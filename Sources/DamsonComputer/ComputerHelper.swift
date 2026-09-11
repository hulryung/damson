import AppKit
import Darwin

@MainActor
private final class ComputerHelperDelegate: NSObject, NSApplicationDelegate {
    let engine = ComputerEngine()
    let server = ComputerServer()
    var item: NSStatusItem?
    var monitor: Any?
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try server.start { [weak self] request, completion in
                Task { @MainActor in
                    guard let self else { completion(Data("{\"ok\":false}".utf8)); return }
                    completion(await self.engine.handle(request))
                }
            }
        } catch {
            NSLog("Damson Computer: %@", String(describing: error))
            // Startup failure must be observable by direct CLI supervisors.
            // Terminating NSApplication normally would incorrectly exit with 0.
            Darwin.exit(EXIT_FAILURE)
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(withTitle: "Desktop idle", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        add("Stop Desktop Control", action: #selector(stop), to: menu)
        add("Resume Desktop Control", action: #selector(resume), to: menu)
        add("Grant Permissions…", action: #selector(permissions), to: menu)
        add("Show Session Logs", action: #selector(logs), to: menu)
        menu.addItem(.separator())
        add("Quit Damson Computer", action: #selector(quit), to: menu)
        item?.menu = menu
        engine.onChange = { [weak self] in self?.refresh() }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved]) { [weak self] event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != DesktopAccess.eventTag else { return }
            // WindowServer can send a zero-delta mouseMoved when a window opens
            // under a stationary cursor. That is not a user moving the mouse.
            if event.type == .mouseMoved, event.deltaX == 0, event.deltaY == 0 { return }
            Task { @MainActor in
                guard let self, self.engine.sessions.session != nil else { return }
                let sourcePID = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1
                self.engine.interruptForInput(timestamp: event.timestamp,
                                              kind: "\(event.type):sourcePID=\(sourcePID)")
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.engine.sessions.expire()
                self.refresh()
            }
        }
        refresh()
    }

    private func add(_ title: String, action: Selector, to menu: NSMenu) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
    }

    private func refresh() {
        let title: String
        if engine.sessions.paused { title = "Desktop paused" } else if let session = engine.sessions.session { title = "Desktop: \(session.owner)" } else { title = "Desktop idle" }
        item?.button?.title = engine.sessions.session == nil ? "DC" : "DC ●"
        item?.button?.toolTip = title
        item?.menu?.item(at: 0)?.title = title
    }

    @objc private func stop() { engine.stop() }
    @objc private func resume() { engine.sessions.resume(); refresh() }
    @objc private func permissions() { _ = engine.desktop.permissions(prompt: true) }
    @objc private func logs() { NSWorkspace.shared.open(ComputerPaths.artifacts) }
    @objc private func quit() { engine.stop(); NSApp.terminate(nil) }
}

@MainActor
public func runComputerHelper() {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = ComputerHelperDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
