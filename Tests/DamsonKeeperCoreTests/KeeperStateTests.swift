import CFDPass
import DamsonControl
import Darwin
import Foundation
import XCTest
@testable import DamsonKeeperCore

/// The keeper holds every surviving session's PTY master while damson is gone. If it traps,
/// every held fd closes at once and every shell the user was keeping loses its terminal —
/// the exact outcome the keeper exists to prevent. So these tests are mostly about the
/// hostile paths: a client that disconnects mid-conversation, a stale index, a dead child.
final class KeeperStateTests: XCTestCase {

    /// A socketpair standing in for the app↔keeper connection. SIGPIPE is off on both ends,
    /// as it is in both processes: a test that writes after its peer hung up must see EPIPE,
    /// not take the test runner down.
    private func socketPair() -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        disableSIGPIPE(fds[0])
        disableSIGPIPE(fds[1])
        return (fds[0], fds[1])
    }

    /// The fd message that follows a granted line, waiting at most `waitMs` for it. -1 if
    /// none came.
    private func receiveFD(_ sock: Int32, waitMs: Int32) -> Int32 {
        var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, waitMs) > 0 else { return -1 }
        var fd: Int32 = -1
        var byte: UInt8 = 0
        return cfd_recv(sock, &fd, &byte, 1) > 0 ? fd : -1
    }

    /// A pipe standing in for a held PTY master: readable, closeable, and EOF-able on demand.
    private func heldPipe(uuid: String, buffer: Data = Data()) -> (held: Held, writeEnd: Int32) {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        let fl = fcntl(fds[0], F_GETFL)
        _ = fcntl(fds[0], F_SETFL, fl | O_NONBLOCK)
        return (Held(uuid: uuid, fd: fds[0], pid: 0, startSec: 0, startUsec: 0,
                     buffer: buffer, alive: true), fds[1])
    }

    private func makeKeeper(timeout: TimeInterval = 60) -> KeeperState {
        KeeperState(bufferCap: 64 * 1024, unclaimedTimeout: timeout)
    }

    // MARK: - drain

    func testDrainAccumulatesOutput() {
        let k = makeKeeper()
        let (h, w) = heldPipe(uuid: "a")
        k.adopt([h])
        write(w, "hello", 5)
        k.drain(0)
        XCTAssertEqual(k.held[0].buffer, Data("hello".utf8))
        XCTAssertTrue(k.held[0].alive)
        close(w)
    }

    /// EOF means the child is gone: the entry must be marked dead and its fd closed exactly
    /// once, so nothing later reads or double-closes it.
    func testDrainMarksDeadOnEOF() {
        let k = makeKeeper()
        let (h, w) = heldPipe(uuid: "a")
        k.adopt([h])
        close(w)                       // child exits
        k.drain(0)
        XCTAssertFalse(k.held[0].alive)
        XCTAssertEqual(k.held[0].fd, -1, "the fd must be closed and cleared, not left dangling")
    }

    /// The regression test for the fix that shipped without one. An index past the end
    /// traps on subscript, and a closed slot reads fd -1 → EBADF, which falls past the
    /// EINTR/EAGAIN arms and marks a LIVE session dead. Both kill sessions the keeper is
    /// supposed to be protecting.
    func testDrainIgnoresStaleAndClosedIndices() {
        let k = makeKeeper()
        let (h, w) = heldPipe(uuid: "a")
        k.adopt([h])

        k.drain(5)                     // past the end — must not trap
        k.drain(-1)                    // negative — must not trap
        XCTAssertTrue(k.held[0].alive)

        close(w)
        k.drain(0)                     // EOF closes it
        XCTAssertFalse(k.held[0].alive)
        k.drain(0)                     // already closed — must not mark anything, must not trap
        XCTAssertEqual(k.held[0].fd, -1)
    }

    /// Past the cap the keeper stops reading, so the child blocks at the kernel queue
    /// instead of the keeper growing without bound.
    func testDrainStopsAtTheBufferCap() {
        let k = KeeperState(bufferCap: 1024)
        let (h, w) = heldPipe(uuid: "a")
        k.adopt([h])
        _ = Data(repeating: 0x41, count: 8192).withUnsafeBytes { write(w, $0.baseAddress, 8192) }
        k.drain(0)
        XCTAssertLessThanOrEqual(k.held[0].buffer.count, 1024)
        close(w)
    }

    // MARK: - claims

    /// A client that speaks the wrong generation must be refused without losing anything:
    /// the sessions belong to a different app instance's handoff.
    func testGenerationMismatchIsRejectedAndNothingIsLost() {
        let k = makeKeeper()
        let (h, w) = heldPipe(uuid: "a")
        k.adopt([h])
        let (client, server) = socketPair()
        _ = keeperWriteLine(fd: client, KeeperClaimHello(generation: "OTHER"))
        let ended = k.serveClaim(conn: server, generation: "MINE")
        XCTAssertFalse(ended)
        XCTAssertEqual(k.held.count, 1)
        XCTAssertTrue(k.held[0].alive)
        close(client); close(w)
    }

    /// THE crash this extraction exists for. `serveClaim` mutates `held`, and the poll loop
    /// had gathered slot→index pairs before it ran; draining through them afterwards
    /// subscripts out of range and traps, taking every held session with it. A client that
    /// merely disconnects mid-conversation was enough to trigger it.
    func testClaimDropMidConversationDoesNotTrap() {
        let k = makeKeeper()
        var writers: [Int32] = []
        for name in ["a", "b", "c"] {
            let (h, w) = heldPipe(uuid: name)
            k.adopt([h]); writers.append(w)
        }
        // The protocol is lockstep and this test drives both ends from one thread, so the
        // client's whole script is written up front and the write side is then half-closed:
        // `serveClaim` reads hello and the claim, then hits EOF exactly where a vanished
        // client would leave it.
        let (client, server) = socketPair()
        _ = keeperWriteLine(fd: client, KeeperClaimHello(generation: "G"))
        _ = keeperWriteLine(fd: client, KeeperClaimRequest(op: "claim", uuid: "a"))
        shutdown(client, SHUT_WR)                                        // vanish mid-claim

        let ended = k.serveClaim(conn: server, generation: "G")
        XCTAssertFalse(ended, "a dropped client is not an `end`")
        // Un-acked, so it is KEPT for a retry rather than silently dropped.
        XCTAssertEqual(k.held.count, 3)
        // And every index the old poll set could have handed us must be safe to drain now.
        for i in -1...5 { k.drain(i) }
        for w in writers { close(w) }
    }

    /// `end` means the new app took what it wanted; whatever is left is unwanted and must be
    /// closed, so those children get SIGHUP instead of stranding until the timeout.
    func testEndClosesUnwantedSessions() {
        let k = makeKeeper()
        var writers: [Int32] = []
        for name in ["a", "b"] {
            let (h, w) = heldPipe(uuid: name)
            k.adopt([h]); writers.append(w)
        }
        let (client, server) = socketPair()
        _ = keeperWriteLine(fd: client, KeeperClaimHello(generation: "G"))
        _ = keeperWriteLine(fd: client, KeeperClaimRequest(op: "end", uuid: nil))
        shutdown(client, SHUT_WR)

        XCTAssertTrue(k.serveClaim(conn: server, generation: "G"), "`end` must stop the keeper")
        for h in k.held { XCTAssertEqual(h.fd, -1, "unwanted sessions must be closed") }
        close(client); for w in writers { close(w) }
    }

    func testClaimForAnUnknownSessionIsRefusedNotFatal() {
        let k = makeKeeper()
        let (h, w) = heldPipe(uuid: "a")
        k.adopt([h])
        let (client, server) = socketPair()
        _ = keeperWriteLine(fd: client, KeeperClaimHello(generation: "G"))
        _ = keeperWriteLine(fd: client, KeeperClaimRequest(op: "claim", uuid: "nope"))
        _ = keeperWriteLine(fd: client, KeeperClaimRequest(op: "end", uuid: nil))
        shutdown(client, SHUT_WR)
        XCTAssertTrue(k.serveClaim(conn: server, generation: "G"))
        close(client); close(w)
    }

    /// Raw bytes whose base64 makes `line` — newline included — fill `sock`'s send buffer
    /// to within one SCM_RIGHTS control message (16 bytes). That is the state in which
    /// macOS refuses to pass an fd: EMSGSIZE, at once, without blocking. Zeros, because
    /// their base64 has no "/" for JSONEncoder to escape into two bytes.
    private func payloadFillingSendBuffer(of sock: Int32,
                                          line: (String) -> any Encodable) throws -> Data {
        var sndbuf: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(getsockopt(sock, SOL_SOCKET, SO_SNDBUF, &sndbuf, &len), 0)
        func length(_ n: Int) throws -> Int {
            try JSONEncoder().encode(line(Data(count: n).base64EncodedString())).count + 1
        }
        let n = (Int(sndbuf) - (try length(0))) / 4 * 3
        let filled = try length(n)
        XCTAssertLessThanOrEqual(filled, Int(sndbuf))
        XCTAssertGreaterThan(filled, Int(sndbuf) - 16, "must leave less room than an fd needs")
        return Data(count: n)
    }

    /// The launch hang of 2026-09-15. A grant line carries everything the session printed
    /// while the app was down; the keeper wrote it and sent the fd straight after, while
    /// the app was still reading the line. Past the socket buffer's size, the fd sometimes
    /// met a buffer the app had not yet drained, was refused, and the app — holding an `ok`
    /// grant — waited for it forever. Here the client simply reads late, which makes that
    /// sometimes an always.
    func testAGrantThatFillsTheSocketBufferStillCarriesItsFd() throws {
        let k = makeKeeper()
        let (client, server) = socketPair()
        let buffer = try payloadFillingSendBuffer(of: server) {
            KeeperClaimGrant(ok: true, pid: 0, startSec: 0, startUsec: 0, buffer: $0)
        }
        let (h, w) = heldPipe(uuid: "a", buffer: buffer)
        k.adopt([h])
        // The keeper answers from its own thread, as it does from its own process.
        let served = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = k.serveClaim(conn: server, generation: "G")
            served.signal()
        }
        XCTAssertTrue(keeperWriteLine(fd: client, KeeperClaimHello(generation: "G")))
        _ = try XCTUnwrap(keeperReadLine(fd: client))                         // inventory
        XCTAssertTrue(keeperWriteLine(fd: client, KeeperClaimRequest(op: "claim", uuid: "a")))
        usleep(200_000)                // the grant fills the buffer and the fd is sent into it
        let grant = try XCTUnwrap(keeperReadLine(fd: client))
        XCTAssertEqual(keeperDecode(KeeperClaimGrant.self, grant)?.buffer?.count,
                       buffer.base64EncodedString().count)

        let fd = receiveFD(client, waitMs: 2000)
        XCTAssertGreaterThanOrEqual(fd, 0, "granted, but the fd never came")
        if fd >= 0 { close(fd) }
        close(client)                              // hanging up ends the conversation either way
        served.wait()
        close(w)
    }

    /// When the fd still cannot go — the app stopped reading — the keeper must hang up, not
    /// wait for the app's next line: the app is waiting for the fd, and each side waiting
    /// for the other is the hang. The session stays held for the app's next try.
    func testAnFdThatCannotBeSentEndsTheConversationButKeepsTheSession() throws {
        let k = makeKeeper()
        let (client, server) = socketPair()
        let buffer = try payloadFillingSendBuffer(of: server) {
            KeeperClaimGrant(ok: true, pid: 0, startSec: 0, startUsec: 0, buffer: $0)
        }
        let (h, w) = heldPipe(uuid: "a", buffer: buffer)
        k.adopt([h])
        var ended: Bool?
        let served = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            ended = k.serveClaim(conn: server, generation: "G")
            served.signal()
        }
        XCTAssertTrue(keeperWriteLine(fd: client, KeeperClaimHello(generation: "G")))
        _ = try XCTUnwrap(keeperReadLine(fd: client))                         // inventory
        XCTAssertTrue(keeperWriteLine(fd: client, KeeperClaimRequest(op: "claim", uuid: "a")))
        // …and never read again, so the grant fills the buffer and stays there.

        guard served.wait(timeout: .now() + 10) == .success else {
            XCTFail("the keeper is waiting for the app's next line while the app waits for the fd")
            shutdown(client, SHUT_RDWR)
            served.wait()
            return
        }
        XCTAssertEqual(ended, false, "a hang-up is not an `end`")
        XCTAssertEqual(k.held.count, 1)
        XCTAssertTrue(k.held[0].alive)
        XCTAssertGreaterThanOrEqual(k.held[0].fd, 0, "the session must still be held")
        close(client)
        close(w)
        k.closeAllHeld(reason: "test over")
    }

    /// The same refusal on the way out. A hold line carries what the app had read but not
    /// yet parsed — up to 2 MB for a busy pane — and the fd follows it just as a grant's
    /// does. There the sender skipped the ack while the keeper still waited for the fd; the
    /// keeper then took the next line for the fd message and lost every session after it.
    func testAHoldThatFillsTheSocketBufferIsStillHeld() throws {
        let k = makeKeeper()
        let (app, keeperEnd) = socketPair()
        let tail = try payloadFillingSendBuffer(of: app) {
            KeeperHold(op: "hold", uuid: "a", pid: 1, startSec: 0, startUsec: 0, tail: $0)
        }
        var p: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&p), 0)
        // The keeper starts reading late, so the hold line is still unread when the fd goes.
        let received = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            k.receiveHolds(fd: keeperEnd)
            close(keeperEnd)
            received.signal()
        }
        // What handOffAll sends per session: the hold line, the fd, then it reads the ack.
        var ok = keeperWriteLine(fd: app, KeeperHold(
            op: "hold", uuid: "a", pid: 1, startSec: 0, startUsec: 0,
            tail: tail.base64EncodedString()))
        if ok {
            var byte: UInt8 = 0x46
            ok = withUnsafeBytes(of: &byte) { cfd_send(app, p[0], $0.baseAddress!, 1) > 0 }
        }
        if ok { _ = keeperReadLine(fd: app) }
        _ = keeperWriteLine(fd: app, KeeperHold(op: "done"))
        _ = keeperReadLine(fd: app)
        received.wait()

        XCTAssertTrue(ok, "the fd must go through once the keeper reads")
        XCTAssertEqual(k.held.map(\.uuid), ["a"], "the hold must arrive with its fd")
        k.closeAllHeld(reason: "test over")
        close(app)
        close(p[0]); close(p[1])
    }

    /// The inventory is how the app decides what to reclaim, so it must report what is
    /// actually held — including how much output accumulated while the app was away.
    func testInventoryReportsHeldSessions() throws {
        let k = makeKeeper()
        let (h, w) = heldPipe(uuid: "a", buffer: Data("tail".utf8))
        k.adopt([h])
        let (client, server) = socketPair()
        _ = keeperWriteLine(fd: client, KeeperClaimHello(generation: "G"))
        shutdown(client, SHUT_WR)                 // hello, then EOF — serveClaim returns
        _ = k.serveClaim(conn: server, generation: "G")
        // Everything the server wrote is still buffered on our side after it closed.
        let line = try XCTUnwrap(keeperReadLine(fd: client))
        let inv = try XCTUnwrap(keeperDecode(KeeperInventory.self, line))
        XCTAssertTrue(inv.ok)
        XCTAssertEqual(inv.sessions.first?.uuid, "a")
        XCTAssertEqual(inv.sessions.first?.buffered, 4)
        close(client); close(w)
    }

    // MARK: - loop outcomes

    func testLoopStopsWhenEveryChildHasExited() {
        let k = makeKeeper()
        let (h, w) = heldPipe(uuid: "a")
        k.adopt([h])
        close(w)
        k.drain(0)                                  // observe EOF → not alive
        let (listen, _) = socketPair()
        XCTAssertEqual(k.run(listenFD: listen, generation: "G"), .allSessionsDead)
        close(listen)
    }

    /// Nobody came back. Closing the masters HUPs the children — ordinary logout semantics,
    /// which is the right outcome, and far better than holding them forever.
    func testLoopTimesOutAndClosesEverything() {
        // `run` computes its deadline from `now()` on entry, so the clock has to advance
        // AFTER that — a fixed clock set into the future just moves the deadline with it.
        // One second per reading crosses a one-second timeout on the next check, with no
        // real waiting and no dependence on wall time.
        var clock = Date()
        let k = KeeperState(bufferCap: 4096, unclaimedTimeout: 1,
                            now: { clock = clock.addingTimeInterval(1); return clock },
                            shouldTerminate: { false })
        let (h, w) = heldPipe(uuid: "a")
        k.adopt([h])
        let (listen, _) = socketPair()
        XCTAssertEqual(k.run(listenFD: listen, generation: "G"), .timedOut)
        XCTAssertEqual(k.held[0].fd, -1, "a timeout must not leave masters open")
        close(listen); close(w)
    }

    func testSIGTERMClosesEverything() {
        var stop = false
        let k = KeeperState(bufferCap: 4096, unclaimedTimeout: 600,
                            now: Date.init, shouldTerminate: { stop })
        let (h, w) = heldPipe(uuid: "a")
        k.adopt([h])
        stop = true
        let (listen, _) = socketPair()
        XCTAssertEqual(k.run(listenFD: listen, generation: "G"), .terminated)
        XCTAssertEqual(k.held[0].fd, -1)
        close(listen); close(w)
    }
}
