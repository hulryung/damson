import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A single round-trip where the client sends one command and reads one response.
/// The timeout applies to connect / read / write individually.
/// Connect to `socketPath` → write a JSON line → read one line → parse.
public enum SocketIOError: Error, CustomStringConvertible {
    case connect(String)
    case write(String)
    case read(String)
    case decode(String)
    case timeout

    public var description: String {
        switch self {
        case .connect(let m): return "connect: \(m)"
        case .write(let m): return "write: \(m)"
        case .read(let m): return "read: \(m)"
        case .decode(let m): return "decode: \(m)"
        case .timeout: return "timeout"
        }
    }
}

public func sendCommand(
    socketPath: String,
    commandJSON: String,
    timeout: TimeInterval = 5.0
) -> Result<ControlResponse, SocketIOError> {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        return .failure(.connect("socket() failed: errno=\(errno)"))
    }
    defer { close(fd) }

    if let err = bindOrConnectUnix(fd: fd, path: socketPath, listen: false) {
        return .failure(.connect(err))
    }

    let sec = Int(timeout)
    let usec = Int32((timeout - Double(sec)) * 1_000_000)
    var tv = timeval(tv_sec: sec, tv_usec: suseconds_t(usec))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))

    // Request: JSON + \n
    var req = Array(commandJSON.utf8)
    req.append(0x0A)
    var sent = 0
    while sent < req.count {
        let n = req.withUnsafeBufferPointer { buf -> Int in
            write(fd, buf.baseAddress!.advanced(by: sent), buf.count - sent)
        }
        if n <= 0 {
            return .failure(.write("write() returned \(n), errno=\(errno)"))
        }
        sent += n
    }

    // Read until \n (or EOF). Only one response, so 64KB is plenty.
    var buf = [UInt8](repeating: 0, count: 65_536)
    var got = 0
    while got < buf.count {
        let n = buf.withUnsafeMutableBufferPointer { p -> Int in
            read(fd, p.baseAddress!.advanced(by: got), p.count - got)
        }
        if n <= 0 { break }
        got += n
        if buf[..<got].contains(0x0A) { break }
    }
    let endIdx = buf[..<got].firstIndex(of: 0x0A) ?? got
    let data = Data(buf[..<endIdx])
    guard !data.isEmpty else {
        return .failure(.read("server closed without response"))
    }
    do {
        let resp = try JSONDecoder().decode(ControlResponse.self, from: data)
        return .success(resp)
    } catch {
        return .failure(.decode("\(error)"))
    }
}

/// Fills in `sockaddr_un`. listen=false → connect, true → bind+listen.
/// Returns nil on success, an error message on failure.
public func bindOrConnectUnix(fd: Int32, path: String, listen doListen: Bool) -> String? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let cap = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < cap else {
        return "path too long (\(bytes.count) >= \(cap) bytes)"
    }
    // Step 1: fill in addr.sun_path (standalone & access).
    withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
        let dst = UnsafeMutableRawPointer(tuplePtr).assumingMemoryBound(to: CChar.self)
        for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
        dst[bytes.count] = 0
    }
    // Step 2: reinterpret the whole addr pointer as sockaddr for the syscall (separate access).
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result: Int32 = withUnsafePointer(to: &addr) { ap -> Int32 in
        ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa -> Int32 in
            doListen ? bind(fd, sa, len) : connect(fd, sa, len)
        }
    }
    if result != 0 {
        return "\(doListen ? "bind" : "connect")() failed: errno=\(errno) (\(String(cString: strerror(errno))))"
    }
    if doListen {
        if Darwin.listen(fd, 16) != 0 {
            return "listen() failed: errno=\(errno)"
        }
    }
    return nil
}
