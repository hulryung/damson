import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// `damsonRuntimeDir()` — the directory where the damson control socket lives.
/// Priority:
///   1. `$XDG_RUNTIME_DIR/damson`
///   2. `$TMPDIR/damson-{uid}` (macOS default — TMPDIR is always set)
///   3. `/tmp/damson-{uid}` (last-resort fallback)
/// (The directory convention derives from Rust halite's `runtime_dir`.)
public func damsonRuntimeDir() -> String {
    let env = ProcessInfo.processInfo.environment
    if let xdg = env["XDG_RUNTIME_DIR"], !xdg.isEmpty {
        return (xdg as NSString).appendingPathComponent("damson")
    }
    let uid = getuid()
    if let tmp = env["TMPDIR"], !tmp.isEmpty {
        // TMPDIR usually has a trailing slash — NSString cleans it up.
        return (tmp as NSString).appendingPathComponent("damson-\(uid)")
    }
    return "/tmp/damson-\(uid)"
}

/// A single damson instance discovered on disk.
public struct DamsonInstance: Sendable {
    public let pid: Int
    public let socketPath: String
    public let mtime: Date?
}

/// List of running damson instances (newest first).
/// "Running" = the socket file exists + connect does not immediately return `ECONNREFUSED`.
public func listDamsonInstances() -> [DamsonInstance] {
    let dir = damsonRuntimeDir()
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: dir) else {
        return []
    }
    var found: [DamsonInstance] = []
    for name in names {
        guard name.hasSuffix(".sock") else { continue }
        let stem = String(name.dropLast(5))
        guard let pid = Int(stem), pid > 0 else { continue }
        let path = (dir as NSString).appendingPathComponent(name)
        guard isSocketLive(path: path) else { continue }
        let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        found.append(DamsonInstance(pid: pid, socketPath: path, mtime: mtime))
    }
    found.sort { (a, b) in
        let am = a.mtime ?? .distantPast
        let bm = b.mtime ?? .distantPast
        return am > bm
    }
    return found
}

public struct PickSocketError: Error, CustomStringConvertible, Equatable, Sendable {
    public let message: String
    public init(_ m: String) { self.message = m }
    public var description: String { message }
}

/// If `--pid` is given, the matching instance; otherwise the instance with the most recent mtime.
public func pickDamsonSocket(pid: Int?) -> Result<String, PickSocketError> {
    let instances = listDamsonInstances()
    if let want = pid {
        if let m = instances.first(where: { $0.pid == want }) {
            return .success(m.socketPath)
        }
        return .failure(PickSocketError("no damson instance with pid \(want)"))
    }
    if let first = instances.first {
        return .success(first.socketPath)
    }
    return .failure(PickSocketError(
        "no running damson instance found (try `damson-cli --list-instances`)"
    ))
}

/// Attempts to connect and immediately disconnects. Returns true if alive.
public func isSocketLive(path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    return bindOrConnectUnix(fd: fd, path: path, listen: false) == nil
}
