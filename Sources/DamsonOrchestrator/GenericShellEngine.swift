import Foundation

/// Engine for non-TUI tools and plain shell commands (build scripts, `aider -m`,
/// linters, test runs). These run as a foreground job and return to the shell prompt
/// when done, so readiness is driven by process/shell signals — `classify` returns
/// nil and `ReadinessDetector` uses its generic (Layer 0–2) path.
public struct GenericShellEngine: AgentEngine {
    public init() {}

    public var id: String { "shell" }
    public var displayName: String { "Shell Command" }
    public var usesLongRunningTUI: Bool { false }
    /// The task prompt IS the command line; it's passed via the launch argv.
    public var promptDelivery: PromptDelivery { .launchArgument }
    public var launchesOwnShell: Bool { true }

    public func launchArgv(task: AgentTask, worktree: URL) -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let cmd = task.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty prompt → an interactive login shell tab (Cmd-T "new session"); otherwise
        // run the prompt as a one-shot command line.
        return cmd.isEmpty ? [shell, "-l"] : [shell, "-l", "-c", cmd]
    }

    // classify defaults to nil → generic detector path.
}
