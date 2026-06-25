import Foundation
import DamsonControl
#if canImport(Darwin)
import Darwin
#endif

/// NDJSON wire format for orchard ↔ orchard-cli. Unlike damson's hand-rolled Wire (kept
/// Rust-compatible), this uses Codable directly — there's no cross-language constraint.
///
/// A command is a flat optional-bag keyed by `cmd`; the server switches on `cmd`.
public struct OrchardCommand: Codable, Sendable {
    public var cmd: String
    public var path: String?        // add-workspace
    public var workspace: Int?      // add-task / list-agents (workspace index)
    public var engine: String?      // add-task
    public var title: String?       // add-task
    public var prompt: String?      // add-task
    public var agent: String?       // agent short id (from list-agents)
    public var text: String?        // send-text
    public var keys: [String]?      // send-key
    public var count: Int?          // set-concurrency

    public init(cmd: String, path: String? = nil, workspace: Int? = nil, engine: String? = nil,
                title: String? = nil, prompt: String? = nil, agent: String? = nil,
                text: String? = nil, keys: [String]? = nil, count: Int? = nil) {
        self.cmd = cmd; self.path = path; self.workspace = workspace; self.engine = engine
        self.title = title; self.prompt = prompt; self.agent = agent; self.text = text
        self.keys = keys; self.count = count
    }

    public func jsonLine() -> String {
        let data = (try? JSONEncoder().encode(self)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

public struct WorkspaceInfo: Codable, Sendable {
    public let index: Int
    public let name: String
    public let path: String
    public let agentCount: Int
    public init(index: Int, name: String, path: String, agentCount: Int) {
        self.index = index; self.name = name; self.path = path; self.agentCount = agentCount
    }
}

public struct AgentInfo: Codable, Sendable {
    public let id: String          // short id (8 chars)
    public let workspace: Int
    public let title: String
    public let engine: String
    public let state: String
    public let branch: String?
    public init(id: String, workspace: Int, title: String, engine: String, state: String, branch: String?) {
        self.id = id; self.workspace = workspace; self.title = title
        self.engine = engine; self.state = state; self.branch = branch
    }
}

public struct OrchardResponse: Codable, Sendable {
    public var ok: Bool
    public var err: String?
    public var message: String?
    public var workspaces: [WorkspaceInfo]?
    public var agents: [AgentInfo]?
    public var output: String?

    public init(ok: Bool, err: String? = nil, message: String? = nil,
                workspaces: [WorkspaceInfo]? = nil, agents: [AgentInfo]? = nil, output: String? = nil) {
        self.ok = ok; self.err = err; self.message = message
        self.workspaces = workspaces; self.agents = agents; self.output = output
    }

    public static func ok(_ message: String? = nil) -> Self { .init(ok: true, message: message) }
    public static func error(_ msg: String) -> Self { .init(ok: false, err: msg) }
}

// MARK: - Runtime dir / discovery

/// Directory holding orchard control sockets (`{pid}.sock`). Per-user, 0700.
public func orchardRuntimeDir() -> String {
    let env = ProcessInfo.processInfo.environment
    let base: String
    if let xdg = env["XDG_RUNTIME_DIR"], !xdg.isEmpty {
        base = xdg
    } else if let tmp = env["TMPDIR"], !tmp.isEmpty {
        base = (tmp as NSString).deletingLastPathComponent
    } else {
        base = "/tmp"
    }
    return (base as NSString).appendingPathComponent("orchard-\(getuid())")
}

public struct OrchardInstance: Sendable {
    public let pid: Int
    public let socketPath: String
    public let mtime: Date?
}

/// All live orchard instances, newest first.
public func listOrchardInstances() -> [OrchardInstance] {
    let dir = orchardRuntimeDir()
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
    var out: [OrchardInstance] = []
    for name in names where name.hasSuffix(".sock") {
        guard let pid = Int(name.dropLast(5)), pid > 0 else { continue }
        let path = (dir as NSString).appendingPathComponent(name)
        let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        out.append(OrchardInstance(pid: pid, socketPath: path, mtime: mtime))
    }
    return out.sorted { ($0.mtime ?? .distantPast) > ($1.mtime ?? .distantPast) }
}

// MARK: - Client

public enum OrchardClientError: Error, CustomStringConvertible {
    case noInstance
    case io(String)
    case decode(String)
    public var description: String {
        switch self {
        case .noInstance: return "no running Orchard instance found"
        case .io(let m): return m
        case .decode(let m): return "decode failed: \(m)"
        }
    }
}

/// Send one command to a specific socket and decode the response.
public func orchardSend(socketPath: String, command: OrchardCommand,
                        timeout: TimeInterval = 5.0) -> Result<OrchardResponse, OrchardClientError> {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return .failure(.io("socket() failed: errno=\(errno)")) }
    defer { close(fd) }
    if let err = bindOrConnectUnix(fd: fd, path: socketPath, listen: false) {
        return .failure(.io(err))
    }
    let sec = Int(timeout)
    var tv = timeval(tv_sec: sec, tv_usec: suseconds_t(Int32((timeout - Double(sec)) * 1_000_000)))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))

    var req = Array(command.jsonLine().utf8)
    req.append(0x0A)
    var sent = 0
    while sent < req.count {
        let n = req.withUnsafeBufferPointer { write(fd, $0.baseAddress!.advanced(by: sent), $0.count - sent) }
        if n <= 0 { return .failure(.io("write failed errno=\(errno)")) }
        sent += n
    }

    var data = Data()
    var buf = [UInt8](repeating: 0, count: 65_536)
    while true {
        let n = buf.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, $0.count) }
        if n <= 0 { break }
        data.append(contentsOf: buf[0..<n])
        if data.last == 0x0A { break }
    }
    if let nl = data.firstIndex(of: 0x0A) { data = data.prefix(upTo: nl) }
    guard !data.isEmpty else { return .failure(.io("server closed without response")) }
    do { return .success(try JSONDecoder().decode(OrchardResponse.self, from: data)) }
    catch { return .failure(.decode("\(error)")) }
}

/// Send to the most-recent live instance (or a specific pid).
public func orchardSend(command: OrchardCommand, pid: Int? = nil,
                        timeout: TimeInterval = 5.0) -> Result<OrchardResponse, OrchardClientError> {
    let instances = listOrchardInstances()
    let target: OrchardInstance?
    if let pid { target = instances.first { $0.pid == pid } }
    else { target = instances.first }
    guard let t = target else { return .failure(.noInstance) }
    return orchardSend(socketPath: t.socketPath, command: command, timeout: timeout)
}
