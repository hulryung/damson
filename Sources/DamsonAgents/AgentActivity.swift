import DamsonTerminal
import Foundation

/// One row of the Agent Activity list: what damson can say about a pane's agent, and who
/// said it. Typed so the attention order is decided from the state itself, never from the
/// wording of a display string.
public struct AgentActivity: Equatable {
    public enum Source: Equatable {
        /// An OSC 777 report from the pane's own process (see docs/WORKBENCH.md).
        case explicitReport(ReportedAgentState, at: Date?)
        /// Claude Code's session record, as the badge reads it.
        case claudeObservation(AgentBadge)
        /// A known agent launcher that has reported nothing. Never inferred to be done.
        case unreported(program: String)
    }

    public let source: Source

    /// Programs worth listing even before they report, so a silent agent shows as
    /// "unknown" instead of vanishing from the list.
    public static let knownLaunchers: Set<String> = ["claude", "codex", "grok", "cursor-agent", "gemini", "opencode"]

    /// The launcher's program name, `shell` when argv is empty.
    public static func program(argv: [String]) -> String {
        argv.first.map { ($0 as NSString).lastPathComponent } ?? "shell"
    }

    /// An explicit report wins over an observation, which wins over the launcher; nil
    /// when the pane has nothing to do with an agent.
    public static func classify(report: ReportedAgentState?, reportedAt: Date?,
                                badge: AgentBadge?, argv: [String]) -> AgentActivity? {
        if let report { return AgentActivity(source: .explicitReport(report, at: reportedAt)) }
        if let badge { return AgentActivity(source: .claudeObservation(badge)) }
        let program = program(argv: argv)
        return knownLaunchers.contains(program) ? AgentActivity(source: .unreported(program: program)) : nil
    }

    /// 0 = needs the user's input now, 1 = reported failure, 2 = everything else.
    public var attentionRank: Int {
        switch source {
        case .explicitReport(.waiting, _), .claudeObservation(.waiting): return 0
        case .explicitReport(.failed, _): return 1
        default: return 2
        }
    }

    /// "state · source · cwd" — the line under the pane title.
    public func detail(cwd: String, formatTime: (Date) -> String) -> String {
        switch source {
        case let .explicitReport(state, at):
            return "\(state.rawValue) · explicit report\(at.map { " at \(formatTime($0))" } ?? "") · \(cwd)"
        case let .claudeObservation(badge):
            return "\(badge.describedAs) · Claude observation · \(cwd)"
        case let .unreported(program):
            return "State unknown · no report from \(program) · \(cwd)"
        }
    }

    /// Attention first, then title in Finder order. Stable for equal keys.
    public static func sorted<T>(_ items: [T], rank: (T) -> Int, title: (T) -> String) -> [T] {
        items.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element), rank(b.element))
            if ra != rb { return ra < rb }
            let order = title(a.element).localizedStandardCompare(title(b.element))
            return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
        }.map(\.element)
    }
}
