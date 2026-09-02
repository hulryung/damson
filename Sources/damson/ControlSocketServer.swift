import AppKit
import Foundation
import DamsonControl
#if canImport(Darwin)
import Darwin
#endif

/// Unix domain socket server for damson-cli ↔ damson communication.
///
/// Lifecycle:
///   1. `start(handler:)` — create the runtime dir (0o700), sweep stale sockets,
///      unlink our own PID file, bind, chmod 0o600, spawn the accept thread.
///   2. The accept thread follows a one-connection = one-command pattern.
///      Read one JSON line → handler → write one response line → close.
///   3. The handler is called on a worker thread, so it's the handler's responsibility
///      to hop main-actor work onto DispatchQueue.main itself. This class takes no
///      responsibility for thread safety.
final class ControlSocketServer {
    /// `listenFd` and `stopped` are touched by both `stop()` (main/deinit) and the accept
    /// thread, so all access to them goes through `stateLock`. The lock is never held
    /// across the blocking `accept()` — the loop snapshots the fd/flag, then releases.
    private let stateLock = NSLock()
    private var listenFd: Int32 = -1
    private var socketPath: String = ""
    private var thread: Thread?
    private var stopped = false
    /// Accepted connections still being served. A one-shot exchange removes itself in
    /// milliseconds; a subscription stays until the client leaves — so `stop()` has to be
    /// able to close them, or shutdown would block on a listener that never hangs up.
    private var liveConnections: Set<Int32> = []

    /// handler: command → response. Called on a worker thread.
    typealias Handler = (ControlCommand) -> ControlResponse

    /// Streaming hook for `watch-agents`: writes lines to `fd` until the client leaves.
    /// Installed by the app; a nil hook makes the command an ordinary error rather than a
    /// hang, so a client always gets an answer.
    var streamHandler: ((Int32) -> Void)?

    /// Throws on failure. socketPath has the form `damsonRuntimeDir()/{pid}.sock`.
    @discardableResult
    func start(handler: @escaping Handler) throws -> String {
        let dir = damsonRuntimeDir()
        try createRuntimeDir(at: dir)
        sweepStaleSockets(in: dir)

        let pid = ProcessInfo.processInfo.processIdentifier
        let path = (dir as NSString).appendingPathComponent("\(pid).sock")
        // If a file with our own PID is left behind (pid reuse after a prior SIGKILL), remove it first.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ControlSocketError(
                "socket() failed: errno=\(errno)"
            )
        }
        if let err = bindOrConnectUnix(fd: fd, path: path, listen: true) {
            close(fd)
            throw ControlSocketError(err)
        }
        // Block access by other users.
        chmod(path, 0o600)

        stateLock.lock()
        self.listenFd = fd
        stateLock.unlock()
        self.socketPath = path

        let t = Thread { [weak self] in
            self?.acceptLoop(handler: handler)
        }
        t.name = "damson.control.accept"
        t.start()
        self.thread = t

        return path
    }

    /// Re-create the listening socket if its file has gone. Returns whether it rebound.
    ///
    /// macOS periodically sweeps `$TMPDIR`, and it deletes the socket file of a damson that
    /// has simply been running for a few days. The listening fd stays valid, so nothing in
    /// the app notices — but the path a client connects to no longer exists, so `damson-cli`
    /// reports "no running damson instances" while the app is right there. Every scripted
    /// or orchestrated use stops working, silently, with no error on either side.
    ///
    /// Observed: two instances alive, both sockets gone, the runtime dir holding only a
    /// stale socket from an instance that had already quit.
    @discardableResult
    func rebindIfMissing() -> Bool {
        stateLock.lock()
        let stoppedNow = stopped
        let old = listenFd
        stateLock.unlock()
        guard !stoppedNow, !socketPath.isEmpty else { return false }

        var st = stat()
        if stat(socketPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK { return false }

        let dir = damsonRuntimeDir()
        try? createRuntimeDir(at: dir)      // the sweep may have taken the directory too
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        unlink(socketPath)
        if bindOrConnectUnix(fd: fd, path: socketPath, listen: true) != nil {
            close(fd)
            return false
        }
        chmod(socketPath, 0o600)

        stateLock.lock()
        listenFd = fd
        stateLock.unlock()
        // Wake the accept loop so it stops waiting on the fd nobody can reach any more.
        // It re-reads `listenFd` and continues on the new one.
        if old >= 0 {
            shutdown(old, SHUT_RDWR)
            close(old)
        }
        NSLog("damson: control socket was missing; rebound at \(socketPath)")
        return true
    }

    func stop() {
        stateLock.lock()
        if stopped { stateLock.unlock(); return }   // idempotent (deinit + explicit stop)
        stopped = true
        let fd = listenFd
        listenFd = -1
        stateLock.unlock()
        if fd >= 0 {
            // Wake the accept call with shutdown, then close.
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        // Shut down in-flight connections too: a subscriber is blocked in write/poll and
        // would otherwise keep its thread (and the app's teardown) waiting indefinitely.
        stateLock.lock()
        let live = liveConnections
        liveConnections.removeAll()
        stateLock.unlock()
        for c in live { shutdown(c, SHUT_RDWR) }
        if !socketPath.isEmpty {
            unlink(socketPath)
        }
    }

    deinit { stop() }

    private func createRuntimeDir(at dir: String) throws {
        let fm = FileManager.default
        try? fm.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        // Tighten permissions even if the directory already exists.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            throw ControlSocketError("runtime dir not a directory: \(dir)")
        }
    }

    private func sweepStaleSockets(in dir: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for name in names where name.hasSuffix(".sock") {
            let p = (dir as NSString).appendingPathComponent(name)
            if !isSocketLive(path: p) {
                unlink(p)
            }
        }
    }

    private func acceptLoop(handler: @escaping Handler) {
        while true {
            stateLock.lock()
            let stopNow = stopped
            let fd = listenFd
            stateLock.unlock()
            if stopNow { return }

            var addr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let conn: Int32 = withUnsafeMutablePointer(to: &addr) { ap in
                ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(fd, sa, &len)
                }
            }
            if conn < 0 {
                stateLock.lock()
                let stoppedNow = stopped
                stateLock.unlock()
                if stoppedNow { return }
                if errno == EINTR { continue }
                if errno == EBADF || errno == EINVAL {
                    // A rebind may have swapped the listener underneath us and closed the
                    // old fd to wake this call. Pick up the new one and carry on; only give
                    // up when there genuinely is not one.
                    stateLock.lock()
                    let current = listenFd
                    stateLock.unlock()
                    if current >= 0 && current != fd { continue }
                    return
                }
                // Transient error — pause briefly and retry.
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            // One thread per connection. Serving inline used to be fine when every
            // exchange was one line in, one line out — but a subscription (`watch-agents`)
            // holds its connection open for as long as the client cares to listen, and
            // inline that would wedge the accept loop: no other damson-cli command could
            // be served for the lifetime of the watcher. A blocking-forever connection is
            // also why this is a Thread rather than a concurrent DispatchQueue, which such
            // a connection would occupy a worker of indefinitely.
            let c = conn
            stateLock.lock()
            liveConnections.insert(c)
            stateLock.unlock()
            let t = Thread { [weak self] in
                guard let self else { close(c); return }
                self.handleConnection(fd: c, handler: handler)
                self.stateLock.lock()
                self.liveConnections.remove(c)
                self.stateLock.unlock()
            }
            t.name = "damson.control.conn"
            t.start()
        }
    }

    private func handleConnection(fd: Int32, handler: @escaping Handler) {
        defer { close(fd) }
        // A client that disconnects before reading the reply must not raise SIGPIPE on
        // our response write() — that would terminate the whole app. EPIPE instead.
        disableSIGPIPE(fd)

        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv,
                   socklen_t(MemoryLayout.size(ofValue: tv)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv,
                   socklen_t(MemoryLayout.size(ofValue: tv)))

        // Read one newline-framed request into a growable buffer. A large `send-text`
        // paste can exceed any fixed size; the 5s SO_RCVTIMEO above bounds a slow peer.
        let payload: Data
        switch readFramedLine(fd: fd) {
        case .line(let d):
            payload = d
        case .eof(let d):
            guard !d.isEmpty else { return }
            payload = d
        case .tooLong:
            writeResponse(.err("request exceeded size limit"), to: fd)
            return
        case .timeout, .error:
            return
        }
        guard !payload.isEmpty else { return }

        let resp: ControlResponse
        do {
            let cmd = try JSONDecoder().decode(ControlCommand.self, from: payload)
            // A subscription is not a request/response: hand the connection to the stream
            // hook, which owns it until the client disconnects. The read timeout set above
            // would otherwise cut a quiet watcher off after 5s, so clear it first.
            if case .watchAgents = cmd.kind, let stream = streamHandler {
                var none = timeval(tv_sec: 0, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &none,
                           socklen_t(MemoryLayout.size(ofValue: none)))
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &none,
                           socklen_t(MemoryLayout.size(ofValue: none)))
                stream(fd)
                return
            }
            resp = handler(cmd)
        } catch {
            resp = .err("parse error: \(error)")
        }
        writeResponse(resp, to: fd)
    }

    /// Encode `resp` as a JSON line and write it all, retrying on EINTR so a
    /// signal-interrupted partial write doesn't drop the rest of the framed response.
    private func writeResponse(_ resp: ControlResponse, to fd: Int32) {
        guard var out = try? JSONEncoder().encode(resp) else { return }
        out.append(0x0A)
        out.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < out.count {
                let n = write(fd, base.advanced(by: sent), out.count - sent)
                if n < 0 {
                    if errno == EINTR { continue }
                    return   // real write error — give up on this connection
                }
                if n == 0 { return }
                sent += n
            }
        }
    }
}

struct ControlSocketError: Error, CustomStringConvertible {
    let message: String
    init(_ m: String) { self.message = m }
    var description: String { message }
}
