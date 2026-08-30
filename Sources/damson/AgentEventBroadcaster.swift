import DamsonAgents
import DamsonControl
import Foundation

/// Fans agent state changes out to `watch-agents` subscribers.
///
/// Subscribers are control-socket connections, each served on its own thread, so the
/// handoff has to be thread-safe: the sweep publishes on main, the writes happen wherever
/// the connection lives. Each subscriber owns a bounded mailbox rather than a shared
/// cursor — one slow reader must not stall the sweep or the others.
final class AgentEventBroadcaster {
    /// Per-subscriber backlog cap. A subscriber that stops reading is a subscriber that has
    /// gone away or wedged; past this we drop it rather than grow without bound, because the
    /// alternative is the app holding memory for a client that is never coming back.
    private static let maxQueued = 256

    private final class Subscriber {
        let id = UUID()
        var pending: [AgentEventLine] = []
        var overflowed = false
        let wake = DispatchSemaphore(value: 0)
    }

    private let lock = NSLock()
    private var subscribers: [UUID: Subscriber] = [:]
    /// Kept so a new subscriber can be handed the present before the future.
    private var stream = AgentEventStream()

    /// Publish one sweep. Returns the events, so the caller can log or test them.
    @discardableResult
    func publish(_ observations: [AgentObservation]) -> [AgentEvent] {
        let events = stream.ingest(observations)
        guard !events.isEmpty else { return events }
        let lines = events.map(Self.line)
        lock.lock()
        for (_, s) in subscribers {
            if s.pending.count + lines.count > Self.maxQueued {
                s.overflowed = true
            } else {
                s.pending.append(contentsOf: lines)
            }
            s.wake.signal()
        }
        lock.unlock()
        return events
    }

    /// Register a listener. `handle` is its token; the returned lines start with a snapshot
    /// of what is already running, so a coordinator that connects mid-run is not blind until
    /// the next change.
    func subscribe() -> (handle: UUID, backlog: [AgentEventLine]) {
        let s = Subscriber()
        let snapshot = stream.snapshot().map(Self.line)
        lock.lock()
        subscribers[s.id] = s
        lock.unlock()
        return (s.id, snapshot)
    }

    func unsubscribe(_ handle: UUID) {
        lock.lock()
        let s = subscribers.removeValue(forKey: handle)
        lock.unlock()
        s?.wake.signal()   // release a blocked waiter so its thread can exit
    }

    /// Block until there is something to send, this subscriber is gone, or `timeout` passes.
    /// Returns nil when the subscriber should stop (dropped, or it overflowed).
    func next(_ handle: UUID, timeout: TimeInterval) -> [AgentEventLine]? {
        lock.lock()
        guard let s = subscribers[handle] else { lock.unlock(); return nil }
        if !s.pending.isEmpty {
            let out = s.pending
            s.pending.removeAll(keepingCapacity: true)
            lock.unlock()
            return out
        }
        let overflowed = s.overflowed
        lock.unlock()
        if overflowed { return nil }

        _ = s.wake.wait(timeout: .now() + timeout)

        lock.lock()
        defer { lock.unlock() }
        guard let live = subscribers[handle], !live.overflowed else { return nil }
        let out = live.pending
        live.pending.removeAll(keepingCapacity: true)
        return out
    }

    private static func line(_ e: AgentEvent) -> AgentEventLine {
        AgentEventLine(event: e.kind.rawValue, pane: e.paneID, pid: e.pid, status: e.status,
                       previousStatus: e.previousStatus, waitingFor: e.waitingFor, cwd: e.cwd)
    }
}
