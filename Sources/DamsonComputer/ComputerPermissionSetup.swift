import AppKit

/// Runs inside the helper so macOS attributes requests to Damson Computer.
@MainActor
final class ComputerPermissionSetup: NSWindowController {
    static let shared = ComputerPermissionSetup()
    private let desktop = DesktopAccess()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set Up Damson Computer"
        super.init(window: window)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let help = NSTextField(wrappingLabelWithString: "Choose each permission below. Damson Computer will request access from macOS, then open the matching settings page. Turn on Damson Computer in the list.")
        stack.addArrangedSubview(help)
        stack.addArrangedSubview(status)
        for (title, action) in [("1. Add to Accessibility…", #selector(accessibility)),
                                ("2. Add to Screen Recording…", #selector(screenRecording))] {
            stack.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        let fallback = NSTextField(wrappingLabelWithString: "Still missing? Click + in System Settings, press ⌘⇧G, paste the helper path below, then click Open. If macOS asks you to restart the helper, quit it from the DC menu and start it again.")
        stack.addArrangedSubview(fallback)
        let path = NSTextField(wrappingLabelWithString: Bundle.main.bundlePath)
        path.isSelectable = true
        path.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        stack.addArrangedSubview(path)
        let files = NSStackView()
        files.addArrangedSubview(NSButton(title: "Copy Helper Path", target: self, action: #selector(copyPath)))
        files.addArrangedSubview(NSButton(title: "Show Helper in Finder", target: self, action: #selector(showHelper)))
        stack.addArrangedSubview(files)
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24)
            ] + [help, status, fallback, path].map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
        }
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present(destination: ComputerPrivacySettings? = nil) {
        refresh()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if let destination { request(destination) }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.window?.isVisible == true else { return }
                    self.refresh()
                }
            }
        }
    }

    private func refresh() {
        let permissions = desktop.permissions()
        let access = permissions["accessibility"] as? Bool == true ? "Allowed" : "Needs permission"
        let screen = permissions["screenRecording"] as? Bool == true ? "Allowed" : "Needs permission"
        status.stringValue = "Accessibility: \(access)\nScreen Recording: \(screen)"
    }

    @objc private func accessibility() { request(.accessibility) }
    @objc private func screenRecording() { request(.screenRecording) }
    private func request(_ destination: ComputerPrivacySettings) {
        _ = desktop.permissions(prompt: true, destination: destination)
        destination.open()
        refresh()
    }
    @objc private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Bundle.main.bundlePath, forType: .string)
    }
    @objc private func showHelper() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
}
