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
public enum AgentLaunch {
    /// Absolute path to the `claude` binary. A GUI launch has a minimal PATH (LaunchServices
    /// does not run a login shell), so searching the usual install locations is more reliable
    /// than trusting PATH — but PATH is still the last resort, for installs we don't know about.
    public static func claudeExecutable(env: [String: String]) -> String {
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
    public static func isAvailable(env: [String: String]) -> Bool {
        FileManager.default.isExecutableFile(atPath: claudeExecutable(env: env))
    }

    /// Build the config for a pane running Claude Code.
    ///
    /// - `sessionID`: damson mints the session id rather than letting Claude Code pick one,
    ///   so the pane and the conversation share an identifier damson chose. That is what
    ///   makes `claude --resume <id>` possible later (Stage 4) when a pane's process did
    ///   not survive but its transcript did.
    /// - `label`: shown in Claude Code's own UI and in `claude agents --json`, so a human
    ///   reading either can tell which damson pane a session belongs to.
    /// - `base`: the user's ordinary pane config (font, theme, env…). Passed in rather than
    ///   read here, so this stays a pure function of its inputs — reading UserDefaults is
    ///   the app's job, and keeping it out is what makes this testable at all.
    public static func config(base: DamsonConfig, cwd: String?,
                              sessionID: UUID, label: String?) -> DamsonConfig {
        var config = base
        if let cwd { config.cwd = cwd }
        var argv = [claudeExecutable(env: config.env), "--session-id", sessionID.uuidString]
        if let label, !label.isEmpty { argv += ["--name", label] }
        config.argv = argv
        return config
    }

    /// Turn a saved argv into the one to run when the pane's process did NOT survive a
    /// restart — the keeper never answered, or the child died while held.
    ///
    /// For a Claude Code pane damson minted the session id, so `--session-id X` becomes
    /// `--resume X`: the pane comes back attached to its own transcript rather than as a
    /// blank conversation in the right directory. Anything else is re-run verbatim; damson
    /// has no idea how another program resumes, and inventing a flag would be worse than
    /// starting it fresh.
    /// A Claude Code pane comes back as a NEW conversation in the same directory, not as a
    /// resumed one. That is a deliberate retreat, not an oversight:
    ///
    /// Rewriting `--session-id X` to `--resume X` was tried and measured. It loses the pane.
    /// With no transcript, `claude --resume X` prints "No conversation found" and exits;
    /// with a real transcript it can still exit ("No deferred tool marker found in the
    /// resumed session…"). A pane whose process exits on startup closes — so the user ends
    /// up with no pane at all, which is worse than the login shell this replaced. Re-running
    /// `--session-id X` is no safer: an id whose conversation already exists is a conflict.
    ///
    /// So the session-identity flags are dropped and the program restarts clean. What
    /// persists is damson's own pane id, which is the identifier this repo controls; the
    /// conversation is one `/resume` away inside the pane, chosen by a human who can see
    /// whether it worked.
    public static func restartArgv(_ saved: [String]) -> [String] {
        guard isClaude(saved.first) else { return saved }
        var out: [String] = []
        var i = 0
        while i < saved.count {
            // Drop the flag AND its value; a bare trailing flag just disappears.
            if saved[i] == "--session-id" || saved[i] == "--resume" || saved[i] == "-r" {
                i += 2
                continue
            }
            out.append(saved[i])
            i += 1
        }
        return out
    }

    /// True when argv[0] looks like the Claude Code CLI — matched on the executable's NAME,
    /// so it holds for any install location, and never on a substring of a path (a pane
    /// running `/Users/claude/bin/vim` is not Claude Code).
    static func isClaude(_ executable: String?) -> Bool {
        guard let executable else { return false }
        return (executable as NSString).lastPathComponent == "claude"
    }

    /// A short, human-readable name for a pane started in `cwd` — the directory's last
    /// component, which is what a developer actually calls the project.
    public static func label(for cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty ? nil : base
    }
}
