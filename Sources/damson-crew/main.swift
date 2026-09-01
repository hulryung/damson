import DamsonControl
import DamsonCrew
import Foundation

// damson-crew — opens a tab per task in a running damson and tells you when one needs you.
//
// Fan-out and attention routing, NOT a queue. damson has no trustworthy "this task is
// finished" signal: `status: "idle"` also means "asked you a question" and "never prompted".
// See docs/CLAUDE-ORCHESTRATION.md §5.

let usage = """
damson-crew — open a tab per task in a running damson.

Usage:
  damson-crew run   --tasks FILE [--group NAME] [--pid PID] [--command CMD]
  damson-crew watch  [--tasks FILE] [--pid PID] [--notify] [--focus]
  damson-crew status --tasks FILE [--group NAME] [--pid PID]
  damson-crew close  --group NAME [--pid PID] [--yes] [--remove-worktrees]

Options:
  --tasks FILE     JSON array of tasks. "-" reads stdin. Each entry needs a
                   name, a prompt, and somewhere to run — either a `cwd`, or a
                   `repo` (plus optional `branch` and `base`), in which case a
                   git worktree is made and used:
                     {"name": "review-api", "cwd": "/path", "prompt": "…"}
                     {"name": "review-api", "repo": "~/dev/api",
                      "branch": "agent/review-api", "base": "main",
                      "prompt": "…", "command": ["codex"]}
                   `name` is the tab label AND the spawn key, so re-running a
                   list reattaches to its tabs instead of duplicating them.
                   `command` overrides the agent; the prompt is appended last,
                   which claude, codex, grok and cursor-agent all take. Put
                   {prompt} in the command for a tool that wants a flag.
  --group NAME     Put every tab in this group, so the run can be folded or
                   closed as a unit (damson-cli group close NAME).
  --pid PID        Target a specific damson instance (default: most recent).
  --command CMD    Agent to run. Default: from Settings → Orchestration.
  --skip-permissions / --no-skip-permissions
                   Pass --dangerously-skip-permissions to claude, so it does not
                   stop on approval prompts. On by default; change the default in
                   Settings → Orchestration. Applies to claude only — other agents
                   spell this differently or not at all.
  -h, --help

  --trust-new-worktrees / --no-trust-new-worktrees
                   Pre-accept Claude Code's workspace-trust prompt for a worktree
                   this run creates. Claude Code asks on any git repository root
                   it has not seen, and a worktree is one — so without this a
                   fan-out stops once per task. Only worktrees this tool made,
                   and only Claude Code.
  --notify / --no-notify
                   Post a macOS notification when an agent is blocked on you.
  --focus / --no-focus
                   Also bring that agent's tab forward.
                   Both default to Settings → Orchestration.
  --yes            Required by `close`, which shuts several tabs and the
                   programs inside them.
  --remove-worktrees  With `close` (and --tasks): also remove the git worktrees
                   the run created. Never forced — git refuses a tree holding
                   uncommitted or untracked files, and that refusal is
                   reported rather than worked around.

`run` is safe to repeat: every spawn carries the task name as its key, so a
second run reattaches to the tabs it already opened. `status` says which
tasks have tabs and which are blocked on you.

`watch` subscribes to damson and prints a line whenever an agent needs you.
It waits rather than polls: the stream is edge-triggered, so an idle machine
produces nothing. Pass --tasks to name the work instead of a pane id.
"""

func die(_ msg: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(code)
}

/// Pane id → task name, refreshed when a pane turns up that the cache does not know.
///
/// Kept behind a lock because the reading thread reads it and the delivery queue refills it.
final class PaneNames {
    private let client: DamsonClient
    private let tasks: [CrewTask]
    private let lock = NSLock()
    private var map: [String: String] = [:]

    init(client: DamsonClient, tasks: [CrewTask]) {
        self.client = client
        self.tasks = tasks
        refresh()
    }

    func cached(_ pane: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return map[pane]
    }

    /// Fill in a change's task name, asking damson once if this pane is new to us.
    func naming(_ change: AgentBoard.Change) -> AgentBoard.Change {
        guard !tasks.isEmpty else { return change }
        switch change {
        case .needsAttention(let a) where a.task == nil: return .needsAttention(resolve(a))
        case .released(let a) where a.task == nil:       return .released(resolve(a))
        case .appeared(let a) where a.task == nil:       return .appeared(resolve(a))
        case .vanished(let pane, nil):                   return .vanished(paneID: pane, task: cached(pane))
        default:                                         return change
        }
    }

    private func resolve(_ agent: AgentState) -> AgentState {
        if cached(agent.paneID) == nil { refresh() }
        var named = agent
        named.task = cached(agent.paneID)
        return named
    }

    private func refresh() {
        guard !tasks.isEmpty else { return }
        let found = Coordinator(client: client).reattach(tasks)
        lock.lock()
        for (task, pane) in found { map[pane] = task }
        lock.unlock()
    }
}

/// Talks to damson over the same unix socket `damson-cli` uses. Linking `DamsonControl`
/// rather than shelling out to the CLI is deliberate: the CLI is shipped inside the app
/// bundle and only reaches PATH if something linked it there, so a coordinator that ran it
/// as a subprocess would fail on a machine where nobody had.
struct SocketClient: DamsonClient {
    let socketPath: String

    func send(_ kind: ControlCommandKind, target: PaneTarget) -> Result<ControlResponse, CrewError> {
        switch sendCommand(socketPath: socketPath, commandJSON: encodeCommand(kind, target: target)) {
        case .success(let resp): return .success(resp)
        case .failure(let e):    return .failure(CrewError(e.description))
        }
    }
}

var args = CommandLine.arguments.dropFirst().map { $0 }
guard let sub = args.first, sub != "-h", sub != "--help" else { print(usage); exit(args.isEmpty ? 2 : 0) }
args = Array(args.dropFirst())

var tasksPath: String?
var group: String?
var pid: Int?
// Defaults come from damson's Orchestration settings; every one can be overridden per run.
let settings = OrchestrationSettings.load()
var command: [String] = settings.agentCommand
var skipPermissions = settings.skipPermissions
var trustNewWorktrees = settings.trustNewWorktrees
var notify = settings.notifyOnWaiting
var focus = settings.focusOnWaiting
var confirmed = false
var removeWorktrees = false

var i = 0
while i < args.count {
    switch args[i] {
    case "--tasks":
        i += 1; guard i < args.count else { die("--tasks requires a path (or -)") }
        tasksPath = args[i]; i += 1
    case "--group":
        i += 1; guard i < args.count else { die("--group requires a name") }
        group = args[i]; i += 1
    case "--pid":
        i += 1; guard i < args.count, let v = Int(args[i]) else { die("--pid requires a number") }
        pid = v; i += 1
    case "--command":
        i += 1; guard i < args.count else { die("--command requires a command") }
        command = [args[i]]; i += 1
    case "--notify":
        notify = true; i += 1
    case "--no-notify":
        notify = false; i += 1
    case "--focus":
        focus = true; i += 1
    case "--no-focus":
        focus = false; i += 1
    case "--skip-permissions":
        skipPermissions = true; i += 1
    case "--no-skip-permissions":
        skipPermissions = false; i += 1
    case "--trust-new-worktrees":
        trustNewWorktrees = true; i += 1
    case "--no-trust-new-worktrees":
        trustNewWorktrees = false; i += 1
    case "--yes":
        confirmed = true; i += 1
    case "--remove-worktrees":
        removeWorktrees = true; i += 1
    case "-h", "--help":
        print(usage); exit(0)
    default:
        die("unknown option: \(args[i])")
    }
}

guard ["run", "watch", "status", "close"].contains(sub) else { die("unknown command: \(sub)") }

func readTasks(_ path: String) -> TaskList {
    let data: Data
    if path == "-" {
        data = FileHandle.standardInput.readDataToEndOfFile()
    } else {
        guard let d = FileManager.default.contents(atPath: path) else { die("cannot read \(path)") }
        data = d
    }
    do { return try TaskList.parse(data) } catch { die("damson-crew: \(error)") }
}

let socketPath: String
switch pickDamsonSocket(pid: pid) {
case .success(let p): socketPath = p
case .failure(let e): die(e.message)
}
let client = SocketClient(socketPath: socketPath)
// An explicit worktree root keeps every run's trees in one place; empty means beside the
// repo, which is the default because it keeps them obviously related to what they branch from.
let worktrees: WorktreeManager = settings.worktreeRoot.isEmpty
    ? WorktreeManager()
    : WorktreeManager(rootFor: { repo in
        let root = (settings.worktreeRoot as NSString).expandingTildeInPath
        return URL(fileURLWithPath: root)
            .appendingPathComponent(URL(fileURLWithPath: repo).lastPathComponent).path
      })

switch sub {
case "run":
    guard let tasksPath else { die("run requires --tasks") }
    let list = readTasks(tasksPath)
    // Reattach to what is already on screen and open only the rest.
    //
    // `--key` alone is NOT enough here. damson keeps its key→pane table in memory, so it
    // does not survive damson restarting — and a coordinator's whole reason to re-run a
    // list is that something restarted. Without this the second run opens a duplicate of
    // every task, measured: a three-task group came back with six tabs.
    let manager = RunManager(client: client, worktrees: worktrees)
    let existing: [String: String]
    switch manager.status(of: list.tasks, group: group) {
    case .success(let status):
        existing = Dictionary(uniqueKeysWithValues:
            status.rows.compactMap { row in row.paneID.map { (row.task, $0) } })
    case .failure:
        existing = [:]      // cannot see the screen: open everything, `--key` still helps
    }
    let needed = list.tasks.filter { existing[$0.name] == nil }
    if !existing.isEmpty {
        FileHandle.standardError.write(
            Data("reattached to \(existing.count) tab(s), starting \(needed.count)\n".utf8))
    }

    let outcomes = Coordinator(client: client, defaultCommand: command,
                               skipPermissions: skipPermissions,
                               trustNewWorktrees: trustNewWorktrees,
                               worktrees: worktrees)
        .fanOut(needed, group: group)
    var byTask = existing
    for outcome in outcomes where outcome.paneID != nil { byTask[outcome.task] = outcome.paneID }

    for task in list.tasks {
        if let id = byTask[task.name] {
            print("\(task.name)\t\(id)")
        } else {
            let why = outcomes.first { $0.task == task.name }?.error ?? "?"
            FileHandle.standardError.write(Data("\(task.name)\tFAILED: \(why)\n".utf8))
        }
    }
    let failed = list.tasks.count - byTask.count
    if failed > 0 {
        FileHandle.standardError.write(
            Data("\(failed) of \(list.tasks.count) task(s) did not start\n".utf8))
        exit(1)
    }

case "watch":
    // Pane → task, so a line names the work rather than a UUID.
    //
    // Resolved lazily as well as at startup. The normal shape is `watch` in one terminal and
    // `run` in another, so the panes a watcher most wants to name are created AFTER it
    // connects — a startup-only lookup left every one of them reported as a bare id for the
    // rest of the run, which is most of the value of naming them at all.
    let names = PaneNames(client: client, tasks: tasksPath.map { readTasks($0).tasks } ?? [])

    let notifier = SystemNotifier()
    let focuser = PaneFocuser(client: client)
    let watcher = AgentWatcher(
        stream: AgentWatcher.socketStream {
            // Re-resolved per attempt: damson's socket path carries its pid, so a restart
            // (including an update) moves it.
            switch pickDamsonSocket(pid: pid) {
            case .success(let p): return .success(p)
            case .failure(let e): return .failure(CrewError(e.message))
            }
        },
        // Called on the reading thread, so it only ever touches the cache — damson drops a
        // subscriber whose mailbox fills, and a socket round-trip here would risk exactly that.
        taskFor: { names.cached($0) },
        onChange: { change, _ in
            let stamp = ISO8601DateFormatter().string(from: Date())
            // Delivery runs off the reading thread, so this is where a miss can afford to go
            // and ask damson which task the pane belongs to.
            let change = names.naming(change)
            // Only `waiting` is ever escalated — see Escalation for why nothing else is.
            if let alert = change.escalation {
                if notify { notifier.deliver(alert) }
                if focus, let why = focuser.reveal(paneID: alert.paneID) {
                    FileHandle.standardError.write(
                        Data("\(stamp)\tcould not focus \(alert.subject): \(why)\n".utf8))
                }
            }
            switch change {
            case .needsAttention(let a):
                let who = a.task ?? a.paneID
                print("\(stamp)\tWAITING\t\(who)\t\(a.waitingFor ?? "(no detail)")")
            case .released(let a):
                print("\(stamp)\tresumed\t\(a.task ?? a.paneID)")
            case .appeared(let a):
                print("\(stamp)\tstarted\t\(a.task ?? a.paneID)\t\(a.status)")
            case .vanished(let pane, let task):
                print("\(stamp)\tended\t\(task ?? pane)")
            }
            fflush(stdout)
        })
    watcher.run()

case "status":
    guard let tasksPath else { die("status requires --tasks") }
    let list = readTasks(tasksPath)
    switch RunManager(client: client, worktrees: worktrees).status(of: list.tasks, group: group) {
    case .failure(let e): die("damson-crew: \(e.message)")
    case .success(let status):
        for row in status.rows {
            let where_ = row.paneID ?? "-"
            print("\(row.task)\t\(where_)\t\(row.agent ?? "-")")
        }
        // Non-zero when something is blocked, so a shell script can act on it.
        if !status.waiting.isEmpty { exit(1) }
    }

case "close":
    guard let group else { die("close requires --group") }
    // Destructive: several tabs and the programs inside them. Making it the natural
    // consequence of a typo is exactly what a coordinator must not do.
    guard confirmed else {
        die("close would shut every tab in group '\(group)' and the programs in them. " +
            "Re-run with --yes if that is what you want.")
    }
    let manager = RunManager(client: client, worktrees: worktrees)
    switch manager.close(group: group) {
    case .failure(let e): die("damson-crew: \(e.message)", code: 1)
    case .success:        print("closed \(group)")
    }
    if removeWorktrees {
        guard let tasksPath else { die("--remove-worktrees needs --tasks to know which ones") }
        var kept = 0
        for outcome in manager.removeWorktrees(of: readTasks(tasksPath).tasks) {
            if let why = outcome.kept {
                kept += 1
                FileHandle.standardError.write(Data("kept \(outcome.path): \(why)\n".utf8))
            } else {
                print("removed \(outcome.path)")
            }
        }
        if kept > 0 {
            FileHandle.standardError.write(
                Data("\(kept) worktree(s) kept because they hold uncommitted work\n".utf8))
        }
    }

default:
    die("unknown command: \(sub)")
}
