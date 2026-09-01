import Foundation

/// What damson can say about the agent in a pane.
///
/// The case that earns this type is `starting`. Claude Code publishes its session record
/// only once it is past its own startup prompts, so an agent stopped on a first-run consent
/// screen — waiting for a keypress — had no record, and therefore no badge, no `appeared`
/// event, and nothing for a coordinator to escalate. Measured on 0.6.0: a full minute of
/// silence on a pane that was blocked the whole time.
///
/// damson **spawned** those panes, so it knows what it asked them to run. That knowledge is
/// the entire difference between "no agent here" and "an agent that has not checked in yet".
public enum AgentPresence: Equatable {
    /// Not an agent pane, or not one damson can speak for.
    case none
    /// Launched on an agent that publishes records, but nothing has been published yet.
    case starting
    /// The raw `status` from the session record. Forwarded rather than interpreted, so a
    /// driver is not limited to the states damson happens to draw.
    case reported(String)

    /// Decide from the record — if there is one — and what the pane was launched on.
    ///
    /// A record always wins: it is the program speaking for itself, and anything inferred
    /// from argv is a guess by comparison.
    public static func of(row: ClaudeSessionRow?, argv: [String]) -> AgentPresence {
        if let row { return .reported(row.status) }
        return publishesRecords(argv: argv) ? .starting : .none
    }

    /// Whether a pane launched on this argv will eventually publish a session record.
    ///
    /// Deliberately only `claude`. damson happily runs `codex`, `grok` and `cursor-agent`,
    /// but none of them publish anything — a pane on one of those would sit in `starting`
    /// for its entire life, which is a permanently wrong badge. `AgentBadge`'s whole rule is
    /// to degrade to no badge rather than to a wrong one, and that applies here too.
    static func publishesRecords(argv: [String]) -> Bool {
        guard let program = argv.first, !program.isEmpty else { return false }
        // The whole program name, never a substring: `claude-helper` and `myclaude` are not
        // Claude Code, and a badge on them would be a lie damson could not withdraw.
        return (program as NSString).lastPathComponent == "claude"
    }
}
