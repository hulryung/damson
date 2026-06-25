import Foundation
import OrchardControl

// orchard-cli — drive a running Orchard instance over its control socket. Designed so an
// external AI/script can orchestrate: open workspaces, enqueue tasks, read/drive agents.
//
//   orchard-cli list-workspaces
//   orchard-cli add-workspace <repo-path>
//   orchard-cli list-agents [--workspace N]
//   orchard-cli add-task --workspace N [--engine claude-code] [--title T] --prompt "…"
//   orchard-cli agent-output <agentId>
//   orchard-cli send-text <agentId> <text…>
//   orchard-cli send-key  <agentId> <key> [key…]
//   orchard-cli interrupt <agentId>
// Global: --pid N  (target a specific instance; default = most recent)

func usage() -> Never {
    let text = """
    orchard-cli — control a running Orchard instance

    USAGE:
      orchard-cli <command> [args] [--pid N]

    COMMANDS:
      list-workspaces
      add-workspace <repo-path>
      list-agents [--workspace N]
      add-task --workspace N --prompt "…" [--engine claude-code] [--title T]
      agent-output <agentId>
      send-text <agentId> <text…>
      send-key  <agentId> <key> [key…]
      interrupt <agentId>

    Agent ids come from `list-agents`. Output is JSON.
    """
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(2)
}

func parse(_ args: [String]) -> (flags: [String: String], positionals: [String]) {
    var flags: [String: String] = [:]
    var positionals: [String] = []
    var i = 0
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            let key = String(a.dropFirst(2))
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                flags[key] = args[i + 1]; i += 2
            } else {
                flags[key] = "true"; i += 1
            }
        } else {
            positionals.append(a); i += 1
        }
    }
    return (flags, positionals)
}

let raw = Array(CommandLine.arguments.dropFirst())
guard !raw.isEmpty else { usage() }

let (flags, positionals) = parse(raw)
guard let sub = positionals.first else { usage() }
let rest = Array(positionals.dropFirst())
let pid = flags["pid"].flatMap(Int.init)

func need(_ value: String?, _ msg: String) -> String {
    guard let value else { FileHandle.standardError.write(Data(("error: \(msg)\n").utf8)); exit(2) }
    return value
}

let command: OrchardCommand
switch sub {
case "list-workspaces":
    command = OrchardCommand(cmd: "list-workspaces")
case "add-workspace":
    command = OrchardCommand(cmd: "add-workspace", path: need(rest.first, "repo path required"))
case "list-agents":
    command = OrchardCommand(cmd: "list-agents", workspace: flags["workspace"].flatMap(Int.init))
case "set-concurrency":
    command = OrchardCommand(
        cmd: "set-concurrency",
        workspace: Int(need(flags["workspace"], "--workspace N required")),
        count: Int(need(flags["count"] ?? rest.first, "--count C (or positional) required")))
case "add-task":
    command = OrchardCommand(
        cmd: "add-task",
        workspace: Int(need(flags["workspace"], "--workspace N required")),
        engine: flags["engine"],
        title: flags["title"],
        prompt: need(flags["prompt"], "--prompt required"))
case "agent-output":
    command = OrchardCommand(cmd: "agent-output", agent: need(rest.first, "agent id required"))
case "focus":
    command = OrchardCommand(cmd: "focus", agent: need(rest.first, "agent id required"))
case "view":
    command = OrchardCommand(cmd: "view", text: need(rest.first, "grid|tabs required"))
case "show-new-session":
    command = OrchardCommand(cmd: "show-new-session")
case "new-session":
    command = OrchardCommand(
        cmd: "new-session",
        workspace: Int(need(flags["workspace"], "--workspace N required")),
        engine: flags["engine"] ?? rest.first ?? "claude-code")
case "send-text":
    let agent = need(rest.first, "agent id required")
    command = OrchardCommand(cmd: "send-text", agent: agent, text: rest.dropFirst().joined(separator: " "))
case "send-key":
    let agent = need(rest.first, "agent id required")
    command = OrchardCommand(cmd: "send-key", agent: agent, keys: Array(rest.dropFirst()))
case "interrupt":
    command = OrchardCommand(cmd: "interrupt", agent: need(rest.first, "agent id required"))
case "-h", "--help", "help":
    usage()
default:
    FileHandle.standardError.write(Data(("error: unknown command '\(sub)'\n").utf8))
    usage()
}

switch orchardSend(command: command, pid: pid) {
case .success(let response):
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(response), let str = String(data: data, encoding: .utf8) {
        print(str)
    }
    exit(response.ok ? 0 : 1)
case .failure(let error):
    FileHandle.standardError.write(Data(("error: \(error)\n").utf8))
    exit(1)
}
