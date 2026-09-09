import DamsonControl
import Foundation

public final class WorkflowRunner {
    private let client: DamsonClient
    private let executable: String
    private let store: WorkflowStore
    private let lock: WorkflowLock
    public private(set) var state: WorkflowState

    public init(workflow: Workflow, directory: URL, executable: String, client: DamsonClient) throws {
        try workflow.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        store = WorkflowStore(root: directory)
        lock = try WorkflowLock(directory.appendingPathComponent("coordinator.lock"))
        state = try store.prepare(workflow: workflow)
        self.executable = executable
        self.client = client
    }

    /// A tick can be repeated after a crash, including a crash between journal and spawn.
    public func tick() throws {
        for task in state.workflow.tasks where state.tasks[task.id]?.status == .running {
            try observe(task)
        }
        state.blockDescendants()
        for task in state.readyTasks() { try dispatch(task) }
        try store.save(state, to: store.stateURL)
    }

    private func dispatch(_ task: WorkflowTask) throws {
        let token = UUID().uuidString
        let directory = store.attemptURL(token)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousLog = state.tasks[task.id]?.attempt.map {
            store.attemptURL($0).appendingPathComponent("output.log").path
        }
        try store.save(WorkflowAttempt(token: token, task: task, previousLog: previousLog),
                       to: directory.appendingPathComponent("input.json"))
        state.tasks[task.id]?.status = .running
        state.tasks[task.id]?.attempts += 1
        state.tasks[task.id]?.attempt = token
        state.tasks[task.id]?.pane = nil
        state.tasks[task.id]?.dispatchedAt = Date()
        if let previousMessage = state.tasks[task.id]?.message {
            state.tasks[task.id]?.message = "retrying after: " + previousMessage
        }
        // Record the token BEFORE IPC. A timeout may still create a pane.
        try store.save(state, to: store.stateURL)
        spawn(task, token: token)
    }

    private func spawn(_ task: WorkflowTask, token: String) {
        let spec = SpawnSpec(cwd: task.cwd,
            argv: [executable, "workflow-worker", store.attemptURL(token).path],
            key: "crew:workflow:\(state.runID):\(token)",
            title: "\(task.id) [\(state.tasks[task.id]?.attempts ?? 0)]",
            group: "\(state.workflow.name)-\(state.runID.prefix(8))")
        switch client.send(.spawnPane(spec)) {
        case .success(let response) where response.ok:
            state.tasks[task.id]?.pane = response.pane?.id
        case .success(let response): state.tasks[task.id]?.message = response.err ?? "spawn refused"
        case .failure(let error): state.tasks[task.id]?.message = error.message
        }
    }

    private func observe(_ task: WorkflowTask) throws {
        guard let row = state.tasks[task.id], let token = row.attempt, let dispatched = row.dispatchedAt else {
            throw CrewError("invalid running task state: \(task.id)")
        }
        let directory = store.attemptURL(token)
        let resultURL = directory.appendingPathComponent("result.json")
        if FileManager.default.fileExists(atPath: resultURL.path) {
            let result = try store.read(WorkflowResult.self, from: resultURL)
            guard result.token == token else { throw CrewError("attempt result identity mismatch: \(task.id)") }
            finish(task, succeeded: result.succeeded, message: result.message, retryable: result.retryable)
            return
        }
        // A held worker lock is authoritative evidence of live execution, including after
        // coordinator or app restarts. PID reuse cannot impersonate that worker.
        if try inspectUnlocked(task, token: token, dispatched: dispatched, directory: directory) {
            spawn(task, token: token)
        }
    }

    private func inspectUnlocked(_ task: WorkflowTask, token: String, dispatched: Date,
                                 directory: URL) throws -> Bool {
        guard let workerLock = try WorkflowLock.acquireIfAvailable(directory.appendingPathComponent("worker.lock")) else {
            return false
        }
        defer { withExtendedLifetime(workerLock) {} }
        let resultURL = directory.appendingPathComponent("result.json")
        // A worker can publish between our initial read and acquisition of its lock.
        if FileManager.default.fileExists(atPath: resultURL.path) {
            let result = try store.read(WorkflowResult.self, from: resultURL)
            guard result.token == token else { throw CrewError("attempt result identity mismatch: \(task.id)") }
            finish(task, succeeded: result.succeeded, message: result.message, retryable: result.retryable)
            return false
        }
        let started = FileManager.default.fileExists(atPath: directory.appendingPathComponent("started.json").path)
        if started || Date().timeIntervalSince(dispatched) > 30 {
            let message = started ? "worker exited without a result" : "worker did not start within 30 seconds"
            try store.save(WorkflowResult(token: token, succeeded: false, message: message, retryable: !started), to: resultURL)
            finish(task, succeeded: false, message: message, retryable: !started)
            return false
        }
        return true
    }

    private func finish(_ task: WorkflowTask, succeeded: Bool, message: String, retryable: Bool = true) {
        let retry = retryable && !succeeded && (state.tasks[task.id]?.attempts ?? 0) < task.maxAttempts
        state.tasks[task.id]?.status = succeeded ? .succeeded : (retry ? .pending : .failed)
        state.tasks[task.id]?.message = message
    }
}
