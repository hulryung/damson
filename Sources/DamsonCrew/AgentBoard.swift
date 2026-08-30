import DamsonControl
import Foundation

/// What the coordinator believes about one agent right now.
public struct AgentState: Equatable, Sendable {
    public let paneID: String
    public var pid: Int32?
    public var status: String
    public var waitingFor: String?
    public var cwd: String?
    /// The task this pane is running, when the pane's label matches one. Filled in by the
    /// caller, since damson knows nothing about tasks.
    public var task: String?

    public var isWaiting: Bool { status == "waiting" }
}

/// The live picture of every agent, fed by the `watch-agents` stream.
///
/// The stream's contract puts four things on the consumer, and every one of them is a way to
/// be quietly wrong rather than visibly broken:
///
///  - **A snapshot arrives first**, then changes. The opening burst is the present, not news.
///  - **It is edge-triggered.** Silence means nothing changed, not that the link died.
///  - **A `heartbeat` line every 20s** exists so a dead peer is found by the write failing.
///    It is not a state change and must not be treated as one.
///  - **A new process in an old pane is `vanished` + `appeared`, never `changed`.** Carrying
///    state across that boundary would attribute one conversation's conclusions to another.
public struct AgentBoard: Equatable {
    public private(set) var agents: [String: AgentState] = [:]
    /// True once the opening snapshot has been consumed.
    public private(set) var hasSnapshot = false

    public init() {}

    /// Something the coordinator should act on. Returned rather than dispatched so the
    /// decision of what to do stays outside this type — and so it can be tested.
    public enum Change: Equatable {
        /// An agent is blocked on a human. `waitingFor` is what it is blocked on.
        case needsAttention(AgentState)
        /// It was blocked and no longer is.
        case released(AgentState)
        case appeared(AgentState)
        case vanished(paneID: String, task: String?)
    }

    /// Apply one line. Returns what changed in a way worth acting on, or nil.
    @discardableResult
    public mutating func apply(_ line: AgentEventLine, task: (String) -> String? = { _ in nil })
        -> Change? {
        switch line.event {
        case "heartbeat":
            // Liveness only. Reporting it as a change would make an idle machine look busy
            // and, worse, would let a caller measure elapsed time instead of activity.
            return nil

        case "vanished":
            guard let gone = agents.removeValue(forKey: line.pane) else { return nil }
            return .vanished(paneID: gone.paneID, task: gone.task)

        case "appeared", "changed":
            let previous = agents[line.pane]
            // A pid change in a pane damson called `changed` should not happen — the server
            // reports vanished+appeared for that — but if it ever did, treating it as a
            // continuation would carry one conversation's state into another. Start fresh.
            let continues = previous != nil && (line.pid == nil || previous?.pid == line.pid)
            var state = continues ? previous! : AgentState(
                paneID: line.pane, pid: line.pid, status: line.status ?? "",
                waitingFor: line.waitingFor, cwd: line.cwd, task: task(line.pane))
            state.pid = line.pid ?? state.pid
            state.status = line.status ?? state.status
            state.waitingFor = line.waitingFor
            state.cwd = line.cwd ?? state.cwd
            if state.task == nil { state.task = task(line.pane) }
            agents[line.pane] = state

            if state.isWaiting {
                // `waitingFor` is part of the state: an agent moving from one question to
                // the next is `waiting` both times, and the thing blocking it changed. Only
                // the same question twice is not news.
                if previous?.isWaiting == true, previous?.waitingFor == state.waitingFor {
                    return nil
                }
                return .needsAttention(state)
            }
            if previous?.isWaiting == true { return .released(state) }
            return continues ? nil : .appeared(state)

        default:
            // An event this build does not know. Ignore it rather than guess — the same
            // direction damson's own badge vocabulary degrades in.
            return nil
        }
    }

    /// Mark the opening snapshot consumed. Everything after this is live.
    public mutating func snapshotComplete() { hasSnapshot = true }

    /// Forget everything. Used on reconnect: the new subscription opens with its own
    /// snapshot, and keeping stale rows would leave agents on the board that have since gone.
    public mutating func reset() {
        agents.removeAll()
        hasSnapshot = false
    }

    public var waiting: [AgentState] {
        agents.values.filter(\.isWaiting).sorted { $0.paneID < $1.paneID }
    }
}
