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

    /// A socketpair standing in for the app↔keeper connection.
    private func socketPair() -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (fds[0], fds[1])
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
