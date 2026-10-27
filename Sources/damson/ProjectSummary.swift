import AppKit
import DamsonTerminal

/// An on-demand snapshot, never a per-frame or permanently polling Git process.
final class ProjectSummary: NSWindowController {
    static let shared = ProjectSummary()
    private let text = NSTextView()
    private var generation = UUID()
    private var folder: String?
    private var pid: Int32?
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Project Summary"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        text.isEditable = false
        text.isSelectable = true
        text.isAutomaticLinkDetectionEnabled = true
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.textContainerInset = NSSize(width: 16, height: 16)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(reload))
        let stack = NSStackView(views: [refresh, scroll])
        stack.orientation = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(folder: String, pid: Int32?) {
        self.folder = folder
        self.pid = pid
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        reload()
    }
    @objc private func reload() {
        guard let folder else { return }
        let request = UUID()
        generation = request
        let pid = self.pid
        text.string = "\(folder)\n\nLoading…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let report = Self.collect(folder: folder, pid: pid)
            DispatchQueue.main.async {
                guard let self, self.generation == request else { return }
                self.text.string = report
                // Native text detection makes localhost URLs clickable.
                self.text.checkTextInDocument(nil)
            }
        }
    }
    private static func run(_ executable: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        process.environment = env
        // Drain output while the child runs; a large repository cannot deadlock a pipe.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: deadline)
        var data = Data()
        var truncated = false
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if data.count + chunk.count <= 2_000_000 { data.append(chunk) }
            else { truncated = true }
        }
        process.waitUntilExit()
        deadline.cancel()
        return (truncated ? -2 : process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    private static func collect(folder: String, pid: Int32?) -> String {
        var result = "Folder: \(folder)\n\n"
        let root = run("/usr/bin/git", ["-C", folder, "rev-parse", "--show-toplevel"])
        if root.0 == 0 {
            let branch = run("/usr/bin/git", ["-C", folder, "branch", "--show-current"])
            let name = branch.1.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = run("/usr/bin/git", ["-C", folder, "status", "--porcelain=v1", "-z"])
            let records = status.1.split(separator: "\0")
            var count = 0, i = 0
            while i < records.count {
                let code = records[i].prefix(2)
                count += 1
                i += (code.contains("R") || code.contains("C")) ? 2 : 1
            }
            result += "Repository: \(root.1.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            result += "Branch: \(branch.0 == 0 ? (name.isEmpty ? "detached HEAD" : name) : "unavailable")\n"
            result += status.0 == 0 ? "Changed files: \(count)\n" : "Changed files: unavailable (query failed or timed out)\n"
        } else {
            result += root.1.contains("not a git repository") ? "Git: this folder is not a repository\n" : "Git: unavailable (folder inaccessible or query failed/timed out)\n"
        }
        result += "\nListening services of this pane's foreground process:\n"
        if let pid {
            let sockets = run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"])
            let addresses = sockets.1.split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
            if sockets.0 == 0 {
                result += addresses.isEmpty ? "None found\n" : addresses.map { "• \($0)" }.joined(separator: "\n") + "\n"
                let ports = Set(addresses.compactMap { address -> Int? in
                    guard ["*:", "127.0.0.1:", "0.0.0.0:", "[::1]:", "[::]:"].contains(where: { address.hasPrefix($0) }),
                          let value = address.split(separator: ":").last, let port = Int(value), (1...65535).contains(port) else { return nil }
                    return port
                })
                if !ports.isEmpty {
                    result += "\nTry in browser (HTTP protocol not verified):\n"
                    result += ports.sorted().map { "http://localhost:\($0)" }.joined(separator: "\n") + "\n"
                }
                result += "TCP listeners are not necessarily HTTP services.\n"
            } else { result += "None found or process information unavailable\n" }
        } else { result += "Process ownership unavailable for this session\n" }
        return result + "\nSnapshot only; Refresh checks this same folder again."
    }
}
