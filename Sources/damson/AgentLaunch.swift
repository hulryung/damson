import DamsonTerminal
import Foundation

/// How damson opens a pane that runs an agent CLI.
///
/// The prompt, when there is one, goes in **argv** — never typed into the pane afterwards.
/// Claude Code offers no acknowledgment that typed input was received (the only ack,
/// `--replay-user-messages`, exists solely in headless stream-json mode), so a prompt
/// written to a live TUI 200ms before it reaches its input box lands nowhere and damson
/// cannot tell. Passing it at launch is the only delivery this side can be sure of.
///
/// damson also does NOT create worktrees: `claude -w <name>` owns that, and duplicating it
/// here would mean two things managing the same directories.
enum AgentLaunch {
    /// Absolute path to the `claude` binary. A GUI launch has a minimal PATH (LaunchServices
    /// does not run a login shell), so searching the usual install locations is more reliable
    /// than trusting PATH — but PATH is still the last resort, for installs we don't know about.
    static func claudeExecutable(env: [String: String]) -> String {
        let candidates = [
            "\(NSHomeDirectory())/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Fall back to resolving through the user's own PATH if we were given one.
        if let path = env["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = "\(dir)/claude"
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return "claude"
    }

    /// True when `claude` can be found at all — the menu items are disabled otherwise, so a
    /// machine without it doesn't get commands that open a pane and immediately print
    /// "command not found".
    static var isAvailable: Bool {
        let env = DamsonConfig.fromUserDefaults().env
        return FileManager.default.isExecutableFile(atPath: claudeExecutable(env: env))
    }

    /// Build the config for a pane running Claude Code.
    ///
    /// - `sessionID`: damson mints the session id rather than letting Claude Code pick one,
    ///   so the pane and the conversation share an identifier damson chose. That is what
    ///   makes `claude --resume <id>` possible later (Stage 4) when a pane's process did
    ///   not survive but its transcript did.
    /// - `label`: shown in Claude Code's own UI and in `claude agents --json`, so a human
    ///   reading either can tell which damson pane a session belongs to.
    static func config(cwd: String?, sessionID: UUID, label: String?) -> DamsonConfig {
        var config = DamsonConfig.fromUserDefaults()
        if let cwd { config.cwd = cwd }
        var argv = [claudeExecutable(env: config.env), "--session-id", sessionID.uuidString]
        if let label, !label.isEmpty { argv += ["--name", label] }
        config.argv = argv
        return config
    }

    /// A short, human-readable name for a pane started in `cwd` — the directory's last
    /// component, which is what a developer actually calls the project.
    static func label(for cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty ? nil : base
    }
}
