// damson-keeper — holds PTY master fds across an app restart.
//
// The app hands each surviving session's master fd over a socketpair (fd 3) right
// before it exits; because the master stays open here, the children never receive
// SIGHUP and keep running (reparented to launchd). The next app instance connects
// to the claim socket, takes the fds back, and this process exits.
//
// The behaviour lives in `DamsonKeeperCore.KeeperState` so it can be tested — a trap
// in here closes every held master at once, which is every surviving shell losing its
// terminal. This file is just process setup: arguments, log file, signals, sockets.
//
// Foundation/Darwin ONLY — linking AppKit would register a ghost app with
// LaunchServices and the Dock. Single thread, one poll loop, lockstep protocol
// (see DamsonControl/KeeperProtocol.swift).

import DamsonControl
import DamsonKeeperCore
import Darwin
import Foundation

/// Flipped by the SIGTERM handler; a handler cannot capture context, so it must be global.
var terminating = false

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

func log(_ msg: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
    logHandle?.write(line.data(using: .utf8) ?? Data())
}

signal(SIGPIPE, SIG_IGN)
// SIGTERM (logout / user cleanup): close every master — the children get SIGHUP,
// standard "terminal went away" — and exit. The handler only flips a flag; poll
// returns EINTR and the loop notices.
signal(SIGTERM) { _ in terminating = true }
_ = chdir("/")

log("keeper start generation=\(generation) pid=\(getpid())")

let keeper = KeeperState(shouldTerminate: { terminating }, log: log)

// MARK: - Phase 1: receive holds on the inherited socketpair (fd 3)

keeper.receiveHolds(fd: keeperHandoffFD)
close(keeperHandoffFD)

guard !keeper.held.isEmpty else {
    log("nothing to hold — exiting")
    exit(0)
}
log("holding \(keeper.held.count) session(s)")

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

let outcome = keeper.run(listenFD: listenFD, generation: generation)
log("keeper loop ended: \(outcome)")

close(listenFD)
unlink(sockPath)
// The app runs us from a per-generation COPY in the runtime dir; clean it up.
// (Unlinking a running binary is safe — the vnode lives until we exit.)
unlink(CommandLine.arguments[0])
log("keeper exit")
exit(0)
