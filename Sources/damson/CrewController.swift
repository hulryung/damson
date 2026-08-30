import AppKit
import DamsonAgents
import DamsonTerminal
import Foundation

/// Keeps damson's panes labelled with what the Claude Code session inside them is doing.
///
/// The whole mechanism is two facts joined:
///  - a pane can name the process group owning its tty (`DamsonSession.foregroundProcessID`,
///    which only the holder of the PTY master can obtain), and
///  - Claude Code publishes one record per live session keyed by that same pid.
///
/// So the "am I an agent, and how is it going" question is a dictionary lookup, not an
/// inference. Nothing here reads terminal output, matches rendered text, or writes to a
/// pane — damson observes, and the human still drives.
///
/// **Hot-path rule.** This runs on a timer and nowhere else. It must never be wired to
/// `DamsonSession.onOutput`, `outputEvents`, or any render callback: a pane under an output
/// flood already spends its main-thread budget parsing, and this feature is not worth a
/// single byte of it. The steady-state cost per pane per tick is one `tcgetpgrp` ioctl and
/// one dictionary miss.
final class CrewController {
    /// How often to re-read Claude Code's session records. Slow on purpose: these badges
    /// are ambient context, and a human reading a status pill cannot tell 3s from 1s.
    private static let refreshInterval: TimeInterval = 3.0

    private let registry = ClaudeSessionRegistry()
    private var timer: DispatchSourceTimer?
    /// Windows to sweep. Supplied by the app delegate rather than held, so the controller
    /// never becomes a second owner of a window's lifetime.
    private let windows: () -> [CompactWindowController]

    private var didLogVersion = false

    /// Publishes state changes to `watch-agents` subscribers. Owned by the delegate so it
    /// outlives any one connection.
    private let broadcaster: AgentEventBroadcaster
    /// Resolves a session to its stable pane id, so an event names the pane a driver holds.
    private let paneID: (DamsonSession) -> UUID?

    init(windows: @escaping () -> [CompactWindowController],
         broadcaster: AgentEventBroadcaster,
         paneID: @escaping (DamsonSession) -> UUID?) {
        self.windows = windows
        self.broadcaster = broadcaster
        self.paneID = paneID
    }

    /// Begin sweeping. Safe to call twice — the previous timer is cancelled first.
    func start() {
        stop()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + Self.refreshInterval,
                   repeating: Self.refreshInterval,
                   leeway: .milliseconds(500))
        // `[weak self]` plus an explicit `stop()` in deinit: a DispatchSourceTimer keeps its
        // handler alive until cancelled, so a strong capture here would pin the controller
        // (and through it nothing else, but the timer would keep firing) for the process's life.
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    deinit { stop() }

    /// The agent status of a pane right now, from the table the last sweep read. Used by
    /// the control socket so a script sees the same status the badge shows, without paying
    /// for a fresh directory scan per query.
    func badge(for session: DamsonSession) -> AgentBadge? {
        guard let row = registry.session(forForegroundPID: session.foregroundProcessID) else {
            return nil
        }
        return AgentBadge(status: row.status)
    }

    /// One sweep: re-read the session records, then relabel every pane in every window.
    private func tick() {
        registry.refresh()

        // Notice — once — when Claude Code has moved past the version this was written
        // against. The badge vocabulary is not ours; if it drifts, `AgentBadge` degrades to
        // "no badge" and this line is the only breadcrumb saying why.
        if !didLogVersion, let v = registry.observedVersion, v != Self.knownGoodVersion {
            didLogVersion = true
            NSLog("damson: Claude Code \(v) (agent badges verified against \(Self.knownGoodVersion))")
        }

        guard !registry.byPID.isEmpty || didSeeAgents else { return }
        var sawAny = false
        // Built while the badges are applied, so the events a subscriber sees and the pills
        // the user sees come from ONE observation of the world rather than two sweeps that
        // could disagree.
        var observed: [AgentObservation] = []
        for controller in windows() {
            controller.refreshAgentBadges { [registry, paneID] session in
                guard let row = registry.session(forForegroundPID: session.foregroundProcessID)
                else { return nil }
                sawAny = true
                // An id is minted here: a pane running an agent is exactly the pane a driver
                // will want to name, and an event with no id would be unactionable.
                if let id = paneID(session) {
                    observed.append(AgentObservation(
                        paneID: id.uuidString, pid: row.pid, status: row.status,
                        waitingFor: row.waitingFor, cwd: row.cwd))
                }
                // The badge vocabulary is closed; the event stream forwards the raw status
                // so a driver isn't limited to what damson happens to draw.
                return AgentBadge(status: row.status)
            }
        }
        broadcaster.publish(observed)
        // Once agents have been seen, keep sweeping even after the table empties, so the
        // last badges get cleared rather than frozen on screen.
        didSeeAgents = sawAny
    }

    /// True while at least one pane showed a badge on the previous tick.
    private var didSeeAgents = false

    /// The Claude Code release whose session-record format and status vocabulary
    /// (`busy` / `shell` / `idle` / `waiting`) this integration was last verified against.
    /// Written against 2.1.228; re-checked against 2.1.251 with the vocabulary unchanged.
    /// Purely informational — see `AgentBadge` for the fail-quiet behaviour.
    private static let knownGoodVersion = "2.1.251"
}
