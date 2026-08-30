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
  damson-crew watch [--tasks FILE] [--pid PID]

Options:
  --tasks FILE     JSON array of tasks. "-" reads stdin. Each entry:
                     {"name": "review-api", "cwd": "/path", "prompt": "…"}
                   `name` is the tab label AND the spawn key, so re-running a
                   list reattaches to its tabs instead of duplicating them.
  --group NAME     Put every tab in this group, so the run can be folded or
                   closed as a unit (damson-cli group close NAME).
  --pid PID        Target a specific damson instance (default: most recent).
  --command CMD    Agent to run. Default: claude.
  -h, --help

`watch` subscribes to damson and prints a line whenever an agent needs you.
It waits rather than polls: the stream is edge-triggered, so an idle machine
produces nothing. Pass --tasks to name the work instead of a pane id.
"""

func die(_ msg: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(code)
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
var command: [String] = ["claude"]

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
    case "-h", "--help":
        print(usage); exit(0)
    default:
        die("unknown option: \(args[i])")
    }
}

guard ["run", "watch"].contains(sub) else { die("unknown command: \(sub)") }

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

switch sub {
case "run":
    guard let tasksPath else { die("run requires --tasks") }
    let list = readTasks(tasksPath)
    let outcomes = Coordinator(client: client, defaultCommand: command)
        .fanOut(list.tasks, group: group)

    for outcome in outcomes {
        if let id = outcome.paneID {
            print("\(outcome.task)\t\(id)")
        } else {
            FileHandle.standardError.write(
                Data("\(outcome.task)\tFAILED: \(outcome.error ?? "?")\n".utf8))
        }
    }
    let failed = outcomes.filter { !$0.opened }.count
    if failed > 0 {
        FileHandle.standardError.write(
            Data("\(failed) of \(outcomes.count) task(s) did not start\n".utf8))
        exit(1)
    }

case "watch":
    // Pane → task, so a line names the work rather than a UUID. Resolved once at startup
    // from what is on screen; a pane that appears later still reports its id.
    var byPane: [String: String] = [:]
    if let tasksPath {
        let list = readTasks(tasksPath)
        for (task, pane) in Coordinator(client: client).reattach(list.tasks) { byPane[pane] = task }
    }

    let watcher = AgentWatcher(
        stream: AgentWatcher.socketStream {
            // Re-resolved per attempt: damson's socket path carries its pid, so a restart
            // (including an update) moves it.
            switch pickDamsonSocket(pid: pid) {
            case .success(let p): return .success(p)
            case .failure(let e): return .failure(CrewError(e.message))
            }
        },
        taskFor: { byPane[$0] },
        onChange: { change, _ in
            let stamp = ISO8601DateFormatter().string(from: Date())
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

default:
    die("unknown command: \(sub)")
}
