import AppKit
import SwiftUI
import DamsonTerminal
import OrchardControl

// Relaunch inside Orchard.app (own icon/dock identity) before any GUI work.
OrchardTrampoline.relaunchInAppBundleIfNeeded()

let app = NSApplication.shared
let appDelegate = OrchardAppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()

final class OrchardAppDelegate: NSObject, NSApplicationDelegate {
    private var store: WorkspaceStore!
    private var window: NSWindow?
    private var controlServer: OrchardControlServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let store = WorkspaceStore()
            self.store = store
            store.restore()
            startControlServer(store: store)
            buildMenu()

            let hosting = NSHostingController(rootView: RootView().environmentObject(store))
            let win = NSWindow(contentViewController: hosting)
            win.title = "Orchard"
            win.setContentSize(NSSize(width: 1180, height: 760))
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.center()
            win.makeKeyAndOrderFront(nil)
            self.window = win
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        controlServer?.stop()
        MainActor.assumeIsolated { store?.shutdownAll() }
    }

    /// Start the orchard-cli control socket. The handler runs on a worker thread, so it hops
    /// to the main actor (where `store` lives) and waits briefly for the result.
    private func startControlServer(store: WorkspaceStore) {
        let server = OrchardControlServer()
        do {
            try server.start { command in
                var response = OrchardResponse.error("timed out")
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    response = MainActor.assumeIsolated { store.handle(command) }
                    sem.signal()
                }
                _ = sem.wait(timeout: .now() + 8)
                return response
            }
            controlServer = server
        } catch {
            NSLog("orchard: control server failed to start: %@", String(describing: error))
        }
    }

    // MARK: - Menu actions

    @MainActor @objc func newWorkspace(_ sender: Any?) { store.addWorkspaceViaPanel() }
    /// Cmd-T — new mission-less session as a TAB (stacked): pick engine, type mission in-terminal.
    @MainActor @objc func newTask(_ sender: Any?) { store.requestNewSession(mode: .tabs) }
    /// Cmd-D — new mission-less session BESIDE (grid/side-by-side).
    @MainActor @objc func newAgentBeside(_ sender: Any?) { store.requestNewSession(mode: .grid) }
    /// Compose a pre-defined mission (the old Cmd-T behavior) — also on the toolbar "+".
    @MainActor @objc func addMission(_ sender: Any?) { store.requestAddTaskForSelected() }

    // Global zoom — apply to every agent terminal in the front window. (Per-terminal zoom
    // is handled by the plain Zoom In/Out items, which target the focused surface via the
    // responder chain.)
    @MainActor @objc func zoomAllIn(_ sender: Any?) { surfaces().forEach { $0.zoomIn(nil) } }
    @MainActor @objc func zoomAllOut(_ sender: Any?) { surfaces().forEach { $0.zoomOut(nil) } }
    @MainActor @objc func resetAllZoom(_ sender: Any?) { surfaces().forEach { $0.resetZoom(nil) } }

    /// Every terminal surface in the key/main window's view hierarchy.
    private func surfaces() -> [DamsonSurfaceView] {
        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
        guard let root = window?.contentView else { return [] }
        var found: [DamsonSurfaceView] = []
        func walk(_ v: NSView) {
            if let s = v as? DamsonSurfaceView { found.append(s) }
            v.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Orchard", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Orchard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        let nw = NSMenuItem(title: "New Workspace…", action: #selector(newWorkspace(_:)), keyEquivalent: "n")
        nw.target = self
        fileMenu.addItem(nw)
        let nt = NSMenuItem(title: "New Session (Tab)…", action: #selector(newTask(_:)), keyEquivalent: "t")
        nt.target = self
        fileMenu.addItem(nt)
        let nb = NSMenuItem(title: "New Session Beside…", action: #selector(newAgentBeside(_:)), keyEquivalent: "d")
        nb.target = self
        fileMenu.addItem(nb)
        let am = NSMenuItem(title: "Add Mission…", action: #selector(addMission(_:)), keyEquivalent: "t")
        am.keyEquivalentModifierMask = [.command, .shift]; am.target = self
        fileMenu.addItem(am)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        // Per-terminal: target the focused surface via the responder chain (nil target).
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(DamsonSurfaceView.zoomIn(_:)), keyEquivalent: "=")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(DamsonSurfaceView.zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(DamsonSurfaceView.resetZoom(_:)), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        // Global: every terminal in the front window.
        let zai = NSMenuItem(title: "Zoom All In", action: #selector(zoomAllIn(_:)), keyEquivalent: "=")
        zai.keyEquivalentModifierMask = [.command, .option]; zai.target = self
        viewMenu.addItem(zai)
        let zao = NSMenuItem(title: "Zoom All Out", action: #selector(zoomAllOut(_:)), keyEquivalent: "-")
        zao.keyEquivalentModifierMask = [.command, .option]; zao.target = self
        viewMenu.addItem(zao)
        let zar = NSMenuItem(title: "Reset All Zoom", action: #selector(resetAllZoom(_:)), keyEquivalent: "0")
        zar.keyEquivalentModifierMask = [.command, .option]; zar.target = self
        viewMenu.addItem(zar)

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
