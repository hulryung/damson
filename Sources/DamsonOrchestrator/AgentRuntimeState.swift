import Foundation

/// The live state of a single agent session, as inferred by `ReadinessDetector`.
///
/// The scheduler dispatches a new task to an agent ONLY when its state is exactly
/// `.idle`. `.awaitingApproval` must never be confused with `.idle` — sending a task
/// into an approval prompt would corrupt the agent's pending decision.
public enum AgentRuntimeState: Equatable, Sendable {
    /// Process spawned, the agent's UI has not yet settled (splash / first paint).
    case starting
    /// Ready to accept a task (at its input prompt, quiescent).
    case idle
    /// Actively producing a turn.
    case working
    /// Blocked on a human approval/choice prompt (e.g. "Do you want to proceed? 1. Yes …").
    case awaitingApproval
    /// Blocked waiting for free-text input the orchestrator may fill (rare).
    case awaitingInput
    /// Process exited with code 0.
    case finished(Int32)
    /// Process exited nonzero, or the detector gave up.
    case errored(String)
}

public extension AgentRuntimeState {
    /// Terminal states free the agent's concurrency slot and trigger worktree finalize.
    var isTerminal: Bool {
        switch self {
        case .finished, .errored: return true
        default: return false
        }
    }

    /// Whether the scheduler may dispatch a task to an agent in this state.
    var acceptsTask: Bool { self == .idle }

    /// Short single-glyph status used in tab titles and the dashboard pill.
    var glyph: String {
        switch self {
        case .starting: return "◌"
        case .idle: return "●"
        case .working: return "⟳"
        case .awaitingApproval: return "⚠"
        case .awaitingInput: return "✎"
        case .finished: return "✓"
        case .errored: return "✗"
        }
    }
}
