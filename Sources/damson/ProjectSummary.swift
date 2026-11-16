import AppKit
import DamsonProjectInfo

/// An on-demand snapshot, never a per-frame or permanently polling Git process.
final class ProjectSummary: NSWindowController {
    static let shared = ProjectSummary()
    private let text = NSTextView()
    private var generation = UUID()
    private var folder: String?
    /// The pane's foreground process GROUP (tcgetpgrp), read again on every Refresh: a
    /// dev server started after the panel opened is a new group.
    private var processGroup: () -> Int32? = { nil }
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
    func show(folder: String, processGroup: @escaping () -> Int32?) {
        self.folder = folder
        self.processGroup = processGroup
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        reload()
    }
    @objc private func reload() {
        guard let folder else { return }
        let request = UUID()
        generation = request
        let pid = processGroup()
        text.string = "\(folder)\n\nLoading…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let report = ProjectSnapshot.collect(folder: folder, processGroup: pid).render()
            DispatchQueue.main.async {
                guard let self, self.generation == request else { return }
                self.text.string = report
                // Native text detection makes localhost URLs clickable.
                self.text.checkTextInDocument(nil)
            }
        }
    }
}
