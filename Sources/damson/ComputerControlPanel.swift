import AppKit
import DamsonComputer

/// Only observes/manages the separate desktop helper; the terminal never hosts
/// accessibility execution or owns the machine-wide input lease.
@MainActor
final class ComputerControlPanel: NSWindowController {
    static let shared = ComputerControlPanel()
    private let status = NSTextField(wrappingLabelWithString: "Checking computer helper…")
    private var timer: Timer?
    private var loading = false

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Computer Control"
        super.init(window: window)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 14)
        stack.addArrangedSubview(status)
        let note = NSTextField(wrappingLabelWithString: "One task can control the desktop at a time. Moving the mouse or typing stops an active session. Resume explicitly when you are ready.")
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)
        let controls = NSStackView()
        for (title, action) in [("Start Helper", #selector(startHelper)), ("Stop", #selector(stop)),
                                ("Resume", #selector(resume)), ("Permissions…", #selector(permissions))] {
            controls.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        stack.addArrangedSubview(controls)
        stack.addArrangedSubview(NSButton(title: "Show Session Logs", target: self, action: #selector(showLogs)))
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)
            ])
        }
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    @objc func showPanel() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        refresh()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.window?.isVisible == true else { return }
                    self.refresh()
                }
            }
        }
    }

    @objc private func startHelper() {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Damson Computer.app")
        guard FileManager.default.fileExists(atPath: helper.path) else {
            status.stringValue = "The helper is not bundled in this build. Use scripts/build-app.sh to build the complete app."
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: helper, configuration: config) { [weak self] _, error in
            Task { @MainActor in
                if let error { self?.status.stringValue = error.localizedDescription } else { self?.refresh() }
            }
        }
    }

    @objc private func stop() { send("stop") }
    @objc private func resume() { send("resume") }
    @objc private func permissions() { send("permissions", arguments: ["prompt": "true"]) }
    @objc private func showLogs() { NSWorkspace.shared.open(ComputerPaths.artifacts) }

    private func send(_ command: String, arguments: [String: String] = [:]) {
        Task {
            let error = await Task.detached { () -> String? in
                do {
                    let data = try ComputerTransport.call(ComputerRequest(command: command, arguments: arguments))
                    let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    if result?["ok"] as? Bool != true { return String(data: data, encoding: .utf8) }
                    return nil
                } catch { return String(describing: error) }
            }.value
            if let error { status.stringValue = error } else { refresh() }
        }
    }

    private func refresh() {
        guard !loading else { return }
        loading = true
        Task {
            let text = await Task.detached { () -> String in
                do {
                    let data = try ComputerTransport.call(ComputerRequest(command: "status"))
                    let response = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    guard let result = response?["result"] as? [String: Any] else { return "Invalid helper response." }
                    let permissions = result["permissions"] as? [String: Any] ?? [:]
                    let access = permissions["accessibility"] as? Bool == true ? "allowed" : "needed"
                    let screen = permissions["screenRecording"] as? Bool == true ? "allowed" : "needed"
                    let state: String
                    if result["paused"] as? Bool == true {
                        let interrupted = (result["pauseReason"] as? String)?.hasPrefix("external_input:") == true
                        state = interrupted ? "Paused — mouse or keyboard activity interrupted the task."
                            : "Paused — desktop control is stopped."
                    } else if let session = result["session"] as? [String: Any] {
                        state = "In use: \(session["owner"] ?? "")\nTarget app PID: \(session["pid"] ?? "")"
                    } else { state = "Ready — no task owns the desktop." }
                    return "\(state)\n\nAccessibility: \(access)\nScreen Recording: \(screen)"
                } catch { return "Helper is stopped or unavailable.\nStart Helper to enable computer control." }
            }.value
            status.stringValue = text
            loading = false
        }
    }
}
