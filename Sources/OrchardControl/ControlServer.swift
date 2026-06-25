import Foundation
import DamsonControl
#if canImport(Darwin)
import Darwin
#endif

/// Unix-domain socket server for orchard ↔ orchard-cli. One connection = one command:
/// read a JSON line → handler → write a JSON response line → close. Mirrors damson's
/// `ControlSocketServer`. The handler runs on a worker thread; it is the handler's job to
/// hop main-actor work to the main queue itself (this class takes no thread-safety stance).
public final class OrchardControlServer {
    public typealias Handler = (OrchardCommand) -> OrchardResponse

    private var listenFd: Int32 = -1
    private var socketPath: String = ""
    private var thread: Thread?
    private var stopped = false

    public init() {}

    @discardableResult
    public func start(handler: @escaping Handler) throws -> String {
        let dir = orchardRuntimeDir()
        try createRuntimeDir(at: dir)
        sweepStaleSockets(in: dir)

        let pid = ProcessInfo.processInfo.processIdentifier
        let path = (dir as NSString).appendingPathComponent("\(pid).sock")
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError("socket() failed: errno=\(errno)") }
        if let err = bindOrConnectUnix(fd: fd, path: path, listen: true) {
            close(fd); throw ServerError(err)
        }
        chmod(path, 0o600)
        listenFd = fd
        socketPath = path

        let t = Thread { [weak self] in self?.acceptLoop(handler: handler) }
        t.name = "orchard.control.accept"
        t.start()
        thread = t
        return path
    }

    public func stop() {
        stopped = true
        if listenFd >= 0 { shutdown(listenFd, SHUT_RDWR); close(listenFd); listenFd = -1 }
        if !socketPath.isEmpty { unlink(socketPath) }
    }

    deinit { stop() }

    private func createRuntimeDir(at dir: String) throws {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            throw ServerError("runtime dir not a directory: \(dir)")
        }
    }

    private func sweepStaleSockets(in dir: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for name in names where name.hasSuffix(".sock") {
            guard let pid = Int(name.dropLast(5)), pid > 0 else { continue }
            // kill(pid, 0) == 0 → process alive; ESRCH → dead → stale.
            if kill(pid_t(pid), 0) != 0 && errno == ESRCH {
                unlink((dir as NSString).appendingPathComponent(name))
            }
        }
    }

    private func acceptLoop(handler: @escaping Handler) {
        while !stopped {
            var addr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let conn: Int32 = withUnsafeMutablePointer(to: &addr) { ap in
                ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listenFd, $0, &len) }
            }
            if conn < 0 {
                if stopped { return }
                if errno == EINTR { continue }
                if errno == EBADF || errno == EINVAL { return }
                Thread.sleep(forTimeInterval: 0.01); continue
            }
            handleConnection(fd: conn, handler: handler)
        }
    }

    private func handleConnection(fd: Int32, handler: @escaping Handler) {
        defer { close(fd) }
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if data.contains(0x0A) { break }
        }
        if let nl = data.firstIndex(of: 0x0A) { data = data.prefix(upTo: nl) }
        guard !data.isEmpty else { return }

        let resp: OrchardResponse
        if let cmd = try? JSONDecoder().decode(OrchardCommand.self, from: data) {
            resp = handler(cmd)
        } else {
            resp = .error("parse error")
        }
        guard var out = try? JSONEncoder().encode(resp) else { return }
        out.append(0x0A)
        var sent = 0
        out.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.baseAddress!
            while sent < out.count {
                let n = write(fd, p.advanced(by: sent), out.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }
}

struct ServerError: Error, CustomStringConvertible {
    let message: String
    init(_ m: String) { message = m }
    var description: String { message }
}
