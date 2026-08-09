import AppKit
import CFDPass
import DamsonControl
import DamsonTerminal
import Darwin

/// Restart survival — the app side of the keeper handshake.
///
/// Quit side (`handOffAll`): release each compact pane's PTY from its session WITHOUT
/// killing the child, spawn `damson-keeper` detached, and pass every master fd over a
/// socketpair via SCM_RIGHTS. The keeper holds (and drains) them; the children never see
/// SIGHUP and keep running. Launch side (`claim`): fetch the fds back from the keeper of
/// the generation recorded in RestorableState and hand them to `PaneNode.from(restorable:adopt:)`.
///
/// See docs/SESSION-KEEPER.md and Sources/damson-keeper/main.swift for the protocol.

/// What the quit side records per handed-off session (keyed by ObjectIdentifier(session)
/// into `toRestorable(handoff:)`).
struct SessionHandoffRecord {
    let uuid: String
    let preamble: Data
    let cwd: String?
}

/// What the launch side gets back per claimed session.
struct AdoptedSession {
    let fd: Int32
    let pid: pid_t
    let startSec: UInt64
    let startUsec: UInt64
    /// Handoff tail + everything the child printed while the app was down.
    let buffer: Data
}

enum SessionHandoff {
    /// The feature gate (Settings → "Keep sessions running across restarts").
    static var keepEnabled: Bool {
        UserDefaults.standard.bool(forKey: "damson.keepSessionsOnRestart")
    }

    // MARK: - Quit side

    /// Hand every releasable compact-window session to a fresh keeper. Returns the
    /// generation + per-session records for `toRestorable`, or nil when there was nothing
    /// to hand off or the keeper could not be started (in which case any already-released
    /// PTYs are closed — the children get SIGHUP, equivalent to a normal quit).
    static func handOffAll(controllers: [CompactWindowController])
        -> (generation: String, records: [ObjectIdentifier: SessionHandoffRecord])? {
        // Release first: collect (session, preamble, handoff) for every pane that can
        // survive. Preamble MUST be captured before release — it reads live session state.
        var pending: [(session: DamsonSession, record: SessionHandoffRecord,
                       handoff: PTYHost.PTYHandoff)] = []
        for controller in controllers {
            for session in controller.allPaneSessions {
                let preamble = session.stateRestorationPreamble()
                guard let handoff = session.releasePTYForHandoff() else { continue }
                let record = SessionHandoffRecord(
                    uuid: UUID().uuidString, preamble: preamble, cwd: handoff.cwd)
                pending.append((session, record, handoff))
            }
        }
        guard !pending.isEmpty else { return nil }

        // Short on purpose: the generation lands in the claim-socket filename, and
        // sockaddr_un caps the whole path at 104 bytes — a full UUID under a deep
        // $TMPDIR blows it. Eight hex chars is ample for "my keeper vs a stale one".
        let generation = String(UUID().uuidString.prefix(8))
        func abortReleased() {
            // Keeper unavailable: close the released masters. Last-close delivers SIGHUP,
            // so this degrades to exactly what a normal quit would have done.
            for p in pending { close(p.handoff.fd) }
        }

        guard let sock = spawnKeeper(generation: generation) else {
            abortReleased()
            return nil
        }
        defer { close(sock) }

        var records: [ObjectIdentifier: SessionHandoffRecord] = [:]
        for p in pending {
            let hold = KeeperHold(
                op: "hold", uuid: p.record.uuid, pid: Int32(p.handoff.pid),
                startSec: p.handoff.startSec, startUsec: p.handoff.startUsec,
                tail: p.handoff.tail.base64EncodedString())
            var ok = keeperWriteLine(fd: sock, hold)
            if ok {
                var byte: UInt8 = 0x46
                ok = withUnsafeBytes(of: &byte) {
                    cfd_send(sock, p.handoff.fd, $0.baseAddress!, 1) > 0
                }
            }
            if ok, let ackLine = keeperReadLine(fd: sock),
               let ack = keeperDecode(KeeperAck.self, ackLine), ack.ok {
                // The keeper holds a reference now (in flight or received) — our copy
                // must go so the keeper's later close is the LAST close.
                close(p.handoff.fd)
                records[ObjectIdentifier(p.session)] = p.record
            } else {
                NSLog("damson: handoff failed for %@ — closing (child will HUP)", p.record.uuid)
                close(p.handoff.fd)
            }
        }
        _ = keeperWriteLine(fd: sock, KeeperHold(op: "done"))
        _ = keeperReadLine(fd: sock)   // final ack — best effort
        guard !records.isEmpty else { return nil }
        NSLog("damson: handed off %d session(s), generation %@", records.count, generation)
        return (generation, records)
    }

    /// Spawn the keeper detached (own session, survives us) with the handoff socketpair
    /// on fd 3. Returns our end of the pair.
    private static func spawnKeeper(generation: String) -> Int32? {
        guard let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent().appendingPathComponent("damson-keeper").path,
            FileManager.default.isExecutableFile(atPath: bundled) else {
            NSLog("damson: damson-keeper binary not found")
            return nil
        }
        // Run a COPY from the runtime dir, not the bundle: an update may replace the
        // bundle in place (Sparkle swaps atomically, but brew/cp-style installs don't),
        // and a keeper whose backing binary lives outside the bundle is immune either
        // way. The keeper unlinks the copy when it exits.
        let runtime = damsonRuntimeDir()
        try? FileManager.default.createDirectory(
            atPath: runtime, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let copyPath = (runtime as NSString).appendingPathComponent("keeper-bin-\(generation)")
        do {
            try FileManager.default.copyItem(atPath: bundled, toPath: copyPath)
        } catch {
            NSLog("damson: keeper copy failed: \(error)")
            return nil
        }

        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            try? FileManager.default.removeItem(atPath: copyPath)
            return nil
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        // POSIX_SPAWN_CLOEXEC_DEFAULT closes EVERYTHING not named here — crucial: a stray
        // inherited pty fd in the keeper would silently defeat last-close SIGHUP forever.
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 1)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 2)
        posix_spawn_file_actions_adddup2(&fileActions, pair[1], keeperHandoffFD)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] =
            [strdup(copyPath), strdup(generation), nil]
        // Inherit OUR environment — the keeper derives its runtime dir from TMPDIR, and
        // an empty environment would silently send it to the /tmp fallback while the
        // claiming app looks in $TMPDIR: the claim would never find it.
        let rc = posix_spawn(&pid, copyPath, &fileActions, &attr, argv, environ)
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attr)
        for p in argv where p != nil { free(p) }
        close(pair[1])
        guard rc == 0 else {
            NSLog("damson: keeper spawn failed rc=%d", rc)
            close(pair[0])
            try? FileManager.default.removeItem(atPath: copyPath)
            return nil
        }
        disableSIGPIPE(pair[0])
        NSLog("damson: keeper spawned pid=%d", pid)
        return pair[0]
    }

    // MARK: - Launch side

    /// Claim the surviving sessions of `generation` back from the keeper. Returns whatever
    /// could be claimed (empty when the keeper is gone or held nothing useful). Sessions the
    /// keeper holds that aren't in `wanted` are closed by the keeper at "end" (their leaves
    /// no longer exist in the saved layout).
    static func claim(generation: String, wanted: [String]) -> [String: AdoptedSession] {
        let path = keeperSocketPath(generation: generation)
        var sock: Int32 = -1
        for attempt in 0..<3 {
            if attempt > 0 { usleep(200_000) }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            if bindOrConnectUnix(fd: fd, path: path, listen: false) == nil {
                sock = fd
                break
            }
            close(fd)
        }
        guard sock >= 0 else {
            NSLog("damson: no keeper answering for generation %@", generation)
            return [:]
        }
        defer { close(sock) }
        disableSIGPIPE(sock)

        guard keeperWriteLine(fd: sock, KeeperClaimHello(generation: generation)),
              let invLine = keeperReadLine(fd: sock),
              let inventory = keeperDecode(KeeperInventory.self, invLine), inventory.ok else {
            return [:]
        }
        let alive = Set(inventory.sessions.filter(\.alive).map(\.uuid))

        var out: [String: AdoptedSession] = [:]
        for uuid in wanted where alive.contains(uuid) {
            guard keeperWriteLine(fd: sock, KeeperClaimRequest(op: "claim", uuid: uuid)),
                  let grantLine = keeperReadLine(fd: sock),
                  let grant = keeperDecode(KeeperClaimGrant.self, grantLine), grant.ok else {
                continue
            }
            var fd: Int32 = -1
            var byte: UInt8 = 0
            let r = cfd_recv(sock, &fd, &byte, 1)
            guard r > 0, fd >= 0, let pid = grant.pid else {
                if fd >= 0 { close(fd) }
                continue
            }
            _ = keeperWriteLine(fd: sock, KeeperClaimRequest(op: "ack"))
            out[uuid] = AdoptedSession(
                fd: fd, pid: pid,
                startSec: grant.startSec ?? 0, startUsec: grant.startUsec ?? 0,
                buffer: grant.buffer.flatMap { Data(base64Encoded: $0) } ?? Data())
        }
        _ = keeperWriteLine(fd: sock, KeeperClaimRequest(op: "end"))
        _ = keeperReadLine(fd: sock)   // best effort
        if !out.isEmpty {
            NSLog("damson: adopted %d surviving session(s)", out.count)
        }
        return out
    }
}
