import Foundation
import Darwin
import DamsonControl

public struct ComputerRequest: Codable {
    public let id: String
    public let command: String
    public let arguments: [String: String]
    public init(id: String = UUID().uuidString, command: String, arguments: [String: String] = [:]) {
        self.id = id
        self.command = command
        self.arguments = arguments
    }
}

public enum ComputerPaths {
    public static var runtime: String { "/tmp/damson-computer-\(getuid())" }
    public static var socket: String { runtime + "/control.sock" }
    public static var artifacts: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Damson/Computer/sessions", isDirectory: true)
    }

    public static func prepareRuntime() throws {
        if mkdir(runtime, 0o700) != 0, errno != EEXIST {
            throw ComputerFailure("runtime", "Cannot create private runtime directory: \(errno)")
        }
        var info = stat()
        guard lstat(runtime, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700 else {
            throw ComputerFailure("runtime", "Runtime directory must be owned by this user, mode 0700, and not a symlink.")
        }
    }
}

public enum ComputerTransport {
    public static func call(_ request: ComputerRequest) throws -> Data {
        try ComputerPaths.prepareRuntime()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ComputerFailure("transport", "Cannot create socket.") }
        defer { close(fd) }
        configure(fd)
        if let error = bindOrConnectUnix(fd: fd, path: ComputerPaths.socket, listen: false) {
            throw ComputerFailure("unavailable", "Computer helper is unavailable. Run damson-computer start. \(error)")
        }
        try writeLine(try JSONEncoder().encode(request), fd: fd)
        guard case .line(let response) = readFramedLine(fd: fd, hardCap: 4 * 1024 * 1024) else {
            throw ComputerFailure("transport", "No complete response. The action may have executed; observe before retrying.")
        }
        return response
    }

    static func configure(_ fd: Int32) {
        disableSIGPIPE(fd)
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    static func writeLine(_ data: Data, fd: Int32) throws {
        let bytes = Array(data) + [UInt8(10)]
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw ComputerFailure("transport", "Socket write failed.") }
            offset += n
        }
    }
}
