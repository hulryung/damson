import Foundation

/// One observed change in an agent pane's state.
///
/// Emitted so a coordinator can WAIT rather than poll. Polling `list-agents` is correct but
/// wasteful and late: at a 3s sweep a driver either asks far more often than anything
/// changes, or learns that an agent went `waiting` up to a sweep after it did — and
/// `waiting` is the state a human is being blocked on.
public struct AgentEvent: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// A pane started running something damson recognizes as an agent.
        case appeared
        /// Its status moved (busy → idle, idle → waiting, …).
        case changed
        /// The pane stopped being an agent: the process exited, or the pane closed.
        case vanished
    }
    public let kind: Kind
    public let paneID: String
    public let pid: Int32?
    /// Status after the change. nil for `vanished`.
    public let status: String?
    /// Status before it. nil for `appeared`.
    public let previousStatus: String?
    /// What a `waiting` agent is blocked on, when the CLI says.
    public let waitingFor: String?
    public let cwd: String?

    public init(kind: Kind, paneID: String, pid: Int32?, status: String?,
                previousStatus: String?, waitingFor: String?, cwd: String?) {
        self.kind = kind
        self.paneID = paneID
        self.pid = pid
        self.status = status
        self.previousStatus = previousStatus
        self.waitingFor = waitingFor
        self.cwd = cwd
    }
}

/// What a sweep saw for one pane. The caller builds these from its own pane↔session join;
/// this type deliberately knows nothing about panes, sessions or AppKit so the diff can be
/// tested on its own.
public struct AgentObservation: Equatable, Sendable {
    public let paneID: String
    public let pid: Int32?
    public let status: String
    public let waitingFor: String?
    public let cwd: String?

    public init(paneID: String, pid: Int32?, status: String,
                waitingFor: String? = nil, cwd: String? = nil) {
        self.paneID = paneID
        self.pid = pid
        self.status = status
        self.waitingFor = waitingFor
        self.cwd = cwd
    }
}

/// Turns successive sweeps into a stream of changes.
///
/// Edge-triggered on purpose: a sweep that sees the same thing emits nothing, so an idle
/// machine produces no traffic and a subscriber's inbox measures real activity rather than
/// elapsed time. `waitingFor` is treated as part of the state — an agent that moves from
/// one question to another is a change a coordinator needs, even though `status` stayed
/// `waiting` both times.
///
/// Main-thread only, like the sweep that feeds it.
public struct AgentEventStream {
    private var last: [String: AgentObservation] = [:]

    public init() {}

    /// Diff this sweep against the previous one. Returns the changes, in a stable order
    /// (vanished first, then by pane id) so a test — and a log — reads deterministically.
    public mutating func ingest(_ observations: [AgentObservation]) -> [AgentEvent] {
        var events: [AgentEvent] = []
        let seen = Set(observations.map(\.paneID))

        for (paneID, prev) in last.sorted(by: { $0.key < $1.key }) where !seen.contains(paneID) {
            events.append(AgentEvent(kind: .vanished, paneID: paneID, pid: prev.pid,
                                     status: nil, previousStatus: prev.status,
                                     waitingFor: nil, cwd: prev.cwd))
        }
        for obs in observations.sorted(by: { $0.paneID < $1.paneID }) {
            guard let prev = last[obs.paneID] else {
                events.append(AgentEvent(kind: .appeared, paneID: obs.paneID, pid: obs.pid,
                                         status: obs.status, previousStatus: nil,
                                         waitingFor: obs.waitingFor, cwd: obs.cwd))
                continue
            }
            // A pane that was reused by a DIFFERENT process is not a status change: the old
            // agent is gone and a new one is there. Reporting it as `changed` would let a
            // coordinator carry its old conclusions across two unrelated conversations.
            if prev.pid != obs.pid {
                events.append(AgentEvent(kind: .vanished, paneID: obs.paneID, pid: prev.pid,
                                         status: nil, previousStatus: prev.status,
                                         waitingFor: nil, cwd: prev.cwd))
                events.append(AgentEvent(kind: .appeared, paneID: obs.paneID, pid: obs.pid,
                                         status: obs.status, previousStatus: nil,
                                         waitingFor: obs.waitingFor, cwd: obs.cwd))
            } else if prev.status != obs.status || prev.waitingFor != obs.waitingFor {
                events.append(AgentEvent(kind: .changed, paneID: obs.paneID, pid: obs.pid,
                                         status: obs.status, previousStatus: prev.status,
                                         waitingFor: obs.waitingFor, cwd: obs.cwd))
            }
        }
        last = Dictionary(uniqueKeysWithValues: observations.map { ($0.paneID, $0) })
        return events
    }

    /// Everything currently known, as `appeared` events — what a new subscriber gets so it
    /// starts from the present rather than from whatever happens next.
    public func snapshot() -> [AgentEvent] {
        last.values.sorted { $0.paneID < $1.paneID }.map {
            AgentEvent(kind: .appeared, paneID: $0.paneID, pid: $0.pid, status: $0.status,
                       previousStatus: nil, waitingFor: $0.waitingFor, cwd: $0.cwd)
        }
    }
}
