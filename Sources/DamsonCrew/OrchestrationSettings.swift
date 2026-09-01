import Foundation

/// Settings shared between damson's Orchestration preferences tab and `damson-crew`.
///
/// The two are separate processes, so the CLI has to read the **app's** defaults domain
/// explicitly — its own `UserDefaults.standard` is a different domain entirely, and reading
/// that would silently give every setting its default forever.
public struct OrchestrationSettings: Equatable {
    /// The app whose preferences these are.
    public static let domain = "app.damson.terminal"

    /// What `damson-crew run` starts when a task does not name its own command.
    public var agentCommand: [String]
    /// Pass `--dangerously-skip-permissions` to `claude`.
    ///
    /// On by default, and the name is the warning: it removes every confirmation the agent
    /// would otherwise ask for. It is the default because an agent stopped on a permission
    /// prompt is the most common way a fan-out stalls — the run looks alive while several
    /// tabs sit waiting for a keypress — and because someone opening a terminal to run
    /// agents in can see what they are doing. Anyone who wants the prompts turns it off.
    public var skipPermissions: Bool
    /// Post a notification when an agent becomes blocked on the user.
    public var notifyOnWaiting: Bool
    /// Also bring that agent's tab forward.
    public var focusOnWaiting: Bool
    /// Where worktrees are made. Empty means beside the repo, as `<repo>-worktrees`.
    public var worktreeRoot: String
    /// Pre-accept Claude Code's workspace-trust prompt for a worktree damson-crew created.
    ///
    /// Claude Code prompts on a git repository root it has not seen, and a worktree is one
    /// by definition — so without this a fan-out stops once per task with every agent
    /// waiting on a keypress. It applies only to worktrees this tool made itself, from a
    /// repository the user named, and only to Claude Code: codex and cursor-agent have
    /// their own gates and their own stores, which damson does not pretend to know.
    public var trustNewWorktrees: Bool

    public static let `default` = OrchestrationSettings(
        agentCommand: ["claude"], skipPermissions: true,
        notifyOnWaiting: true, focusOnWaiting: false, worktreeRoot: "",
        trustNewWorktrees: true)

    /// Read the app's preferences, falling back to the defaults for anything unset. Never
    /// throws and never fails: a coordinator must run whether or not the app has ever been
    /// opened to write a preference.
    public static func load(domain: String = OrchestrationSettings.domain) -> OrchestrationSettings {
        guard let defaults = UserDefaults(suiteName: domain) else { return .default }
        var s = OrchestrationSettings.default
        if let raw = defaults.string(forKey: Keys.agentCommand) {
            let parts = raw.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            if !parts.isEmpty { s.agentCommand = parts }
        }
        if defaults.object(forKey: Keys.skipPermissions) != nil {
            s.skipPermissions = defaults.bool(forKey: Keys.skipPermissions)
        }
        if defaults.object(forKey: Keys.notifyOnWaiting) != nil {
            s.notifyOnWaiting = defaults.bool(forKey: Keys.notifyOnWaiting)
        }
        if defaults.object(forKey: Keys.focusOnWaiting) != nil {
            s.focusOnWaiting = defaults.bool(forKey: Keys.focusOnWaiting)
        }
        if let root = defaults.string(forKey: Keys.worktreeRoot) { s.worktreeRoot = root }
        if defaults.object(forKey: Keys.trustNewWorktrees) != nil {
            s.trustNewWorktrees = defaults.bool(forKey: Keys.trustNewWorktrees)
        }
        return s
    }

    /// Preference keys, shared with the settings UI. Spelled once so the two sides cannot
    /// drift into writing and reading different names — which would fail silently, with the
    /// CLI simply never seeing anything the user changed.
    public enum Keys {
        public static let agentCommand    = "damson.orchestration.agentCommand"
        public static let skipPermissions = "damson.orchestration.skipPermissions"
        public static let notifyOnWaiting = "damson.orchestration.notifyOnWaiting"
        public static let focusOnWaiting  = "damson.orchestration.focusOnWaiting"
        public static let worktreeRoot    = "damson.orchestration.worktreeRoot"
        public static let trustNewWorktrees = "damson.orchestration.trustNewWorktrees"
    }
}
