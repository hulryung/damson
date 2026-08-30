import DamsonControl
import Foundation

/// What a run looks like right now: every task, and what became of it.
public struct RunStatus: Equatable {
    public struct Row: Equatable {
        public let task: String
        /// nil when the task has no tab on screen — never opened, or its tab was closed.
        public let paneID: String?
        /// The agent status damson reports, when the pane is running one it recognizes.
        /// nil means "no agent here", which is NOT the same as "the tab is gone": a pane
        /// whose agent exited keeps its tab and falls back to a shell.
        public let agent: String?

        public var hasTab: Bool { paneID != nil }
    }

    public let group: String?
    public let rows: [Row]

    public var missing: [String] { rows.filter { !$0.hasTab }.map(\.task) }
    public var waiting: [Row] { rows.filter { $0.agent == "waiting" } }
}

/// The lifetime of a run: find it, describe it, close it.
///
/// Reattachment is the point. A coordinator that restarted must find the run already on
/// screen rather than opening it a second time — and damson makes that possible because
/// pane ids and tab labels both survive a restart.
public struct RunManager {
    private let client: DamsonClient
    public init(client: DamsonClient) { self.client = client }

    /// Join the task list to what is on screen, by tab label.
    public func status(of tasks: [CrewTask], group: String?) -> Result<RunStatus, CrewError> {
        switch client.send(.listAgents) {
        case .failure(let e): return .failure(e)
        case .success(let resp):
            guard resp.ok, let panes = resp.panes else {
                return .failure(CrewError(resp.err ?? "damson did not list its panes"))
            }
            // Only panes in this run's group count when a group was named, so two runs that
            // happen to use the same task name cannot be mistaken for each other.
            let relevant = panes.filter { group == nil || $0.group == group }
            var byLabel: [String: PaneInfo] = [:]
            for pane in relevant { if let t = pane.title { byLabel[t] = pane } }
            let rows = tasks.map { task in
                let pane = byLabel[task.name]
                return RunStatus.Row(task: task.name, paneID: pane?.id, agent: pane?.agent)
            }
            return .success(RunStatus(group: group, rows: rows))
        }
    }

    /// Which tasks still need a tab opened. Re-running a list is safe anyway — every spawn
    /// carries the task name as its key — but knowing spares the round trips and lets a
    /// caller report "reattached to 4, starting 1" instead of silently doing nothing.
    public func tasksNeedingTabs(_ tasks: [CrewTask], group: String?) -> [CrewTask] {
        guard case .success(let status) = status(of: tasks, group: group) else { return tasks }
        let missing = Set(status.missing)
        return tasks.filter { missing.contains($0.name) }
    }

    /// Close a run: every tab in its group, and the programs inside them.
    ///
    /// Requires a group. Closing "the tabs whose labels match my task list" would be a much
    /// worse rule for a destructive command — a coordinator with a task called `build` would
    /// close a tab the user had named `build` themselves.
    public func close(group: String) -> Result<Void, CrewError> {
        switch client.send(.closeGroup(group)) {
        case .failure(let e): return .failure(e)
        case .success(let resp):
            // damson answers an unknown group with a typed error rather than a quiet
            // success, so a mistyped run name cannot look like a clean teardown.
            return resp.ok ? .success(()) : .failure(CrewError(resp.err ?? "damson refused to close the group"))
        }
    }
}
