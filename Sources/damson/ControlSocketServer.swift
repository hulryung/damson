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

    /// handler: command → response. Called on a worker thread.
    typealias Handler = (ControlCommand) -> ControlResponse

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
                if errno == EBADF || errno == EINVAL { return }
                // Transient error — pause briefly and retry.
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            handleConnection(fd: conn, handler: handler)
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
