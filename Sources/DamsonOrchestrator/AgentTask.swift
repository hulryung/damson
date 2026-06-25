import Foundation

/// A unit of work to assign to an agent. Persisted as part of an `OrchestratorRun`.
public struct AgentTask: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending        // queued, not yet assigned
        case running        // delivered to an agent
        case completed      // agent finished (process exited 0 or marked done)
        case failed         // agent errored
        case interrupted    // app quit / cancelled mid-flight
    }

    public let id: UUID
    /// Short human label, used for the tab title and the worktree branch slug.
    public var title: String
    /// The full prompt delivered to the agent once it is idle.
    public var prompt: String
    /// Which `AgentEngine` runs this task (e.g. "claude-code", "shell").
    public var engineID: String
    /// Repo the task operates on; the worktree forks from this repo's pinned base ref.
    public var baseRepoPath: String
    /// Optional explicit branch name; otherwise derived from `title`.
    public var branchHint: String?
    public var status: Status

    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        prompt: String,
        engineID: String,
        baseRepoPath: String,
        branchHint: String? = nil,
        status: Status = .pending,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.engineID = engineID
        self.baseRepoPath = baseRepoPath
        self.branchHint = branchHint
        self.status = status
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// Filesystem/branch-safe slug derived from the title (or branchHint).
    public var slug: String {
        let source = branchHint ?? title
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyz0123456789-")
        let lowered = source.lowercased()
        var out = ""
        var lastDash = false
        for scalar in lowered.unicodeScalars {
            if allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastDash = (scalar == "-")
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "task" : String(trimmed.prefix(40))
    }
}
