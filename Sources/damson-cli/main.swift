import Foundation
import DamsonControl

// damson-cli — a CLI that sends commands to a damson instance.
// Communicates with the damson server in the NDJSON wire format.
//
// Usage:
//   damson-cli new-tab
//   damson-cli split horizontal
//   damson-cli switch-tab 2
//   damson-cli close-tab
//   damson-cli list-tabs
//   damson-cli --list-instances
//   damson-cli --pid 12345 new-tab
//
// Exit codes:
//   0 — success (response.ok == true)
//   1 — the server responded with a command failure (response.ok == false)
//   2 — connect/discovery/parse failure (before reaching the server)

let usage = """
damson-cli — send commands to a running damson terminal instance.

Usage:
  damson-cli [--pid PID] <command> [args...]
  damson-cli --list-instances

Commands:
  new-tab                 Spawn a new tab.
  split horizontal|vertical   Split the active pane (not supported in damson).
  switch-tab <index>      Switch to the tab at the 0-based index.
  close-tab               Close the active tab.
  list-tabs               Print tab list as JSON.

Options:
  --pid PID               Target the instance with this PID (default: most recent).
  --list-instances        List running damson instances and exit.
  -h, --help              Show this help.
"""

func die(_ msg: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(code)
}

// Simple argv parsing. No clap-style dependency pulled in.
var args = CommandLine.arguments.dropFirst().map { $0 }
var pidArg: Int?
var listInstances = false
var positional: [String] = []

var i = 0
while i < args.count {
    let a = args[i]
    switch a {
    case "-h", "--help":
        print(usage)
        exit(0)
    case "--list-instances":
        listInstances = true
        i += 1
    case "--pid":
        i += 1
        guard i < args.count, let v = Int(args[i]) else {
            die("--pid requires a numeric argument")
        }
        pidArg = v
        i += 1
    default:
        if a.hasPrefix("--") {
            die("unknown option: \(a)")
        }
        positional.append(a)
        i += 1
    }
}

if listInstances {
    let instances = listDamsonInstances()
    if instances.isEmpty {
        print("(no running damson instances)")
        exit(0)
    }
    // Both a JSON line and a human-readable format. Header on the first line, sorted.
    for inst in instances {
        let mt = inst.mtime.map { ISO8601DateFormatter().string(from: $0) } ?? "?"
        print("pid=\(inst.pid)  mtime=\(mt)  socket=\(inst.socketPath)")
    }
    exit(0)
}

guard let sub = positional.first else {
    print(usage)
    exit(2)
}
let rest = Array(positional.dropFirst())

let cmdKind: ControlCommandKind
switch sub {
case "new-tab":
    guard rest.isEmpty else { die("new-tab takes no arguments") }
    cmdKind = .newTab
case "close-tab":
    guard rest.isEmpty else { die("close-tab takes no arguments") }
    cmdKind = .closeTab
case "list-tabs":
    guard rest.isEmpty else { die("list-tabs takes no arguments") }
    cmdKind = .listTabs
case "split":
    guard rest.count == 1 else { die("split requires direction: horizontal|vertical") }
    guard let dir = SplitDir(rawValue: rest[0]) else {
        die("split direction must be 'horizontal' or 'vertical'")
    }
    cmdKind = .split(dir)
case "switch-tab":
    guard rest.count == 1, let idx = Int(rest[0]) else {
        die("switch-tab requires a 0-based integer index")
    }
    cmdKind = .switchTab(index: idx)
default:
    die("unknown command: \(sub)")
}

let socketPath: String
switch pickDamsonSocket(pid: pidArg) {
case .success(let p): socketPath = p
case .failure(let e): die(e.message)
}

let json = encodeCommand(cmdKind)
switch sendCommand(socketPath: socketPath, commandJSON: json) {
case .success(let resp):
    if !resp.ok {
        let msg = resp.err ?? "(no error message)"
        die("damson: \(msg)", code: 1)
    }
    // If the ok response carries tabs, print them as JSON (script-friendly).
    if let tabs = resp.tabs {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        if let data = try? encoder.encode(tabs),
           let s = String(data: data, encoding: .utf8) {
            print(s)
        }
    }
    exit(0)
case .failure(let e):
    die("damson-cli: \(e.description)")
}
