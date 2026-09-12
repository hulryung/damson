// Compile with the production ComputerControlPanel.swift and its dependencies.
// Exercises real panel button actions against an idle installed helper; no input
// is sent to any target application and no terminal session is opened.
import AppKit
import DamsonComputer

@main
struct PanelAcceptance {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                try await run()
                print("Panel acceptance passed")
                if CommandLine.arguments.contains("--hold") {
                    try String(getpid()).write(toFile: "/tmp/damson-panel-acceptance.pid", atomically: true, encoding: .utf8)
                    try await Task.sleep(for: .seconds(45))
                }
                exit(0)
            } catch {
                fputs("Panel acceptance failed: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    @MainActor static func status() async throws -> [String: Any] {
        let data = try await Task.detached {
            try ComputerTransport.call(ComputerRequest(command: "status"))
        }.value
        let reply = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return reply["result"] as! [String: Any]
    }

    @MainActor static func run() async throws {
        let before = try await status()
        guard before["session"] is NSNull, before["busy"] as? Bool == false,
              before["pauseReason"] is NSNull || before["pauseReason"] as? String == "requested" else {
            throw NSError(domain: "Requires idle helper with no external-input stop", code: 1)
        }
        defer { _ = try? ComputerTransport.call(ComputerRequest(command: "stop")) }
        let panel = ComputerControlPanel.shared
        panel.showPanel()
        let content = panel.window!.contentView!
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let views = descendants(content)
        func button(_ title: String) -> NSButton {
            views.compactMap { $0 as? NSButton }.first { $0.title == title }!
        }
        func text() -> String {
            views.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n")
        }
        for (title, paused) in [("Resume", false), ("Stop", true), ("Start Helper", true)] {
            button(title).performClick(nil)
            var matched = false
            for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(100))
                let current = try await status()
                if current["paused"] as? Bool == paused,
                   text().contains(paused ? "Paused" : "Ready") {
                    matched = true
                    break
                }
            }
            guard matched else { throw NSError(domain: "Panel action failed: \(title)", code: 2) }
        }
        let permissions = before["permissions"] as! [String: Any]
        guard text().contains(permissions["helperPath"] as! String),
              text().contains("Accessibility: allowed"), text().contains("Screen Recording: allowed") else {
            throw NSError(domain: "Panel did not show actual helper path/permissions", code: 3)
        }
        let after = try await status()
        guard after["helperPID"] as? Int == before["helperPID"] as? Int,
              after["session"] is NSNull, after["paused"] as? Bool == true else {
            throw NSError(domain: "Panel changed helper identity or left authority active", code: 4)
        }
    }
}
