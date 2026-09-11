import Foundation

public struct ComputerFailure: Error, CustomStringConvertible {
    public let code: String
    public let description: String
    public init(_ code: String, _ message: String) {
        self.code = code
        description = message
    }
}

public struct ComputerSession: Codable, Equatable {
    public let token: String
    public let owner: String
    public let targetPID: Int32
    public let targetStarted: String
    public let created: Date
    public var expires: Date
    public let artifacts: String
}

/// Accessed only on the helper's main queue. One lease covers the whole desktop,
/// including callers from unrelated Damson instances and workflow state directories.
public final class ComputerSessionStore {
    public private(set) var session: ComputerSession?
    public private(set) var paused = false
    private let root: URL
    private let now: () -> Date
    private let clockNow: () -> ContinuousClock.Instant
    private var deadline: ContinuousClock.Instant?

    public init(root: URL, now: @escaping () -> Date = Date.init,
                clockNow: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.root = root
        self.now = now
        self.clockNow = clockNow
    }

    @discardableResult
    public func expire() -> Bool {
        // Wall-clock dates are display metadata. ContinuousClock also advances
        // during sleep, and cannot extend a lease when system time moves backwards.
        if session != nil, let deadline, deadline <= clockNow() {
            session = nil
            self.deadline = nil
            return true
        }
        return false
    }

    public func acquire(owner: String, pid: Int32, started: String, ttl: Double) throws -> ComputerSession {
        expire()
        guard !paused else { throw ComputerFailure("paused", "Desktop control is paused. Resume it explicitly before acquiring a session.") }
        guard session == nil else { throw ComputerFailure("busy", "Desktop is owned by \(session!.owner).") }
        guard !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, owner.utf8.count <= 256,
              pid > 0, !started.isEmpty else {
            throw ComputerFailure("invalid_argument", "A nonempty owner (up to 256 bytes) and live app PID are required.")
        }
        try validateTTL(ttl)
        let token = UUID().uuidString
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let value = ComputerSession(token: token, owner: owner, targetPID: pid,
                                    targetStarted: started, created: now(),
                                    expires: now().addingTimeInterval(ttl), artifacts: directory.path)
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
        deadline = clockNow().advanced(by: .seconds(ttl))
        session = value
        return value
    }

    public func require(_ token: String?) throws -> ComputerSession {
        expire()
        guard !paused else { throw ComputerFailure("paused", "Desktop control was stopped by the user.") }
        guard let value = session, token == value.token else {
            throw ComputerFailure("invalid_session", "Session is missing, expired, or belongs to another caller. Acquire a new session.")
        }
        return value
    }

    public func renew(_ token: String?, ttl: Double) throws -> ComputerSession {
        var value = try require(token)
        try validateTTL(ttl)
        value.expires = now().addingTimeInterval(ttl)
        deadline = clockNow().advanced(by: .seconds(ttl))
        session = value
        return value
    }

    public func release(_ token: String?) throws {
        _ = try require(token)
        session = nil
        deadline = nil
    }

    public func stop() { session = nil; deadline = nil; paused = true }
    public func resume() { paused = false }

    private func validateTTL(_ ttl: Double) throws {
        guard ttl.isFinite, (5...300).contains(ttl) else {
            throw ComputerFailure("invalid_argument", "Session TTL must be between 5 and 300 seconds; renew it while working.")
        }
    }
}
