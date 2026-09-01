import AppKit

/// What a Claude Code session is doing right now, as damson is willing to display it.
///
/// This is the ONLY place Claude Code's status vocabulary is spelled out. It is a
/// vocabulary damson does not own — a future CLI release may add a state or rename one —
/// so the mapping is deliberately closed and total: anything unrecognized becomes `nil`
/// and the pane simply shows no badge. **Degrade to no badge, never to a wrong badge.**
/// A stale "idle" pill on an agent that is actually blocked is worse than no pill at all,
/// because the user acts on it.
///
/// Observed vocabulary (Claude Code 2.1.228, read out of the CLI itself):
/// `"busy" | "shell" | "idle" | "waiting"`.
public enum AgentBadge: String {
    /// The agent is working on a turn.
    case busy
    /// The agent is running a shell command (its Bash tool).
    case shell
    /// The agent is not working. NOTE: this conflates "finished the task", "asked a
    /// question and is waiting on a human", and "spawned but never prompted" — which is
    /// exactly why damson does not schedule work off it. It is a hint for a human's eyes.
    case idle
    /// The agent is blocked on something the user must answer.
    case waiting
    /// damson launched an agent here, but it has not published a session record yet — it is
    /// still starting, or stopped on one of Claude Code's own first-run prompts.
    ///
    /// This is damson's word, not Claude Code's, and it is the one case `init?(status:)`
    /// never produces. Without it a pane blocked before check-in is indistinguishable from
    /// a shell, and a fan-out reports "4 of 5 started" while the fifth waits for a keypress.
    case starting

    /// Map a raw `status` string from a session record. Returns nil for anything not in the
    /// known vocabulary so an unrecognized state renders as absent rather than as a guess —
    /// and `starting` is deliberately NOT among the strings accepted here, so a future CLI
    /// release that publishes that word cannot silently inherit damson's meaning for it.
    public init?(status: String) {
        switch status {
        case "busy": self = .busy
        case "shell": self = .shell
        case "idle": self = .idle
        case "waiting": self = .waiting
        default: return nil
        }
    }

    /// Short text drawn in the pill. Kept to a couple of glyphs — this sits over the
    /// terminal's own content and must not become a second status bar.
    public var label: String {
        switch self {
        case .busy: return "●"
        case .shell: return "❯"
        case .idle: return "○"
        case .waiting: return "?"
        case .starting: return "…"
        }
    }

    /// Spoken/AX description, and the tab-title suffix.
    public var describedAs: String {
        switch self {
        case .busy: return "working"
        case .shell: return "running a command"
        case .idle: return "idle"
        case .waiting: return "waiting for you"
        case .starting: return "starting"
        }
    }

    /// Only `waiting` earns attention — it is the one state that will not resolve without
    /// the user. Everything else is ambient and must stay quiet, or the badges become
    /// noise the user learns to ignore (and then misses the one that mattered).
    /// `starting` is ambient like the rest: the agent has not asked for anything yet, and a
    /// fan-out that alerted per task at launch would be pure noise.
    public var isAttention: Bool { self == .waiting }

    public var tint: NSColor {
        switch self {
        case .busy: return NSColor.systemBlue
        case .shell: return NSColor.systemTeal
        case .idle: return NSColor.systemGray
        case .waiting: return NSColor.systemOrange
        case .starting: return NSColor.systemGray
        }
    }
}
