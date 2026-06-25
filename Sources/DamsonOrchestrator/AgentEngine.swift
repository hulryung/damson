import Foundation

/// How a task prompt is delivered to a freshly-spawned agent.
public enum PromptDelivery: Sendable {
    /// The prompt is typed/pasted into the agent's input box once it reports `.idle`.
    case typeWhenIdle
    /// The prompt is passed as an argv argument at launch (batch tools, e.g. `aider -m`).
    case launchArgument
    /// No prompt is delivered (the launch command IS the work, e.g. a build script).
    case none
}

/// An engine-agnostic description of one CLI agent tool. Captures everything
/// tool-specific: how to launch it, how to feed it a prompt, and (for full-screen
/// TUIs) how to read its rendered state. New tools are added by conforming here —
/// nothing else in the orchestrator is tool-aware.
public protocol AgentEngine {
    /// Stable identifier persisted in `AgentTask.engineID` (e.g. "claude-code").
    var id: String { get }
    var displayName: String { get }

    /// `true` for long-running full-screen TUIs (Claude Code) that never return to a
    /// shell prompt between turns. For these, process/shell signals (foreground-job,
    /// OSC 133) are useless and `classify` MUST drive readiness from the screen.
    var usesLongRunningTUI: Bool { get }

    var promptDelivery: PromptDelivery { get }

    /// `true` if `launchArgv` already invokes a login shell (so the controller must NOT
    /// wrap it again). `false` (default) means the controller wraps argv in a login shell
    /// so brew/PATH resolve under a GUI launch.
    var launchesOwnShell: Bool { get }

    /// argv to launch inside the prepared worktree. For `.launchArgument` delivery,
    /// include the prompt here.
    func launchArgv(task: AgentTask, worktree: URL) -> [String]

    /// Environment overlay merged onto the base login-shell environment.
    func env(base: [String: String]) -> [String: String]

    /// Engine-specific readiness verdict from a screen snapshot.
    /// Return `nil` to defer to `ReadinessDetector`'s generic (process-signal) logic —
    /// the correct choice for non-TUI engines.
    func classify(_ snapshot: ReadinessSnapshot) -> AgentRuntimeState?

    /// When the agent is `.awaitingApproval`, an engine may auto-clear *benign* gates
    /// (e.g. a startup workspace-trust prompt) by returning the key names to send. Return
    /// `nil` for real task approvals so a human decides. Called at most once per gate entry.
    func autoResponseKeys(_ snapshot: ReadinessSnapshot) -> [String]?
}

public extension AgentEngine {
    var usesLongRunningTUI: Bool { false }
    var promptDelivery: PromptDelivery { .typeWhenIdle }
    var launchesOwnShell: Bool { false }
    func env(base: [String: String]) -> [String: String] { base }
    func classify(_ snapshot: ReadinessSnapshot) -> AgentRuntimeState? { nil }
    func autoResponseKeys(_ snapshot: ReadinessSnapshot) -> [String]? { nil }
}

/// Built-in engine registry. Keyed by `id`. UI/controller resolve engines from here.
public enum AgentEngineRegistry {
    public static let all: [AgentEngine] = [
        ClaudeCodeEngine(),
        GenericShellEngine(),
    ]

    public static func engine(id: String) -> AgentEngine? {
        all.first { $0.id == id }
    }
}
