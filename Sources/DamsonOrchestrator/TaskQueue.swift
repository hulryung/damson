import Foundation
import Combine

/// FIFO task queue, partitioned by lifecycle. Main-actor confined (the scheduler
/// and UI both touch it). `@Published` arrays drive the dashboard directly.
@MainActor
public final class TaskQueue: ObservableObject {
    @Published public private(set) var pending: [AgentTask] = []
    @Published public private(set) var running: [AgentTask] = []
    @Published public private(set) var completed: [AgentTask] = []

    public init() {}

    public var hasPending: Bool { !pending.isEmpty }

    public func enqueue(_ task: AgentTask) {
        var t = task
        t.status = .pending
        pending.append(t)
    }

    /// Pop the next pending task (FIFO) and move it to `running`.
    public func dequeue() -> AgentTask? {
        guard !pending.isEmpty else { return nil }
        var task = pending.removeFirst()
        task.status = .running
        task.startedAt = Date()
        running.append(task)
        return task
    }

    /// Move a running task to the completed list with a terminal status.
    public func finish(_ id: UUID, status: AgentTask.Status, at date: Date = Date()) {
        guard let idx = running.firstIndex(where: { $0.id == id }) else { return }
        var task = running.remove(at: idx)
        task.status = status
        task.finishedAt = date
        completed.append(task)
    }

    /// Remove a still-pending task (user reorder/cancel before it starts).
    public func removePending(_ id: UUID) {
        pending.removeAll { $0.id == id }
    }

    public func reorderPending(from source: Int, to dest: Int) {
        guard pending.indices.contains(source) else { return }
        let task = pending.remove(at: source)
        let clamped = min(max(dest, 0), pending.count)
        pending.insert(task, at: clamped)
    }

    /// Snapshot of every task across partitions (for persistence).
    public var allTasks: [AgentTask] { pending + running + completed }
}
