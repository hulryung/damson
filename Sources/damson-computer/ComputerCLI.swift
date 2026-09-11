import Foundation
import AppKit
import DamsonComputer

let usage = """
damson-computer — observe and control one macOS app through a desktop session.

  start                        Launch the bundled Damson Computer helper.
  status                       Show owner, pause state, and permissions (JSON).
  permissions [--prompt true]  Check or request macOS permissions.
  apps                         List running GUI apps.
  acquire --pid PID --owner NAME [--ttl 60]
                               Acquire exclusive desktop use; returns session token.
  renew --session TOKEN [--ttl 60]
  release --session TOKEN
  stop                         Cancel the session and pause desktop control.
  resume                       Allow new sessions after a user stop.

Session commands (all require --session TOKEN):
  windows                      List target app windows and global point bounds.
  focus                        Explicitly bring the target app forward.
  inspect                      Read accessibility tree; returns element IDs.
  capture --window ID           Save PNG; return path, bounds, and pixel scales.
  press --element ID            Perform accessibility press on an inspected element.
  click --x X --y Y             Click global desktop POINT coordinates.
  type --text TEXT              Unicode input without changing the clipboard.
  key --key cmd+a               Named key/chord (enter, space, arrows, etc.).
  scroll --dy PIXELS [--dx PIXELS]

All responses are JSON. --request-id ID deduplicates retries within the helper's
last 256 completed requests. After disconnect/restart, observe before retrying input.
A dispatched input is not proof that the app accepted it: inspect/capture to verify.
Physical mouse/keyboard input stops an active session. TTL is 5...300 seconds.
"""

func emitError(_ error: Error) -> Never {
    let value = ["ok": false, "error": ["code": (error as? ComputerFailure)?.code ?? "error", "message": String(describing: error)]] as [String: Any]
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data + Data([10]))
    }
    exit(1)
}

func startHelper() throws {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let helper = executable.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Helpers/Damson Computer.app")
    guard FileManager.default.fileExists(atPath: helper.path) else {
        throw ComputerFailure("not_bundled", "Bundled helper app is missing. Build with scripts/build-app.sh or run the development helper with --serve.")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-g", helper.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw ComputerFailure("launch_failed", "Could not launch helper.") }
    for _ in 0..<50 {
        if let data = try? ComputerTransport.call(ComputerRequest(command: "status")) {
            FileHandle.standardOutput.write(data + Data([10]))
            return
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    throw ComputerFailure("launch_failed", "Helper did not become reachable within 5 seconds.")
}

@main
struct ComputerCLI {
    @MainActor static func main() {
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--serve" || Bundle.main.bundleIdentifier == "app.damson.computer" {
    runComputerHelper()
} else if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] {
    print(usage)
} else {
    do {
        if arguments == ["start"] { try startHelper() } else {
            var options: [String: String] = [:]
            var index = 1
            while index < arguments.count {
                let key = arguments[index]
                guard key.hasPrefix("--"), index + 1 < arguments.count else {
                    throw ComputerFailure("invalid_argument", "Expected --option value. See --help.")
                }
                let name = String(key.dropFirst(2))
                guard options[name] == nil else { throw ComputerFailure("invalid_argument", "Duplicate option: \(key)") }
                options[name] = arguments[index + 1]
                index += 2
            }
            let id = options.removeValue(forKey: "request-id") ?? UUID().uuidString
            let data = try ComputerTransport.call(ComputerRequest(id: id, command: arguments[0], arguments: options))
            FileHandle.standardOutput.write(data + Data([10]))
            let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if result?["ok"] as? Bool != true { exit(1) }
        }
    } catch { emitError(error) }
}

    }
}
