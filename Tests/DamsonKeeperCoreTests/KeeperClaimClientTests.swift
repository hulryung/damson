import CFDPass
import DamsonControl
import Darwin
import Foundation
import XCTest
@testable import DamsonKeeperCore

/// The app's side of the claim, driven against a keeper over a real socket. The claim runs
/// on the main thread at launch, before any window exists, so a claim that waits forever is
/// an app that never finishes launching. Every test here therefore waits on a watchdog, not
/// on the claim.
final class KeeperClaimClientTests: XCTestCase {

    private func tempSocketPath() -> String {
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("kc-\(UUID().uuidString.prefix(8)).sock")
    }

    private func listen(at path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertNil(bindOrConnectUnix(fd: fd, path: path, listen: true))
        return fd
    }

    /// Accept one connection, or give up after `timeoutMs` — a scripted keeper must not
    /// outlive a test whose client never came.
    private func accept(_ listenFD: Int32, timeoutMs: Int32) -> Int32? {
        var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, timeoutMs) > 0 else { return nil }
        let conn = Darwin.accept(listenFD, nil, nil)
        guard conn >= 0 else { return nil }
        disableSIGPIPE(conn)
        return conn
    }

    /// A pipe standing in for a held PTY master.
    private func heldPipe(uuid: String, buffer: Data) -> (held: Held, writeEnd: Int32) {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        let fl = fcntl(fds[0], F_GETFL)
        _ = fcntl(fds[0], F_SETFL, fl | O_NONBLOCK)
        return (Held(uuid: uuid, fd: fds[0], pid: 0, startSec: 0, startUsec: 0,
                     buffer: buffer, alive: true), fds[1])
    }

    /// The launch path end to end: the keeper's real loop on one side, the app's real claim
    /// on the other, and sessions that printed more while the app was down than one socket
    /// buffer holds.
    func testClaimTakesBackEverySessionWhateverItBuffered() {
        let path = tempSocketPath()
        let listenFD = listen(at: path)
        defer { close(listenFD); unlink(path) }

        let keeper = KeeperState(bufferCap: 64 * 1024, unclaimedTimeout: 60)
        var uuids: [String] = []
        var writers: [Int32] = []
        for i in 0..<8 {
            let (h, w) = heldPipe(uuid: "s\(i)",
                                  buffer: Data(repeating: UInt8(0x41 + i), count: 32 * 1024))
            keeper.adopt([h])
            uuids.append(h.uuid)
            writers.append(w)
        }
        var outcome: KeeperState.Outcome?
        let keeperDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            outcome = keeper.run(listenFD: listenFD, generation: "G")
            keeperDone.signal()
        }

        var claimed: [String: AdoptedSession] = [:]
        let claimDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            claimed = KeeperClaimClient.claim(socketPath: path, generation: "G", wanted: uuids)
            claimDone.signal()
        }
        guard claimDone.wait(timeout: .now() + 15) == .success else {
            XCTFail("the claim froze — at launch that is the main thread, and the app hangs")
            return
        }

        XCTAssertEqual(Set(claimed.keys), Set(uuids), "every held session must come back")
        for (i, uuid) in uuids.enumerated() {
            XCTAssertEqual(claimed[uuid]?.buffer,
                           Data(repeating: UInt8(0x41 + i), count: 32 * 1024),
                           "\(uuid) must come back with what it printed meanwhile")
        }
        XCTAssertEqual(keeperDone.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(outcome, .claimed)
        for c in claimed.values { close(c.fd) }
        for w in writers { close(w) }
    }

    /// The first launch after this fix ships talks to a keeper from before it — the handoff
    /// happened while the old version was quitting. That keeper, when its fd send fails,
    /// writes nothing more and waits for the next line. The claim must notice, hang up, and
    /// ask again on a fresh connection, where the session is still held: no ack ever came.
    func testClaimRecoversWhenTheKeeperNeverSendsTheFd() {
        let path = tempSocketPath()
        let listenFD = listen(at: path)
        defer { close(listenFD); unlink(path) }
        var p: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&p), 0)
        defer { close(p[0]); close(p[1]) }

        let inventory = KeeperInventory(
            ok: true, sessions: [.init(uuid: "a", alive: true, buffered: 0)])
        let grant = KeeperClaimGrant(ok: true, pid: 42, startSec: 0, startUsec: 0, buffer: nil)
        var connections = 0
        let keeperDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            // First connection: the grant, then silence where the fd should be.
            if let c = self.accept(listenFD, timeoutMs: 5000) {
                connections += 1
                var tv = timeval(tv_sec: 10, tv_usec: 0)
                setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                _ = keeperReadLine(fd: c)                                   // hello
                _ = keeperWriteLine(fd: c, inventory)
                _ = keeperReadLine(fd: c)                                   // claim a
                _ = keeperWriteLine(fd: c, grant)
                _ = keeperReadLine(fd: c)          // the old keeper waits here for a line
                close(c)
            }
            // Second connection: the same keeper, this time the send goes through.
            if let c = self.accept(listenFD, timeoutMs: 5000) {
                connections += 1
                _ = keeperReadLine(fd: c)                                   // hello
                _ = keeperWriteLine(fd: c, inventory)
                _ = keeperReadLine(fd: c)                                   // claim a
                _ = keeperWriteLine(fd: c, grant)
                var byte: UInt8 = 0x46
                _ = withUnsafeBytes(of: &byte) { cfd_send(c, p[0], $0.baseAddress!, 1) }
                _ = keeperReadLine(fd: c)                                   // ack
                _ = keeperReadLine(fd: c)                                   // end
                _ = keeperWriteLine(fd: c, KeeperAck(ok: true))
                close(c)
            }
            keeperDone.signal()
        }

        let started = Date()
        var claimed: [String: AdoptedSession] = [:]
        let claimDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            claimed = KeeperClaimClient.claim(socketPath: path, generation: "G", wanted: ["a"])
            claimDone.signal()
        }
        guard claimDone.wait(timeout: .now() + 20) == .success else {
            XCTFail("the claim froze — at launch that is the main thread, and the app hangs")
            return
        }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(claimed["a"]?.pid, 42, "the keeper still held it — asking again must get it")
        XCTAssertLessThan(elapsed, 5, "a missing fd may cost a short wait, not the launch")
        keeperDone.wait()
        XCTAssertEqual(connections, 2)
        if let fd = claimed["a"]?.fd { close(fd) }
    }
}
