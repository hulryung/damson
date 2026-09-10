import Darwin
import Foundation

/// Advisory locks are held by open descriptors, never inferred from a PID file.
enum WorkflowLockError: Error, CustomStringConvertible {
    case busy(String)
    var description: String {
        switch self { case .busy(let path): return "workflow is already being operated: \(path)" }
    }
}

final class WorkflowLock {
    static func acquireIfAvailable(_ url: URL) throws -> WorkflowLock? {
        do { return try WorkflowLock(url) } catch WorkflowLockError.busy { return nil }
    }

    private let descriptor: Int32
    init(_ url: URL) throws {
        descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CrewError("cannot open workflow lock: \(url.path)") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let reason = errno
            close(descriptor)
            if reason == EWOULDBLOCK { throw WorkflowLockError.busy(url.path) }
            throw CrewError("cannot acquire workflow lock: \(url.path) (errno \(reason))")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

struct WorkflowAttempt: Codable {
    var token: String
    var task: WorkflowTask
    var previousLog: String?
}

struct WorkflowResult: Codable {
    var token: String
    var succeeded: Bool
    var message: String
    var retryable = true
    var finishedAt = Date()
}

struct WorkflowStore {
    let root: URL
    var stateURL: URL { root.appendingPathComponent("state.json") }
    func attemptURL(_ token: String) -> URL { root.appendingPathComponent("attempts/\(token)") }

    func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    func prepare(workflow: Workflow) throws -> WorkflowState {
        if FileManager.default.fileExists(atPath: stateURL.path) {
            let state = try read(WorkflowState.self, from: stateURL)
            guard state.version == 1, state.workflow == workflow,
                  Set(state.tasks.keys) == Set(workflow.tasks.map(\.id)) else {
                throw CrewError("saved workflow differs from this plan; use a new --state directory")
            }
            guard UUID(uuidString: state.runID) != nil else { throw CrewError("invalid saved run identity") }
            for task in workflow.tasks {
                guard let row = state.tasks[task.id], row.attempts >= 0, row.attempts <= task.maxAttempts else {
                    throw CrewError("invalid saved task attempt count")
                }
                if let attempt = row.attempt, UUID(uuidString: attempt) == nil {
                    throw CrewError("invalid saved attempt identity")
                }
                if row.status == .running && (row.attempt == nil || row.dispatchedAt == nil || row.attempts == 0) {
                    throw CrewError("running task has no saved attempt")
                }
            }
            return state
        }
        let state = WorkflowState(workflow: workflow)
        try save(state, to: stateURL)
        return state
    }
}
