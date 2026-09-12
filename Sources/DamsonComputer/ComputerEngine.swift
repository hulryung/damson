import AppKit

@MainActor
public final class ComputerEngine {
    public let sessions: ComputerSessionStore
    public let desktop = DesktopAccess()
    public var onChange: (() -> Void)?
    private var busy = false
    private var seen: [String: (ComputerRequest, Data)] = [:]
    private var order: [String] = []
    private var pending = Set<String>()

    public init(root: URL = ComputerPaths.artifacts) {
        sessions = ComputerSessionStore(root: root)
    }

    public func stop(reason: String = "requested") {
        sessions.stop(reason: reason)
        desktop.clearElements()
        onChange?()
    }

    public func interruptForInput(timestamp: TimeInterval, kind: String) {
        guard let session = sessions.session, timestamp >= session.inputStarted else { return }
        stop(reason: "external_input:\(kind)")
    }

    public func handle(_ request: ComputerRequest) async -> Data {
        if let (previous, data) = seen[request.id] {
            if previous.command == request.command, previous.arguments == request.arguments { return data }
            return response(request.id, failure: ComputerFailure("request_id_reused", "Request ID was already used with different arguments."))
        }
        guard !request.id.isEmpty, request.id.utf8.count <= 128 else {
            return response(request.id, failure: ComputerFailure("invalid_argument", "Request ID must contain 1...128 bytes."))
        }
        guard pending.insert(request.id).inserted else {
            return response(request.id, failure: ComputerFailure("in_progress", "This request is still running. Observe before retrying."))
        }
        defer { pending.remove(request.id); onChange?() }
        let logSession = sessions.session
        var result: Data
        do {
            if let logSession, Self.actions.contains(request.command) {
                try record(request, result: response(request.id, value: ["phase": "intent"]), session: logSession)
            }
            let value = try await execute(request)
            result = response(request.id, value: value)
        } catch {
            result = response(request.id, failure: error)
        }
        // Persist completion before returning. Payload text stays out of logs; the
        // response and screenshot paths are enough to diagnose actions without copying secrets.
        if let session = logSession ?? sessions.session, !["status", "apps", "permissions"].contains(request.command) {
            do { try record(request, result: result, session: session) }
            catch { result = response(request.id, failure: ComputerFailure("record_failed", "Action may have executed, but its log could not be saved: \(error). Observe before retrying.")) }
        }
        seen[request.id] = (request, result)
        order.append(request.id)
        if order.count > 256 { seen.removeValue(forKey: order.removeFirst()) }
        return result
    }

    private func execute(_ request: ComputerRequest) async throws -> [String: Any] {
        let args = request.arguments
        try validateArguments(request)
        switch request.command {
        case "status":
            sessions.expire()
            return ["helperPID": ProcessInfo.processInfo.processIdentifier, "protocolVersion": 1, "pauseReason": sessions.pauseReason as Any? ?? NSNull(), "paused": sessions.paused, "busy": busy, "session": publicSession(), "permissions": desktop.permissions()]
        case "setup-permissions":
            ComputerPermissionSetup.shared.present(destination: args["section"].flatMap(ComputerPrivacySettings.init(rawValue:)))
            return ["shown": true]
        case "permissions": return desktop.permissions(prompt: args["prompt"] == "true")
        case "apps": return ["apps": desktop.apps()]
        case "stop": stop(); return ["paused": true]
        case "resume": sessions.resume(); return ["paused": false]
        default: break
        }
        guard !busy else { throw ComputerFailure("busy", "An operation is in progress; status and stop remain available.") }
        switch request.command {
        case "acquire":
            let pid: Int32 = try integer(args, "pid")
            let value = try sessions.acquire(owner: required(args, "owner"), pid: pid,
                                             started: desktop.identity(pid), ttl: number(args, "ttl", default: 60))
            desktop.clearElements()
            return try dictionary(value)
        case "renew": return try dictionary(sessions.renew(args["session"], ttl: number(args, "ttl", default: 60)))
        case "release": try sessions.release(args["session"]); desktop.clearElements(); return ["released": true]
        default: break
        }
        let session = try sessions.require(args["session"])
        try desktop.validate(session)
        switch request.command {
        case "windows": return ["windows": desktop.windows(pid: session.targetPID)]
        case "focus": try desktop.focus(session)
        case "inspect": return try desktop.inspect(session)
        case "press": try desktop.press(required(args, "element"), session: session)
        case "click": try desktop.click(x: number(args, "x"), y: number(args, "y"), session: session)
        case "type":
            busy = true
            defer { busy = false }
            try await desktop.type(required(args, "text"), session: session) { [sessions] in
                _ = try sessions.require(session.token)
            }
        case "key": try desktop.key(required(args, "key"), session: session)
        case "scroll": try desktop.scroll(dx: integer(args, "dx", default: 0), dy: integer(args, "dy"), session: session)
        case "capture":
            let id: UInt32 = try integer(args, "window")
            busy = true
            defer { busy = false }
            let result = try await desktop.capture(session, windowID: id) { [sessions] in
                _ = try sessions.require(session.token)
            }
            _ = try sessions.require(session.token)
            return result
        default: throw ComputerFailure("unknown_command", "Unknown command: \(request.command)")
        }
        return ["dispatched": true, "verificationRequired": true]
    }

    public func publicSession() -> Any {
        guard let value = sessions.session else { return NSNull() }
        return ["owner": value.owner, "pid": value.targetPID, "expires": value.expires.timeIntervalSince1970,
                "artifacts": value.artifacts] as [String: Any]
    }

    private func validateArguments(_ request: ComputerRequest) throws {
        let schema: [String: Set<String>] = [
            "status": [], "apps": [], "stop": [], "resume": [], "setup-permissions": ["section"],
            "permissions": ["prompt"], "acquire": ["pid", "owner", "ttl"],
            "renew": ["session", "ttl"], "release": ["session"],
            "windows": ["session"], "focus": ["session"], "inspect": ["session"],
            "capture": ["session", "window"], "press": ["session", "element"],
            "click": ["session", "x", "y"], "type": ["session", "text"],
            "key": ["session", "key"], "scroll": ["session", "dx", "dy"]
        ]
        guard let allowed = schema[request.command] else {
            throw ComputerFailure("unknown_command", "Unknown command: \(request.command)")
        }
        let unknown = Set(request.arguments.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw ComputerFailure("invalid_argument", "Unknown arguments: \(unknown.sorted().joined(separator: ", "))")
        }
        if let section = request.arguments["section"], ComputerPrivacySettings(rawValue: section) == nil {
            throw ComputerFailure("invalid_argument", "Unknown permission section.")
        }
        if let prompt = request.arguments["prompt"], !["true", "false"].contains(prompt) {
            throw ComputerFailure("invalid_argument", "--prompt must be true or false.")
        }
    }

    private static let actions: Set<String> = ["focus", "press", "click", "type", "key", "scroll", "capture"]

    private func record(_ request: ComputerRequest, result: Data, session: ComputerSession) throws {
        var arguments = request.arguments
        arguments.removeValue(forKey: "session")
        if let text = arguments.removeValue(forKey: "text") { arguments["textUTF16Length"] = String(text.utf16.count) }
        let entry: [String: Any] = ["arguments": arguments, "time": Date().timeIntervalSince1970, "requestID": request.id,
                                    "command": request.command, "result": try JSONSerialization.jsonObject(with: result)]
        var line = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        line.append(10)
        let path = URL(fileURLWithPath: session.artifacts).appendingPathComponent("actions.jsonl")
        if !FileManager.default.fileExists(atPath: path.path) { try Data().write(to: path, options: .atomic) }
        let file = try FileHandle(forWritingTo: path)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: line)
        try file.synchronize()
    }

    private func dictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] ?? [:]
    }

    private func response(_ id: String, value: [String: Any] = [:], failure: Error? = nil) -> Data {
        var result: [String: Any] = ["id": id, "ok": failure == nil, "result": value]
        if let failure {
            result["error"] = ["code": (failure as? ComputerFailure)?.code ?? "operation_failed", "message": String(describing: failure)]
        }
        return (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data("{\"ok\":false}".utf8)
    }

    private func required(_ args: [String: String], _ key: String) throws -> String {
        guard let value = args[key] else { throw ComputerFailure("invalid_argument", "Missing --\(key).") }
        return value
    }

    private func number(_ args: [String: String], _ key: String, default fallback: Double? = nil) throws -> Double {
        if args[key] == nil, let fallback { return fallback }
        guard let value = Double(try required(args, key)), value.isFinite else {
            throw ComputerFailure("invalid_argument", "--\(key) must be a finite number.")
        }
        return value
    }

    private func integer<T: FixedWidthInteger>(_ args: [String: String], _ key: String, default fallback: T? = nil) throws -> T {
        if args[key] == nil, let fallback { return fallback }
        guard let value = T(try required(args, key)) else { throw ComputerFailure("invalid_argument", "--\(key) must be an integer.") }
        return value
    }
}
