import DamsonControl
import Foundation

/// What the coordinator needs from damson. A protocol so the fan-out can be tested without
/// a running app — the interesting failures here are partial ones, and reproducing those
/// against a real instance is neither quick nor repeatable.
public protocol DamsonClient {
    /// Send one command and return the response, or a message describing why not.
    func send(_ kind: ControlCommandKind, target: PaneTarget) -> Result<ControlResponse, CrewError>
}

public extension DamsonClient {
    func send(_ kind: ControlCommandKind) -> Result<ControlResponse, CrewError> {
        send(kind, target: .active)
    }
}

/// Anything that stopped a command reaching damson or coming back. One case, carrying the
/// message, because the coordinator's only response to any of them is the same: report which
/// task it happened to and carry on with the rest.
public struct CrewError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Opens one tab per task and reports what happened to each.
///
/// This is fan-out, not a queue, and that is structural rather than unfinished work.
/// Measured against Claude Code 2.1.251: a terminal state (`done` / `failed`) exists only
/// for `kind: background` sessions, which carry no pid and therefore have no pane — while
/// the `kind: interactive` sessions that DO live in panes never carry one at all. So a
/// visible tab a human can take over and a completion signal are alternatives, not a pair.
/// See docs/CLAUDE-ORCHESTRATION.md §5.
public struct Coordinator {
    public struct Outcome: Equatable {
        public let task: String
        /// The pane the task is running in, when it opened.
        public let paneID: String?
        /// Why it did not, when it did not.
        public let error: String?

        public var opened: Bool { paneID != nil }
    }

    private let client: DamsonClient
    private let defaultCommand: [String]
    private let worktrees: WorktreeManager
    private let skipPermissions: Bool

    public init(client: DamsonClient, defaultCommand: [String] = ["claude"],
                skipPermissions: Bool = true,
                worktrees: WorktreeManager = WorktreeManager()) {
        self.client = client
        self.defaultCommand = defaultCommand
        self.skipPermissions = skipPermissions
        self.worktrees = worktrees
    }

    /// Where a task should run: its worktree if it asked for one, else its `cwd`.
    ///
    /// Worktrees are made here rather than left to the agent because support for them is
    /// per-tool and inconsistent — `claude -w`, `grok --worktree=<name>`, and nothing at all
    /// in `codex` or `cursor-agent`. All any of them needs is to be started in the right
    /// directory, so doing it once here makes a task list portable across every one.
    func workingDirectory(for task: CrewTask) -> Result<String?, CrewError> {
        guard let repo = task.repo, let branch = task.worktreeBranch else {
            return .success(task.resolvedCWD)
        }
        return worktrees.ensure(repo: repo, branch: branch, base: task.base).map { $0 }
    }

    /// Open a tab per task. One task failing does not stop the rest: a run of five where the
    /// third could not start should leave four agents working and one thing to fix, not
    /// nothing at all.
    ///
    /// Every spawn carries the task name as its idempotency key. That is not belt-and-braces:
    /// damson's control handler reports a timeout at 2s **while the queued work still runs to
    /// completion**, so a spawn that overruns a tab-creation animation answers "failed" for a
    /// tab that did open. Without the key, re-running the list would mint a second agent for
    /// that task.
    public func fanOut(_ tasks: [CrewTask], group: String?) -> [Outcome] {
        tasks.map { task in
            // A worktree that cannot be made is this task's failure, not the run's: the
            // others should still start.
            let cwd: String?
            switch workingDirectory(for: task) {
            case .failure(let e):
                return Outcome(task: task.name, paneID: nil, error: e.message)
            case .success(let path):
                cwd = path
            }
            // The bypass is added here rather than in the task, so it reaches a task that
            // names its own `command` too — a stalled agent is a stalled agent either way.
            let argv = AgentFlags.apply(skipPermissions: skipPermissions,
                                        to: task.argv(defaultCommand: defaultCommand))
            let spec = SpawnSpec(cwd: cwd,
                                 argv: argv,
                                 key: task.name,
                                 title: task.name,
                                 group: group)
            switch client.send(.spawnPane(spec)) {
            case .failure(let why):
                return Outcome(task: task.name, paneID: nil, error: why.message)
            case .success(let resp):
                guard resp.ok else {
                    return Outcome(task: task.name, paneID: nil,
                                   error: resp.err ?? "damson refused the spawn")
                }
                guard let id = resp.pane?.id else {
                    // A spawn that reports success without a pane id leaves the task
                    // unaddressable, which is a failure even though damson said ok.
                    return Outcome(task: task.name, paneID: nil,
                                   error: "damson opened a pane but reported no id")
                }
                return Outcome(task: task.name, paneID: id, error: nil)
            }
        }
    }

    /// What is on screen right now, joined to the task list by tab label. Used to reattach:
    /// the coordinator restarting must find the run it already opened rather than opening it
    /// a second time.
    public func reattach(_ tasks: [CrewTask]) -> [String: String] {
        guard case .success(let resp) = client.send(.listAgents), resp.ok,
              let panes = resp.panes else { return [:] }
        let wanted = Set(tasks.map(\.name))
        var out: [String: String] = [:]
        for pane in panes {
            guard let title = pane.title, wanted.contains(title), let id = pane.id else { continue }
            out[title] = id
        }
        return out
    }
}
