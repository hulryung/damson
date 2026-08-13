import CFDPass
import DamsonControl
import Darwin
import Foundation

/// One PTY master the keeper is holding on behalf of a session that outlived its app.
public struct Held {
    public let uuid: String
    public var fd: Int32
    public let pid: Int32
    public let startSec: UInt64
    public let startUsec: UInt64
    public var buffer: Data
    public var alive: Bool

    public init(uuid: String, fd: Int32, pid: Int32, startSec: UInt64, startUsec: UInt64,
                buffer: Data, alive: Bool) {
        self.uuid = uuid
        self.fd = fd
        self.pid = pid
        self.startSec = startSec
        self.startUsec = startUsec
        self.buffer = buffer
        self.alive = alive
    }
}

/// The keeper's whole behaviour, lifted out of top-level code so it can be tested.
///
/// This process is the reason a shell survives an app update: it holds the PTY masters open
/// while damson is gone, so the children never get SIGHUP. Everything it does is therefore
/// load-bearing in a way that is invisible when it works — and when it traps, every held
/// child loses its terminal at once. That is the whole argument for it being testable.
///
/// Foundation/Darwin ONLY. Linking AppKit here would register a ghost app with
/// LaunchServices and the Dock, so this target must never gain a UI dependency.
///
/// Single-threaded by construction: one poll loop, a lockstep protocol, no locks. The
/// injectable seams (`log`, `now`, `shouldTerminate`) exist so a test can drive it without
/// a signal handler, a real clock, or a log file.
public final class KeeperState {
    public private(set) var held: [Held] = []

    /// Cap per session. Past it the keeper stops reading that fd and the child blocks at the
    /// kernel queue — bounded memory, no loss, the same backpressure contract PTYHost uses.
    public let bufferCap: Int
    /// How long to wait for a claim before concluding no app is coming back. Closing the
    /// masters then HUPs the children — ordinary logout semantics, no orphans.
    public let unclaimedTimeout: TimeInterval

    private let log: (String) -> Void
    private let now: () -> Date
    private let shouldTerminate: () -> Bool

    public init(bufferCap: Int = 4 * 1024 * 1024,
                unclaimedTimeout: TimeInterval = 15 * 60,
                now: @escaping () -> Date = Date.init,
                shouldTerminate: @escaping () -> Bool = { false },
                log: @escaping (String) -> Void = { _ in }) {
        self.bufferCap = bufferCap
        self.unclaimedTimeout = unclaimedTimeout
        self.now = now
        self.shouldTerminate = shouldTerminate
        self.log = log
    }

    /// Test seam: install holds directly, instead of receiving them over a socketpair.
    public func adopt(_ holds: [Held]) { held.append(contentsOf: holds) }

    // MARK: - Phase 1: receive holds over the inherited socketpair

    /// Read `hold` messages (each followed by an fd over SCM_RIGHTS) until `done` or EOF.
    /// Returns false if the peer sent garbage, which is treated the same as EOF.
    @discardableResult
    public func receiveHolds(fd handoffFD: Int32) -> Bool {
        while true {
            guard let line = keeperReadLine(fd: handoffFD),
                  let msg = keeperDecode(KeeperHold.self, line) else { return false }
            switch msg.op {
            case "hold":
                var fd: Int32 = -1
                var byte: UInt8 = 0
                let r = cfd_recv(handoffFD, &fd, &byte, 1)
                guard r > 0, fd >= 0, let uuid = msg.uuid, let pid = msg.pid else {
                    log("hold failed r=\(r) fd=\(fd)")
                    _ = keeperWriteLine(fd: handoffFD, KeeperAck(ok: false, error: "no fd"))
                    if fd >= 0 { close(fd) }
                    continue
                }
                // Non-blocking so the drain loop can slurp whatever is there and move on.
                let fl = fcntl(fd, F_GETFL)
                _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK)
                let tail = msg.tail.flatMap { Data(base64Encoded: $0) } ?? Data()
                held.append(Held(uuid: uuid, fd: fd, pid: pid,
                                 startSec: msg.startSec ?? 0, startUsec: msg.startUsec ?? 0,
                                 buffer: tail, alive: true))
                log("hold uuid=\(uuid) pid=\(pid) tail=\(tail.count)B")
                _ = keeperWriteLine(fd: handoffFD, KeeperAck(ok: true))
            case "done":
                _ = keeperWriteLine(fd: handoffFD, KeeperAck(ok: true))
                return true
            default:
                _ = keeperWriteLine(fd: handoffFD, KeeperAck(ok: false, error: "bad op"))
            }
        }
    }

    // MARK: - Draining

    public func closeAllHeld(reason: String) {
        for i in held.indices where held[i].fd >= 0 {
            close(held[i].fd)
            held[i].fd = -1
        }
        log("closed all held fds (\(reason))")
    }

    public func drain(_ i: Int) {
        // The caller's index may be stale (a claim removed an entry) or already closed. Both
        // are cheap to check and expensive to get wrong: an out-of-range subscript traps, and
        // reading fd -1 returns EBADF — which falls past the EINTR/EAGAIN arms below and marks
        // a perfectly LIVE session dead. Either way every held child loses its terminal.
        guard held.indices.contains(i), held[i].fd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 65536)
        while held[i].buffer.count < bufferCap {
            let n = read(held[i].fd, &buf, min(buf.count, bufferCap - held[i].buffer.count))
            if n > 0 {
                held[i].buffer.append(contentsOf: buf[0..<n])
            } else if n == 0 {
                held[i].alive = false
                close(held[i].fd)
                held[i].fd = -1
                log("EOF uuid=\(held[i].uuid) — child gone")
                return
            } else {
                if errno == EINTR { continue }
                if errno == EAGAIN { return }
                held[i].alive = false
                close(held[i].fd)
                held[i].fd = -1
                log("read error uuid=\(held[i].uuid) errno=\(errno)")
                return
            }
        }
    }

    // MARK: - Claims

    /// One whole claim conversation on an accepted connection. Lockstep, blocking —
    /// claims take milliseconds; children at most block briefly at the kernel queue.
    /// Returns true when the client ended the claim, i.e. the keeper should exit.
    public func serveClaim(conn: Int32, generation: String) -> Bool {
        defer { close(conn) }
        guard let helloLine = keeperReadLine(fd: conn),
              let hello = keeperDecode(KeeperClaimHello.self, helloLine), hello.op == "hello" else {
            return false
        }
        guard hello.generation == generation else {
            _ = keeperWriteLine(fd: conn, KeeperInventory(ok: false, error: "generation mismatch"))
            log("claim rejected: generation \(hello.generation) != \(generation)")
            return false
        }
        let entries = held.map {
            KeeperInventory.Entry(uuid: $0.uuid, alive: $0.alive, buffered: $0.buffer.count)
        }
        _ = keeperWriteLine(fd: conn, KeeperInventory(ok: true, sessions: entries))

        while true {
            guard let line = keeperReadLine(fd: conn),
                  let req = keeperDecode(KeeperClaimRequest.self, line) else {
                // Client vanished mid-claim: whatever it already took is its; keep the rest
                // for a retry until the timeout.
                log("claim connection dropped")
                return false
            }
            switch req.op {
            case "claim":
                guard let uuid = req.uuid, let i = held.firstIndex(where: { $0.uuid == uuid }),
                      held[i].alive, held[i].fd >= 0 else {
                    _ = keeperWriteLine(fd: conn, KeeperClaimGrant(ok: false, error: "not held/alive"))
                    continue
                }
                // Final slurp so the grant buffer is complete up to this instant.
                drain(i)
                guard held[i].alive else {
                    _ = keeperWriteLine(fd: conn, KeeperClaimGrant(ok: false, error: "died during claim"))
                    continue
                }
                let h = held[i]
                _ = keeperWriteLine(fd: conn, KeeperClaimGrant(
                    ok: true, pid: h.pid, startSec: h.startSec, startUsec: h.startUsec,
                    buffer: h.buffer.base64EncodedString()))
                var byte: UInt8 = 0x46   // "F"
                let sent = withUnsafeBytes(of: &byte) { cfd_send(conn, h.fd, $0.baseAddress!, 1) }
                guard sent > 0 else {
                    log("cfd_send failed uuid=\(uuid) errno=\(errno)")
                    continue
                }
                if let ackLine = keeperReadLine(fd: conn),
                   let ack = keeperDecode(KeeperClaimRequest.self, ackLine), ack.op == "ack" {
                    // Claimed — close OUR copy, or the last-close SIGHUP contract breaks
                    // forever (closing a pane in the new app would never HUP the shell).
                    close(held[i].fd)
                    held.remove(at: i)
                    log("claimed uuid=\(uuid)")
                } else {
                    log("no ack for uuid=\(uuid) — keeping")
                }
            case "end":
                // Sessions the new app didn't want (leaf gone from the layout): close them,
                // the children get SIGHUP — same as closing those panes.
                closeAllHeld(reason: "claim ended, \(held.count) unwanted")
                _ = keeperWriteLine(fd: conn, KeeperAck(ok: true))
                return true
            default:
                _ = keeperWriteLine(fd: conn, KeeperAck(ok: false, error: "bad op"))
            }
        }
    }

    // MARK: - Phase 2 loop

    /// Why the loop stopped, so the caller (and a test) can tell an ordinary handoff from
    /// a timeout or a failure.
    public enum Outcome: Equatable {
        case claimed          // a client took what it wanted and said `end`
        case terminated       // SIGTERM
        case timedOut         // nobody came back within unclaimedTimeout
        case allSessionsDead  // every child exited while we held it
        case pollFailed
    }

    /// Drain held masters and serve claims until one of `Outcome` happens. On every exit
    /// path the held fds are closed, so no child is left with a terminal nobody owns.
    public func run(listenFD: Int32, generation: String) -> Outcome {
        let deadline = now().addingTimeInterval(unclaimedTimeout)
        while true {
            if shouldTerminate() {
                closeAllHeld(reason: "SIGTERM")
                return .terminated
            }
            if now() >= deadline {
                closeAllHeld(reason: "unclaimed timeout")
                return .timedOut
            }
            if !held.contains(where: { $0.alive }) {
                log("all held sessions dead")
                return .allSessionsDead
            }

            var fds: [pollfd] = [pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)]
            var indexForSlot: [Int] = [-1]
            for (i, h) in held.enumerated() where h.alive && h.fd >= 0 && h.buffer.count < bufferCap {
                fds.append(pollfd(fd: h.fd, events: Int16(POLLIN), revents: 0))
                indexForSlot.append(i)
            }
            let timeoutMs = Int32(max(250, min(5000, deadline.timeIntervalSince(now()) * 1000)))
            let pr = poll(&fds, nfds_t(fds.count), timeoutMs)
            if pr < 0 {
                if errno == EINTR { continue }
                log("poll failed errno=\(errno)")
                closeAllHeld(reason: "poll failure")
                return .pollFailed
            }
            if pr == 0 { continue }

            var restart = false
            for (slot, pfd) in fds.enumerated() where pfd.revents != 0 {
                if slot == 0 {
                    let conn = accept(listenFD, nil, nil)
                    if conn >= 0 {
                        disableSIGPIPE(conn)
                        if serveClaim(conn: conn, generation: generation) { return .claimed }
                    }
                    // A claim removes entries from `held`, so every index in `indexForSlot`
                    // past this point describes the array as it was BEFORE the conversation.
                    // Rebuild rather than drain through them. Nothing is lost by skipping
                    // this round: the pty fds are level-triggered, so anything readable is
                    // reported again on the very next poll.
                    restart = true
                    break
                } else {
                    drain(indexForSlot[slot])
                }
            }
            if restart { continue }
        }
    }
}
