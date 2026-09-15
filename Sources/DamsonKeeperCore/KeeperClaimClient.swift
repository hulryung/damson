import CFDPass
import DamsonControl
import Darwin
import Foundation

/// What the launch side gets back per claimed session.
public struct AdoptedSession {
    public let fd: Int32
    public let pid: pid_t
    public let startSec: UInt64
    public let startUsec: UInt64
    /// Handoff tail + everything the child printed while the app was down.
    public let buffer: Data
}

/// The app's half of the claim conversation, kept beside the keeper's half so a test can
/// run the two against each other.
///
/// It runs on the main thread at launch, before any window exists, so it must not be able
/// to wait forever: every read and write has a timeout. And since the protocol is lockstep,
/// a turn that goes wrong leaves no telling where the keeper is — so the claim hangs up and
/// asks again on a new connection. That is safe because the keeper keeps every session it
/// has not seen acked.
public enum KeeperClaimClient {
    /// The longest any one read or write may wait.
    static let ioTimeoutSeconds = 5
    /// How long to wait for the fd after its granted line. The keeper sends it while the
    /// line is still being read, so once the line is in, the fd is there or not coming: a
    /// keeper from before cfd_send learned to wait for room sends nothing at all.
    static let fdWaitMs: Int32 = 500
    /// Tries per session before its leaf gets a fresh shell instead.
    static let attemptsPerSession = 3

    /// Claim the surviving sessions of `generation` back from the keeper listening at
    /// `socketPath`. Returns whatever could be claimed (empty when the keeper is gone or
    /// held nothing useful). Sessions the keeper holds that aren't in `wanted` are closed by
    /// the keeper at "end" (their leaves no longer exist in the saved layout).
    public static func claim(socketPath path: String, generation: String, wanted: [String],
                             log: (String) -> Void = { _ in }) -> [String: AdoptedSession] {
        var out: [String: AdoptedSession] = [:]
        var failures: [String: Int] = [:]
        var strays = 0
        while true {
            guard let sock = connect(path) else {
                log("no keeper answering for generation \(generation)")
                return out
            }
            let result = converse(sock, generation: generation, wanted: wanted,
                                  out: &out, failures: failures)
            close(sock)
            switch result {
            case .ended, .refused:
                return out
            case .broken(let uuid?):
                failures[uuid, default: 0] += 1
                log("claim of \(uuid) broke off (try \(failures[uuid, default: 0])) — asking again")
            case .broken(nil):
                strays += 1
                guard strays < 2 else {
                    log("keeper stopped answering — keeping \(out.count) session(s)")
                    return out
                }
            }
        }
    }

    private enum Conversation {
        /// Every wanted session was asked for, and `end` sent.
        case ended
        /// The keeper will not deal with this generation.
        case refused
        /// Out of step — while claiming this session, or outside any one claim (nil).
        case broken(String?)
    }

    /// One connection's worth of the conversation. Sessions claimed are added to `out` as
    /// they arrive, so a connection that breaks halfway keeps what it already got.
    private static func converse(_ sock: Int32, generation: String, wanted: [String],
                                 out: inout [String: AdoptedSession],
                                 failures: [String: Int]) -> Conversation {
        disableSIGPIPE(sock)
        var tv = timeval(tv_sec: ioTimeoutSeconds, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard keeperWriteLine(fd: sock, KeeperClaimHello(generation: generation)),
              let invLine = keeperReadLine(fd: sock),
              let inventory = keeperDecode(KeeperInventory.self, invLine) else {
            return .broken(nil)
        }
        guard inventory.ok else { return .refused }
        let alive = Set(inventory.sessions.filter(\.alive).map(\.uuid))

        for uuid in wanted where out[uuid] == nil && alive.contains(uuid)
            && failures[uuid, default: 0] < attemptsPerSession {
            guard keeperWriteLine(fd: sock, KeeperClaimRequest(op: "claim", uuid: uuid)),
                  let grantLine = keeperReadLine(fd: sock),
                  let grant = keeperDecode(KeeperClaimGrant.self, grantLine) else {
                return .broken(uuid)
            }
            // A refusal (the child died meanwhile) is an answer, and the next turn is ours.
            guard grant.ok else { continue }
            guard let fd = receiveFD(sock) else { return .broken(uuid) }
            guard let pid = grant.pid else {
                close(fd)
                return .broken(uuid)
            }
            out[uuid] = AdoptedSession(
                fd: fd, pid: pid,
                startSec: grant.startSec ?? 0, startUsec: grant.startUsec ?? 0,
                buffer: grant.buffer.flatMap { Data(base64Encoded: $0) } ?? Data())
            // Ours now even if the ack is lost: a keeper that never sees it keeps its own
            // copy until `end`, and closing that copy is then not the child's last close.
            guard keeperWriteLine(fd: sock, KeeperClaimRequest(op: "ack")) else {
                return .broken(nil)
            }
        }
        _ = keeperWriteLine(fd: sock, KeeperClaimRequest(op: "end"))
        _ = keeperReadLine(fd: sock)   // best effort
        return .ended
    }

    /// The fd message that follows a granted line, or nil if it does not come in time.
    private static func receiveFD(_ sock: Int32) -> Int32? {
        var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
        var ready: Int32
        repeat {
            ready = poll(&pfd, 1, fdWaitMs)
        } while ready < 0 && errno == EINTR
        guard ready > 0 else { return nil }
        var fd: Int32 = -1
        var byte: UInt8 = 0
        guard cfd_recv(sock, &fd, &byte, 1) > 0, fd >= 0 else {
            if fd >= 0 { close(fd) }
            return nil
        }
        return fd
    }

    private static func connect(_ path: String) -> Int32? {
        for attempt in 0..<3 {
            if attempt > 0 { usleep(200_000) }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            if bindOrConnectUnix(fd: fd, path: path, listen: false) == nil { return fd }
            close(fd)
        }
        return nil
    }
}
