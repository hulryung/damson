// damson-keeper — holds PTY master fds across an app restart.
//
// The app hands each surviving session's master fd over a socketpair (fd 3) right
// before it exits; because the master stays open here, the children never receive
// SIGHUP and keep running (reparented to launchd). The next app instance connects
// to the claim socket, takes the fds back, and this process exits.
//
// While holding, the keeper DRAINS every master into an append-only buffer: the
// kernel pty queue is tiny (~1KB), so a chatty child would block in write() within
// milliseconds of the app going away. The buffer is replayed into the adopting
// session's parser, so nothing printed during the restart is lost. When a buffer
// hits its cap the keeper simply stops reading that fd — the child then blocks at
// the kernel queue (bounded memory, no tearing, no loss), exactly the backpressure
// contract the app's own PTYHost uses.
//
// Foundation/Darwin ONLY — linking AppKit would register a ghost app with
// LaunchServices and the Dock. Single thread, one poll loop, lockstep protocol
// (see DamsonControl/KeeperProtocol.swift).

import CFDPass
import DamsonControl
import Darwin
import Foundation

// MARK: - State

struct Held {
    let uuid: String
    var fd: Int32
    let pid: Int32
    let startSec: UInt64
    let startUsec: UInt64
    var buffer: Data
    var alive: Bool
}

let bufferCap = 4 * 1024 * 1024
/// How long to wait for a claim before concluding no app is coming back. Closing
/// the masters then HUPs the children — ordinary logout semantics, no orphans.
let unclaimedTimeout: TimeInterval = 15 * 60

var terminating = false

func log(_ msg: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
    logHandle?.write(line.data(using: .utf8) ?? Data())
}

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: damson-keeper <generation>\n".data(using: .utf8)!)
    exit(64)
}
let generation = CommandLine.arguments[1]

let runtimeDir = damsonRuntimeDir()
try? FileManager.default.createDirectory(
    atPath: runtimeDir, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
let logPath = (runtimeDir as NSString).appendingPathComponent("keeper-\(generation).log")
FileManager.default.createFile(atPath: logPath, contents: nil,
                               attributes: [.posixPermissions: 0o600])
let logHandle = FileHandle(forWritingAtPath: logPath)
logHandle?.seekToEndOfFile()

signal(SIGPIPE, SIG_IGN)
// SIGTERM (logout / user cleanup): close every master — the children get SIGHUP,
// standard "terminal went away" — and exit. The handler only flips a flag; poll
// returns EINTR and the loop notices.
signal(SIGTERM) { _ in terminating = true }
_ = chdir("/")

log("keeper start generation=\(generation) pid=\(getpid())")

// MARK: - Phase 1: receive holds on the inherited socketpair (fd 3)

var held: [Held] = []

phase1: while true {
    guard let line = keeperReadLine(fd: keeperHandoffFD),
          let msg = keeperDecode(KeeperHold.self, line) else { break phase1 }   // EOF/garbage
    switch msg.op {
    case "hold":
        var fd: Int32 = -1
        var byte: UInt8 = 0
        let r = cfd_recv(keeperHandoffFD, &fd, &byte, 1)
        guard r > 0, fd >= 0,
              let uuid = msg.uuid, let pid = msg.pid else {
            log("hold failed r=\(r) fd=\(fd)")
            _ = keeperWriteLine(fd: keeperHandoffFD, KeeperAck(ok: false, error: "no fd"))
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
        _ = keeperWriteLine(fd: keeperHandoffFD, KeeperAck(ok: true))
    case "done":
        _ = keeperWriteLine(fd: keeperHandoffFD, KeeperAck(ok: true))
        break phase1
    default:
        _ = keeperWriteLine(fd: keeperHandoffFD, KeeperAck(ok: false, error: "bad op"))
    }
}
close(keeperHandoffFD)

guard !held.isEmpty else {
    log("nothing to hold — exiting")
    exit(0)
}
log("holding \(held.count) session(s)")

// MARK: - Phase 2: drain + serve claims

let sockPath = keeperSocketPath(generation: generation)
unlink(sockPath)
let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
guard listenFD >= 0 else { log("socket() failed"); exit(1) }
if let bindError = bindOrConnectUnix(fd: listenFD, path: sockPath, listen: true) {
    log("bind failed: \(bindError)")
    // Exiting closes every held master — the children get SIGHUP, exactly a normal
    // quit. Nothing strands. Drop our binary copy like the normal exit path does.
    unlink(CommandLine.arguments[0])
    exit(1)
}
chmod(sockPath, 0o600)

func closeAllHeld(reason: String) {
    for i in held.indices where held[i].fd >= 0 {
        close(held[i].fd)
        held[i].fd = -1
    }
    log("closed all held fds (\(reason))")
}

func drain(_ i: Int) {
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

/// One whole claim conversation on an accepted connection. Lockstep, blocking —
/// claims take milliseconds; children at most block briefly at the kernel queue.
func serveClaim(conn: Int32) -> Bool {   // true = claimed-and-ended, keeper should exit
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

let deadline = Date().addingTimeInterval(unclaimedTimeout)

mainLoop: while true {
    if terminating {
        closeAllHeld(reason: "SIGTERM")
        break
    }
    if Date() >= deadline {
        closeAllHeld(reason: "unclaimed timeout")
        break
    }
    if !held.contains(where: { $0.alive }) {
        log("all held sessions dead")
        break
    }

    var fds: [pollfd] = [pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)]
    var indexForSlot: [Int] = [-1]
    for (i, h) in held.enumerated() where h.alive && h.fd >= 0 && h.buffer.count < bufferCap {
        fds.append(pollfd(fd: h.fd, events: Int16(POLLIN), revents: 0))
        indexForSlot.append(i)
    }
    let timeoutMs = Int32(max(250, min(5000, deadline.timeIntervalSinceNow * 1000)))
    let pr = poll(&fds, nfds_t(fds.count), timeoutMs)
    if pr < 0 {
        if errno == EINTR { continue }
        log("poll failed errno=\(errno)")
        closeAllHeld(reason: "poll failure")
        break
    }
    if pr == 0 { continue }

    for (slot, pfd) in fds.enumerated() where pfd.revents != 0 {
        if slot == 0 {
            let conn = accept(listenFD, nil, nil)
            if conn >= 0 {
                disableSIGPIPE(conn)
                if serveClaim(conn: conn) { break mainLoop }
            }
            // A claim removes entries from `held`, so every index in `indexForSlot` past
            // this point describes the array as it was BEFORE the conversation. Rebuild
            // rather than drain through them. Nothing is lost by skipping this round: the
            // pty fds are level-triggered, so anything readable is reported again on the
            // very next poll.
            continue mainLoop
        } else {
            drain(indexForSlot[slot])
        }
    }
}

close(listenFD)
unlink(sockPath)
// The app runs us from a per-generation COPY in the runtime dir; clean it up.
// (Unlinking a running binary is safe — the vnode lives until we exit.)
unlink(CommandLine.arguments[0])
log("keeper exit")
exit(0)
