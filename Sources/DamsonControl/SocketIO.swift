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

/// Disable SIGPIPE for this socket: a `write()` to a peer that has closed then returns
/// EPIPE (an errno the write loops handle) instead of raising SIGPIPE, whose default
/// disposition would terminate the whole process. Without this a `damson-cli` client that
/// disconnects before reading the reply could crash the damson app mid-response.
public func disableSIGPIPE(_ fd: Int32) {
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
}

/// Outcome of reading one newline-framed message off a socket.
public enum FramedLineResult {
    /// A full line was read; payload is the bytes before the newline.
    case line(Data)
    /// The stream closed (EOF) before a newline. Payload is whatever preceded it.
    case eof(Data)
    /// The peer sent more than `hardCap` bytes without a newline — refused.
    case tooLong
    /// A read timed out (SO_RCVTIMEO fired) with no progress.
    case timeout
    /// read() failed with this errno.
    case error(Int32)
}

/// Read from `fd` until a newline (0x0A) or EOF, into a buffer that grows as needed
/// so a response larger than any fixed stack buffer isn't silently truncated (e.g. a
/// `dump-grid` of a large window — CJK cells are 3 bytes each in UTF-8, so a modest
/// Korean grid easily exceeds 64 KB). `hardCap` bounds memory against an unterminated
/// or hostile peer. Only the newly read region is scanned for the newline each pass
/// (not the whole accumulated buffer), so framing stays O(total bytes), not O(n²).
/// EINTR is retried transparently; a timeout is reported distinctly from EOF/error.
public func readFramedLine(fd: Int32, hardCap: Int = 16 * 1024 * 1024) -> FramedLineResult {
    var acc = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 65_536)
    var searchStart = 0
    while true {
        let n = chunk.withUnsafeMutableBufferPointer { p -> Int in
            read(fd, p.baseAddress, p.count)
        }
        if n > 0 {
            acc.append(contentsOf: chunk[0..<n])
            if let nl = acc[searchStart...].firstIndex(of: 0x0A) {
                return .line(Data(acc[..<nl]))
            }
            searchStart = acc.count
            if acc.count > hardCap { return .tooLong }
        } else if n == 0 {
            return .eof(Data(acc))
        } else {
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return .timeout }
            return .error(errno)
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
    disableSIGPIPE(fd)

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
        if n < 0 {
            if errno == EINTR { continue }   // interrupted before any bytes moved — retry
            return .failure(.write("write() failed, errno=\(errno)"))
        }
        if n == 0 {
            return .failure(.write("write() returned 0"))
        }
        sent += n
    }

    // Read one newline-framed response into a growable buffer (a large dump-grid can
    // exceed any fixed size). The 5s SO_RCVTIMEO above surfaces as `.timeout`.
    let data: Data
    switch readFramedLine(fd: fd) {
    case .line(let d):
        data = d
    case .eof(let d):
        guard !d.isEmpty else { return .failure(.read("server closed without response")) }
        data = d   // stream closed mid-line — try to decode the partial payload
    case .tooLong:
        return .failure(.read("response exceeded size limit without a newline"))
    case .timeout:
        return .failure(.timeout)
    case .error(let e):
        return .failure(.read("read() failed, errno=\(e)"))
    }
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
