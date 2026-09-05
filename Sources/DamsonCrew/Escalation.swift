import DamsonControl
import Foundation

/// Turns a blocked agent into something a human actually receives while looking at
/// something else, and gives them one step to get to it.
///
/// Only `waiting` escalates. damson made the same call for tab titles, and for the same
/// reason: if more states escalated the alerts would become noise people learn to dismiss,
/// and then they would miss the one that mattered. In particular `idle` is not "finished" —
/// it also covers *asked a clarifying question* and *spawned but never prompted* — so
/// notifying on it would fire constantly.
public struct Escalation: Equatable {
    public enum Kind: Equatable {
        /// Blocked on the user. Will not move until answered.
        case blocked
        /// Quiet for longer than expected, with no explanation available.
        case stalled
        /// Was working, now stopped. Worth telling someone; not a completion signal — see
        /// `AgentBoard.Change.finishedTurn`.
        case finishedTurn
    }

    public let kind: Kind
    /// The task's name when the pane is one of ours, else the pane id. Never a bare UUID
    /// when we can do better: an alert nobody can act on is worse than none.
    public let subject: String
    public let question: String
    public let paneID: String

    public var title: String {
        switch kind {
        case .blocked:      return "\(subject) needs you"
        case .finishedTurn: return "\(subject) finished"
        case .stalled:      return "\(subject) has gone quiet"
        }
    }
    public var body: String { question }

    /// Only a blocked agent earns being pulled in front of the user. Something that just
    /// stopped working is news, not an interruption — stealing focus for it would move the
    /// window out from under whatever they were doing.
    public var deservesFocus: Bool { kind == .blocked }
}

public extension AgentBoard.Change {
    /// The alert this change deserves, or nil for changes nobody should be interrupted for.
    var escalation: Escalation? {
        switch self {
        case .needsAttention(let agent):
            return Escalation(kind: .blocked, subject: agent.task ?? agent.paneID,
                              question: agent.waitingFor ?? "waiting for you",
                              paneID: agent.paneID)
        case .finishedTurn(let agent):
            return Escalation(kind: .finishedTurn, subject: agent.task ?? agent.paneID,
                              question: "went idle after working", paneID: agent.paneID)
        case .stalled(let agent):
            let mins = Int(Date().timeIntervalSince(agent.since) / 60)
            return Escalation(kind: .stalled, subject: agent.task ?? agent.paneID,
                              question: "still \(agent.status) after \(max(mins, 1)) min",
                              paneID: agent.paneID)
        default:
            return nil
        }
    }
}

/// Delivers alerts. A protocol so the decision of *what* to escalate can be tested apart
/// from the machinery that puts it on screen.
public protocol Notifier {
    func deliver(_ escalation: Escalation)
}

/// Posts a macOS notification by asking `osascript`, which needs no bundle identity — a
/// plain command-line tool cannot use UNUserNotificationCenter without being inside a
/// signed .app, and requiring one would make the coordinator undeployable.
public struct SystemNotifier: Notifier {
    public init() {}

    public func deliver(_ escalation: Escalation) {
        let script = """
        display notification \(quote(escalation.body)) \
        with title \(quote(escalation.title)) sound name "Submarine"
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        // Best effort. A notification that could not be posted must never take down the
        // watcher — losing the alert is bad, losing every future alert is worse.
        try? proc.run()
    }

    /// AppleScript string literal. Agent questions are free-form text from a model and
    /// routinely contain quotes and backslashes; unescaped, they turn the alert into a
    /// syntax error and it silently never appears.
    private func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ") + "\""
    }
}

/// Brings the blocked agent's tab forward, so acting on the alert is one step.
public struct PaneFocuser {
    private let client: DamsonClient
    public init(client: DamsonClient) { self.client = client }

    /// Focus the pane. Returns what went wrong, if anything.
    @discardableResult
    public func reveal(paneID: String) -> String? {
        // `pane-info` on a closed id is a typed error rather than a fallback to the active
        // pane, so this cannot quietly focus the wrong terminal.
        switch client.send(.paneInfo, target: .id(paneID)) {
        case .failure(let e): return e.message
        case .success(let resp):
            guard resp.ok, let tab = resp.pane?.tab else {
                return resp.err ?? "damson did not say which tab that pane is in"
            }
            switch client.send(.switchTab(index: tab)) {
            case .failure(let e): return e.message
            case .success(let r): return r.ok ? nil : (r.err ?? "could not switch tab")
            }
        }
    }
}
