import AppKit
import Combine
import DamsonControl
import DamsonTerminal
import SwiftUI

// Entry point for the standalone damson.app.
// Run via SwiftPM: `swift run damson`
// A proper .app distribution will later graduate into a separate Xcode project.

// If launched as a raw binary, wrap into a .app and relaunch.
// Required to fix the Korean IME first-jamo race (LaunchServices registration).
AppBundleTrampoline.relaunchInAppBundleIfNeeded()

/// One window + one pane tree (Standard/Auto mode). Multiple windows are grouped
/// via native NSWindow tabs, and within each window Cmd+D / Cmd+Shift+D split panes.
final class DamsonWindowController: NSWindowController, NSWindowDelegate {
    private let tree: PaneTreeView
    private var titleSubscription: AnyCancellable?
    private var tabStyleApplier: TabBarStyleApplier?

    /// Leaf sessions for external callers (settingsChanged/willTerminate) to iterate.
    var sessions: [DamsonSession] { tree.root.leaves().map { $0.session } }
    /// The currently active pane's session (the first leaf if none is active).
    var activeSession: DamsonSession? {
        if case .leaf(let s, _) = tree.activeLeaf.kind { return s }
        return tree.root.leaves().first?.session
    }

    init(session: DamsonSession) {
        self.tree = PaneTreeView(rootSession: session)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Damson"
        // Bypass SwiftUI NSHostingController — the SwiftUI hosting layer adds a
        // tiny inset on the leading edge that clips the cell-grid's first column.
        // damson.app uses NSView directly instead of going through the SwiftUI API
        // meant for cmux integration.
        tree.translatesAutoresizingMaskIntoConstraints = false
        // Wrap contentView in a container so there's room to lay an NSVisualEffectView
        // under the titlebar area. (In Standard/Auto mode the inset is 0 —
        // TabBarStyleApplier only insets when compact; this controller is non-compact
        // only, so it's always 0.)
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tree)
        let surfaceTop = tree.topAnchor.constraint(equalTo: container.topAnchor)
        NSLayoutConstraint.activate([
            tree.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tree.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tree.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            surfaceTop,
        ])
        window.contentView = container
        window.contentMinSize = NSSize(width: 320, height: 200)
        window.center()
        // Windows sharing the same identifier are automatically grouped into a macOS
        // native tab group. Cmd+T creates a new tab; Cmd+Shift+] / Cmd+Shift+[ go
        // next/prev (handled automatically by AppKit).
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "damson.terminal"
        super.init(window: window)
        window.delegate = self
        // Close the window (= native tab) when its last pane closes.
        tree.onAllPanesClosed = { [weak self] in
            self?.window?.performClose(nil)
        }
        // The title follows the root's first leaf session (same policy as Compact).
        if let firstSession = tree.root.leaves().first?.session {
            titleSubscription = firstSession.$title
                .receive(on: RunLoop.main)
                .sink { [weak self] newTitle in
                    let base = newTitle.isEmpty ? "Damson" : newTitle
                    self?.window?.title = base + BuildInfo.titleSuffix
                }
        }
        // Apply the tab style the user picked in Settings (this controller is non-compact only).
        let applier = TabBarStyleApplier(
            window: window,
            container: container,
            surface: tree,
            surfaceTopConstraint: surfaceTop
        )
        applier.apply(TabBarStyle.current)
        self.tabStyleApplier = applier
        WindowChrome.applyFromDefaults(to: window)
    }

    func applyTabBarStyle(_ style: TabBarStyle) {
        tabStyleApplier?.apply(style)
    }

    // Method names match CompactWindowController — DamsonSurfaceView's Cmd+W
    // (performCloseTab:) and the Split menu (splitPaneHorizontally:/Vertically:)
    // reach both controllers identically through the responder chain.

    @objc func splitPaneHorizontally(_ sender: Any?) {
        tree.split(direction: .horizontal)
    }

    @objc func splitPaneVertically(_ sender: Any?) {
        tree.split(direction: .vertical)
    }

    /// For damson-cli IPC — takes a direction directly and splits the active pane.
    func splitActive(direction: SplitDirection) {
        tree.split(direction: direction)
    }

    /// damson-cli `focus-pane` — move focus in the pane tree.
    func focusActivePane(_ dir: PaneFocusDirection) {
        tree.moveFocus(dir)
    }

    /// damson-cli `close-pane` — close the active pane (cascades to window when last).
    func closeActivePane() {
        tree.closeActive()
    }

    /// damson-cli `resize-pane` — nudge the divider governing the active pane.
    @discardableResult
    func resizeActivePane(_ dir: PaneFocusDirection, cells: Int) -> Bool {
        guard let win = window else { return false }
        return tree.resizeActiveDivider(
            dir, fraction: WindowResize.dividerFraction(dir, cells: cells,
                                                         session: activeSession, window: win))
    }

    /// damson-cli `list-panes` — panes in traversal order.
    func paneList() -> [PaneInfo] {
        tree.paneSessionsInOrder().enumerated().map { (i, pair) in
            PaneInfo(index: i, cols: pair.session.grid.cols,
                     rows: pair.session.grid.rows, active: pair.active)
        }
    }

    /// damson-cli `zoom` — the active pane's surface (zoomIn/zoomOut/resetZoom target).
    var activeSurfaceView: DamsonSurfaceView? { tree.activeSurfaceView }

    /// damson-cli `resize-window` — size the window so the active terminal is `cols`×`rows`.
    @discardableResult
    func resizeWindowToGrid(cols: Int, rows: Int) -> Bool {
        guard let win = window, let session = activeSession else { return false }
        return WindowResize.resize(window: win, to: (cols, rows), basedOn: session)
    }

    /// Cmd+W — close the active pane. If it's the last pane, onAllPanesClosed closes the window.
    @objc func performCloseTab(_ sender: Any?) {
        tree.closeActive()
    }

    // Pane focus navigation (Cmd+Opt+arrows).
    @objc func focusPaneLeft(_ sender: Any?) { tree.moveFocus(.left) }
    @objc func focusPaneRight(_ sender: Any?) { tree.moveFocus(.right) }
    @objc func focusPaneUp(_ sender: Any?) { tree.moveFocus(.up) }
    @objc func focusPaneDown(_ sender: Any?) { tree.moveFocus(.down) }
    @objc func swapPaneLeft(_ sender: Any?) { tree.swapDirectional(.left) }
    @objc func swapPaneRight(_ sender: Any?) { tree.swapDirectional(.right) }
    @objc func swapPaneUp(_ sender: Any?) { tree.swapDirectional(.up) }
    @objc func swapPaneDown(_ sender: Any?) { tree.swapDirectional(.down) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        // Terminate all of this window's pane sessions. (PaneTreeView.deinit also
        // calls terminateAll, but do it once explicitly at window-close time —
        // double termination is idempotent since PTYHost uses childPID=-1.)
        tree.root.terminateAll()
        // If this is the last window, the application terminates automatically
        // (applicationShouldTerminateAfterLastWindowClosed == true).
    }
}

final class DamsonAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Live single-session controllers (Standard/Auto mode).
    fileprivate var controllers: [DamsonWindowController] = []
    /// Live multi-session controllers (Compact mode).
    fileprivate var compactControllers: [CompactWindowController] = []
    private var settingsWindow: NSWindow?
    /// IPC with damson-cli. Bound after the first window is created.
    private var controlSocket: ControlSocketServer?
    /// Active tmux -CC integrations (one per attach). Kept alive here so the client + host
    /// window survive; removed on teardown — see docs/TMUX-INTEGRATION.md (P1).
    private var tmuxControllers: [TmuxIntegrationController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Control macOS press-and-hold (the accent popup). When it's on, holding a key
        // makes the text input system intercept it as "waiting for an accent" and
        // suppresses key repeat (inconsistent per key — f/q/x etc. don't repeat at all).
        // A terminal needs every key to repeat, so the default is OFF (repeat). When the
        // settings toggle (damson.pressAndHold) is ON, fall back to the macOS default
        // (accent popup). Unset → false → ApplePressAndHoldEnabled=false.
        let pressAndHold = UserDefaults.standard.bool(forKey: "damson.pressAndHold")
        UserDefaults.standard.set(pressAndHold, forKey: "ApplePressAndHoldEnabled")

        // If there's prior session state and we're in Compact mode, restore that layout
        // + cwd; otherwise open a fresh window.
        if TabBarStyle.current == .compact,
           let state = SessionRestore.load(), !state.windows.isEmpty {
            for restoreWindow in state.windows {
                spawnCompactWindow(restoring: restoreWindow)
            }
        } else {
            spawnWindow()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged(_:)),
            name: .damsonSettingsChanged,
            object: nil
        )
        // Keybinding change → rebuild the menu (no refresh needed for view hooks since
        // they read the store live).
        NotificationCenter.default.addObserver(
            forName: .damsonKeybindingsChanged, object: nil, queue: .main
        ) { _ in installMainMenu() }
        // A pane ran `tmux -CC` → take its stream over into native tmux integration.
        // queue: nil = deliver synchronously on the posting (main) thread, REQUIRED so the
        // takeover backend is installed before the first control bytes are forwarded.
        NotificationCenter.default.addObserver(
            forName: DamsonSession.tmuxControlModeDetectedNotification, object: nil, queue: nil
        ) { [weak self] note in
            // Posted on main (PTY data drains on main); hop is a no-op but satisfies actors.
            MainActor.assumeIsolated {
                self?.handleTmuxControlModeDetected(note)
            }
        }
        bindControlSocket()
        // Sparkle is lazily initialized — it starts automatically on first access.
        _ = DamsonUpdater.shared
    }

    /// Just before termination — save the layout + cwd of the current Compact windows.
    func applicationWillTerminate(_ notification: Notification) {
        for c in controllers { for s in c.sessions { s.terminate() } }
        for cc in compactControllers { for s in cc.sessions { s.terminate() } }
        // Save session state (Compact windows only — single-session/native-tab modes
        // aren't restored). Clear old scrollback files before capturing (toRestorable
        // writes fresh ones when the setting is on).
        SessionRestore.resetScrollbackDir()
        let windows = compactControllers.map { $0.toRestorableWindow() }
        if windows.isEmpty {
            SessionRestore.clear()
        } else {
            SessionRestore.save(RestorableState(windows: windows))
        }
    }

    // MARK: - damson-cli IPC

    private func bindControlSocket() {
        let server = ControlSocketServer()
        do {
            let path = try server.start(handler: { [weak self] cmd in
                // handler is called on a worker thread → hop to main and wait for the result.
                guard let self = self else { return .err("damson is shutting down") }
                let sem = DispatchSemaphore(value: 0)
                var resp: ControlResponse = .err("dispatch lost")
                DispatchQueue.main.async {
                    resp = self.dispatch(controlCommand: cmd)
                    sem.signal()
                }
                let r = sem.wait(timeout: .now() + 2.0)
                if r == .timedOut {
                    return .err("timeout waiting for damson to process command")
                }
                return resp
            })
            self.controlSocket = server
            NSLog("damson: control socket listening at %@", path)
        } catch {
            NSLog("damson: failed to bind control socket: %@", String(describing: error))
        }
    }

    /// `dispatch` — called on the main actor. Routes each control command to a
    /// small per-command handler; every branch is handled synchronously. The
    /// switch stays exhaustive over `ControlCommand.Kind` (no `default`), so a
    /// new command kind is a compile error until it's wired up here.
    @MainActor
    private func dispatch(controlCommand cmd: ControlCommand) -> ControlResponse {
        switch cmd.kind {
        case .newTab:                           newTabOrWindow(); return .ok()
        case .split(let dir):                   return controlSplit(dir)
        case .closeTab:                         return controlCloseTab()
        case .switchTab(let index):             return controlSwitchTab(index)
        case .listTabs:                         return controlListTabs()
        case .sendText(let text):               return controlSendText(text)
        case .sendKeys(let names):              return controlSendKeys(names)
        case .resizeWindow(let cols, let rows): return controlResizeWindow(cols: cols, rows: rows)
        case .resizePane(let dir, let amount):  return controlResizePane(dir, amount)
        case .focusPane(let dir):               return controlFocusPane(dir)
        case .closePane:                        return controlClosePane()
        case .listPanes:                        return controlListPanes()
        case .dumpGrid:                         return controlDumpGrid()
        case .zoom(let action):                 return controlZoom(action)
        }
    }

    // MARK: Tab / window control

    @MainActor
    private func controlSplit(_ dir: SplitDir) -> ControlResponse {
        let direction: SplitDirection = (dir == .vertical) ? .vertical : .horizontal
        if let active = activeCompact() {
            active.splitActive(direction: direction)
            return .ok()
        }
        if let single = activeSingleController() {
            single.splitActive(direction: direction)
            return .ok()
        }
        return .err("no active window to split")
    }

    @MainActor
    private func controlCloseTab() -> ControlResponse {
        // If a Compact controller owns the key window, close the active tab. Otherwise close the window.
        if let active = activeCompact() {
            active.closeCurrentTab()
            return .ok()
        }
        if let win = NSApp.keyWindow ?? controllers.last?.window {
            win.performClose(nil)
            return .ok()
        }
        return .err("no active window to close")
    }

    @MainActor
    private func controlSwitchTab(_ index: Int) -> ControlResponse {
        if let active = activeCompact() {
            guard index >= 0, index < active.sessions.count else {
                return .err("tab index \(index) out of range (have \(active.sessions.count) tabs)")
            }
            active.selectTab(index)
            return .ok()
        }
        let tabs = currentNativeTabs()
        guard index >= 0, index < tabs.count else {
            return .err("tab index \(index) out of range (have \(tabs.count) tabs)")
        }
        tabs[index].makeKeyAndOrderFront(nil)
        return .ok()
    }

    @MainActor
    private func controlListTabs() -> ControlResponse {
        if let active = activeCompact() {
            // Report the actual pane (leaf) count for each tab.
            let list = active.tabPaneCounts.enumerated().map { (i, count) in
                TabInfo(index: i, pane_count: count)
            }
            return .tabs(list)
        }
        // Standard/Auto: per native tab, the pane count of that window.
        let single = controllers.filter { $0.window?.isVisible == true }
        if !single.isEmpty {
            let tabs = currentNativeTabs()
            let list = tabs.enumerated().map { (i, win) -> TabInfo in
                let count = controllers.first { $0.window === win }?.sessions.count ?? 1
                return TabInfo(index: i, pane_count: count)
            }
            return .tabs(list)
        }
        let tabs = currentNativeTabs()
        return .tabs(tabs.enumerated().map { (i, _) in TabInfo(index: i, pane_count: 1) })
    }

    // MARK: Remote input

    @MainActor
    private func controlSendText(_ text: String) -> ControlResponse {
        guard let session = activeControlSession() else { return .err("no active pane") }
        guard let data = text.data(using: .utf8) else { return .err("invalid UTF-8 text") }
        session.write(data)
        return .ok()
    }

    @MainActor
    private func controlSendKeys(_ names: [String]) -> ControlResponse {
        guard let session = activeControlSession() else { return .err("no active pane") }
        // Validate every name first so a partial chord isn't half-sent on a typo.
        var sequence = Data()
        for name in names {
            guard let bytes = keyNameToBytes(name) else {
                return .err("unknown key name: \(name)")
            }
            sequence.append(contentsOf: bytes)
        }
        session.write(sequence)
        return .ok()
    }

    // MARK: Pane / window sizing, focus & inspection

    @MainActor
    private func controlResizeWindow(cols: Int, rows: Int) -> ControlResponse {
        if let active = activeCompact() {
            return active.resizeWindowToGrid(cols: cols, rows: rows)
                ? .ok() : .err("no active pane to size")
        }
        if let single = activeSingleController() {
            return single.resizeWindowToGrid(cols: cols, rows: rows)
                ? .ok() : .err("no active pane to size")
        }
        return .err("no active window to resize")
    }

    @MainActor
    private func controlResizePane(_ dir: PaneDir, _ amount: Int) -> ControlResponse {
        let focusDir = paneFocusDirection(dir)
        if let active = activeCompact() {
            return active.resizeActivePane(focusDir, cells: amount)
                ? .ok() : .err("active pane has no split to resize toward \(dir.rawValue)")
        }
        if let single = activeSingleController() {
            return single.resizeActivePane(focusDir, cells: amount)
                ? .ok() : .err("active pane has no split to resize toward \(dir.rawValue)")
        }
        return .err("no active window")
    }

    @MainActor
    private func controlFocusPane(_ dir: PaneDir) -> ControlResponse {
        let focusDir = paneFocusDirection(dir)
        if let active = activeCompact() {
            active.focusActivePane(focusDir)
            return .ok()
        }
        if let single = activeSingleController() {
            single.focusActivePane(focusDir)
            return .ok()
        }
        return .err("no active window")
    }

    @MainActor
    private func controlClosePane() -> ControlResponse {
        if let active = activeCompact() {
            active.closeActivePane()
            return .ok()
        }
        if let single = activeSingleController() {
            single.closeActivePane()
            return .ok()
        }
        return .err("no active window")
    }

    @MainActor
    private func controlListPanes() -> ControlResponse {
        if let active = activeCompact() {
            return .panes(active.paneList())
        }
        if let single = activeSingleController() {
            return .panes(single.paneList())
        }
        return .err("no active window")
    }

    @MainActor
    private func controlDumpGrid() -> ControlResponse {
        guard let session = activeControlSession() else { return .err("no active pane") }
        return .grid(Self.gridText(of: session))
    }

    @MainActor
    private func controlZoom(_ action: String) -> ControlResponse {
        guard let surface = activeCompact()?.activeSurfaceView
                ?? activeSingleController()?.activeSurfaceView else {
            return .err("no active pane")
        }
        switch action {
        case "in": surface.zoomIn(nil)
        case "out": surface.zoomOut(nil)
        case "reset": surface.resetZoom(nil)
        default: return .err("zoom requires in|out|reset")
        }
        return .ok()
    }

    /// Plain-text snapshot of the session grid's visible rows (continuation/wide-spacer
    /// cells skipped), one line per row. For damson-cli dump-grid — remote rendering
    /// inspection. (Takes the session, not the Grid, to dodge the SwiftUI.Grid name clash.)
    private static func gridText(of session: DamsonSession) -> String {
        let g = session.grid
        var lines: [String] = []
        lines.reserveCapacity(g.rows)
        for r in 0..<g.rows {
            var s = ""
            for c in g.row(r) where !c.isContinuation && !c.isWideSpacer {
                s.append(c.char)
            }
            lines.append(s)
        }
        return lines.joined(separator: "\n")
    }

    /// The active pane's session, resolving across compact and single-session controllers.
    @MainActor
    private func activeControlSession() -> DamsonSession? {
        activeCompact()?.activeSession ?? activeSingleController()?.activeSession
    }

    /// Map the wire-level pane direction onto the local pane-focus enum.
    private func paneFocusDirection(_ dir: PaneDir) -> PaneFocusDirection {
        switch dir {
        case .left: return .left
        case .right: return .right
        case .up: return .up
        case .down: return .down
        }
    }

    /// The controller if the current key window is one owned by a CompactWindowController.
    @MainActor
    private func activeCompact() -> CompactWindowController? {
        guard let keyWindow = NSApp.keyWindow else {
            return compactControllers.first
        }
        return compactControllers.first(where: { $0.window === keyWindow })
    }

    /// The controller if the current key window is one owned by a DamsonWindowController (Standard/Auto).
    @MainActor
    private func activeSingleController() -> DamsonWindowController? {
        guard let keyWindow = NSApp.keyWindow else {
            return controllers.first
        }
        return controllers.first(where: { $0.window === keyWindow }) ?? controllers.first
    }

    /// The list of windows in the native tab group (Standard/Auto mode).
    @MainActor
    private func currentNativeTabs() -> [NSWindow] {
        if let key = NSApp.keyWindow {
            if let group = key.tabbedWindows { return group }
            return [key]
        }
        if let first = controllers.first?.window {
            if let group = first.tabbedWindows { return group }
            return [first]
        }
        return []
    }

    @objc func showSettings(_ sender: Any?) {
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = DamsonSettingsView()
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "Damson Settings"
        win.styleMask = [.titled, .closable, .resizable]
        win.setContentSize(NSSize(width: 540, height: 600))
        win.isReleasedWhenClosed = false
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func settingsChanged(_ note: Notification) {
        // Push the new config to every active session — every pane of every tab of
        // every window. Miss one and that pane keeps the old font/theme/cursor.
        let newConfig = DamsonConfig.fromUserDefaults()
        let newTabStyle = TabBarStyle.current
        for c in controllers {
            // Hot-reload every split pane — miss one and that pane keeps the old font/theme.
            for s in c.sessions { s.updateConfig(newConfig) }
            c.applyTabBarStyle(newTabStyle)
            if let w = c.window { WindowChrome.applyFromDefaults(to: w) }
        }
        for cc in compactControllers {
            // allPaneSessions, not sessions — the latter is only each tab's first leaf,
            // so split panes would keep the old config until restart.
            for s in cc.allPaneSessions { s.updateConfig(newConfig) }
            cc.refreshPaneIndicators()
            cc.applyTabBarBackground()   // reflect theme/transparency option changes
            if let w = cc.window { WindowChrome.applyFromDefaults(to: w) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Every pane session across every tab of every window (single-session + Compact).
    private func allSessions() -> [DamsonSession] {
        controllers.flatMap { $0.sessions } + compactControllers.flatMap { $0.allPaneSessions }
    }

    /// Confirmation dialog on ⌘Q / Quit. Ask if a foreground command is running or if there
    /// are 2 or more open sessions (tabs/panes). A single idle session quits immediately without asking.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let sessions = allSessions()
        let busy = sessions.filter { $0.hasRunningForegroundJob }.count
        let total = sessions.count
        guard busy > 0 || total > 1 else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        if busy > 0 {
            alert.messageText = busy == 1
                ? "A process is still running."
                : "\(busy) processes are still running."
            alert.informativeText = "Quitting Damson will terminate "
                + (busy == 1 ? "it." : "them.") + " Quit anyway?"
        } else {
            alert.messageText = "Damson has \(total) open tabs/panes."
            alert.informativeText = "Quitting will close them all. Quit anyway?"
        }
        alert.addButton(withTitle: "Quit")     // .alertFirstButtonReturn (default / Return)
        alert.addButton(withTitle: "Cancel")   // .alertSecondButtonReturn (Esc)
        // Bring the active window forward — so the dialog is visible even if ⌘Q arrives in the background.
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Cmd+N — always a new window.
    @objc func newWindow(_ sender: Any?) {
        spawnWindow()
    }

    /// "Attach tmux (-CC)…" — prompt for an optional target session, then spawn a tmux -CC
    /// control client whose windows render as Damson tabs (P1). Empty target = new session.
    /// See docs/TMUX-INTEGRATION.md.
    @MainActor
    @objc func attachTmux(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Attach tmux (-CC)"
        alert.informativeText = "Enter a tmux target session to attach to, or leave blank to start a new session."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "session name (blank = new)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Attach")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let target = field.stringValue.trimmingCharacters(in: .whitespaces)
        var controller: TmuxIntegrationController!
        controller = TmuxIntegrationController(onTeardown: { [weak self] in
            self?.tmuxControllers.removeAll { $0 === controller }
        })
        tmuxControllers.append(controller)
        controller.start(target: target.isEmpty ? nil : target)
    }

    /// tmux ▸ Detach — cleanly detach the control client of the tmux host window that is
    /// currently key. The session keeps running server-side; `%exit` closes the window.
    @MainActor
    @objc func detachTmux(_ sender: Any?) {
        tmuxController(for: NSApp.keyWindow)?.detach()
    }

    /// Enable "Detach" only while the key window belongs to a tmux integration.
    @MainActor
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(detachTmux(_:)) {
            return tmuxController(for: NSApp.keyWindow) != nil
        }
        return true
    }

    /// The Window menu's tab-navigation chrome (Show Next/Previous Tab + dividers). Populated
    /// by `buildWindowMenu`; shown only when the active window has 2+ tabs.
    var windowTabItems: [NSMenuItem] = []

    /// The numbered "Tab 1…9" items (tag = 1-based number). Each is shown only when that many
    /// tabs actually exist — 2 tabs show Tab 1–2, 3 show Tab 1–3, etc.
    var windowTabNumberItems: [NSMenuItem] = []

    /// The Window menu's pane focus/swap items (and their dividers). Populated by
    /// `buildWindowMenu`; shown only when the active tab has 2+ panes. Split stays visible —
    /// it's what creates the second pane.
    var windowPaneItems: [NSMenuItem] = []

    /// Number of tabs in the active window, across Compact (tab list) and Standard/Auto
    /// (native tab group) modes.
    @MainActor
    func currentTabCount() -> Int {
        if let active = activeCompact() { return active.tabPaneCounts.count }
        return currentNativeTabs().count
    }

    /// Number of panes in the active tab, across Compact and Standard/Auto modes.
    @MainActor
    func currentPaneCount() -> Int {
        if let active = activeCompact() { return active.paneList().count }
        if let single = activeSingleController() { return single.paneList().count }
        return 1
    }

    /// Just before the Window menu opens, hide the per-tab items when there's a single tab and
    /// the pane focus/swap items when there's a single pane — those actions are meaningless
    /// until a second tab/pane exists.
    @MainActor
    func menuNeedsUpdate(_ menu: NSMenu) {
        let tabCount = currentTabCount()
        let multipleTabs = tabCount >= 2
        for item in windowTabItems { item.isHidden = !multipleTabs }
        // Show only as many numbered items as there are tabs (tag is the 1-based number).
        for item in windowTabNumberItems { item.isHidden = !multipleTabs || item.tag > tabCount }
        let multiplePanes = currentPaneCount() >= 2
        for item in windowPaneItems { item.isHidden = !multiplePanes }
    }

    @MainActor
    private func tmuxController(for window: NSWindow?) -> TmuxIntegrationController? {
        guard let window else { return nil }
        return tmuxControllers.first { $0.hostWindow === window }
    }

    /// A local pane's stream entered tmux `-CC` control mode (the user ran `tmux -CC` in
    /// it). Take the stream over into a native tmux integration — same UI as the menu
    /// attach, no manual step. Must run synchronously within the notification so the first
    /// control bytes (delivered right after the post) land in the takeover backend.
    @MainActor
    func handleTmuxControlModeDetected(_ note: Notification) {
        guard let session = note.object as? DamsonSession else { return }
        var controller: TmuxIntegrationController!
        controller = TmuxIntegrationController(takeoverFrom: session, onTeardown: { [weak self] in
            self?.tmuxControllers.removeAll { $0 === controller }
        })
        tmuxControllers.append(controller)
        // Size from the host pane's current grid so tmux lays out at the real dimensions.
        controller.startTakeover(cols: session.grid.cols, rows: session.grid.rows)
    }

    /// Cmd+T — if the active window is Compact, add a tab there; otherwise open a new window.
    @MainActor
    @objc func newTab(_ sender: Any?) {
        newTabOrWindow()
    }

    /// Cmd+W — for a terminal window, close the active pane (if it's the last, cascade tab→window);
    /// for any other window (Settings, etc.) close the whole window. When a menu key-equiv is wired
    /// directly to NSWindow.performClose, there's a bug where the whole window closes even with multiple
    /// tabs, so we centralize the logic here.
    @MainActor
    @objc func closeTabOrWindow(_ sender: Any?) {
        guard let win = NSApp.keyWindow else { return }
        // The windowController of a Compact/single-session terminal window implements
        // per-pane close (performCloseTab). If it does, dispatch there; otherwise close the window.
        let sel = #selector(CompactWindowController.performCloseTab(_:))
        if let wc = win.windowController, wc.responds(to: sel) {
            wc.perform(sel, with: sender)
        } else {
            win.performClose(sender)
        }
    }

    @MainActor
    private func newTabOrWindow() {
        if let active = activeCompact() {
            active.addNewTab()
            return
        }
        spawnWindow()
    }

    private func spawnWindow() {
        let style = TabBarStyle.current
        if style == .compact {
            spawnCompactWindow()
        } else {
            spawnSingleSessionWindow()
        }
    }

    private func spawnSingleSessionWindow() {
        let session = DamsonSession(config: DamsonConfig.fromUserDefaults())
        let controller = DamsonWindowController(session: session)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window, queue: .main
        ) { [weak self, weak controller] _ in
            guard let self = self, let controller = controller else { return }
            self.controllers.removeAll { $0 === controller }
        }
        controllers.append(controller)
        controller.showWindow(nil)
    }

    private func spawnCompactWindow(restoring: RestorableWindow? = nil) {
        let controller = CompactWindowController(restoring: restoring)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window, queue: .main
        ) { [weak self, weak controller] _ in
            guard let self = self, let controller = controller else { return }
            self.compactControllers.removeAll { $0 === controller }
        }
        compactControllers.append(controller)
        controller.showWindow(nil)
    }
}

// MARK: - Minimal menu bar

/// Rebuilt whenever keybindings change (`.damsonKeybindingsChanged`). All shortcut
/// equivalents come from `KeyBindingStore` rather than being hardcoded, so a remap
/// in Settings takes effect by just calling this again.
/// A rebindable menu item: title + selector come from us, the shortcut from the keybinding store.
private func menuItem(_ title: String, _ selector: Selector?, _ id: AppAction.ID,
                      target: AnyObject? = nil, tag: Int = 0) -> NSMenuItem {
    let it = NSMenuItem(title: title, action: selector, keyEquivalent: "")
    KeyBindingStore.shared.apply(id, to: it)
    if let target = target { it.target = target }
    if tag != 0 { it.tag = tag }
    return it
}

/// Attach a titled submenu to `mainMenu` and return it for population.
private func addSubmenu(_ title: String, to mainMenu: NSMenu) -> NSMenu {
    let item = NSMenuItem()
    mainMenu.addItem(item)
    let submenu = NSMenu(title: title)
    item.submenu = submenu
    return submenu
}

private func buildAppMenu(into mainMenu: NSMenu) {
    let appMenu = addSubmenu("", to: mainMenu)
    appMenu.addItem(menuItem("Settings…", #selector(DamsonAppDelegate.showSettings(_:)), .settings))
    appMenu.addItem(NSMenuItem.separator())
    // Sparkle auto-update — the target is the SPUStandardUpdaterController itself.
    let updateItem = NSMenuItem(
        title: "Check for Updates…",
        action: NSSelectorFromString("checkForUpdates:"),
        keyEquivalent: ""
    )
    updateItem.target = DamsonUpdater.shared.target
    appMenu.addItem(updateItem)
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(menuItem("Quit Damson", #selector(NSApplication.terminate(_:)), .quit))
}

private func buildFileMenu(into mainMenu: NSMenu) {
    let fileMenu = addSubmenu("File", to: mainMenu)
    fileMenu.addItem(menuItem("New Window", #selector(DamsonAppDelegate.newWindow(_:)), .newWindow))
    // Cmd+T — in Compact mode add a tab to the active window, otherwise a new window (native tab group join).
    fileMenu.addItem(menuItem("New Tab", #selector(DamsonAppDelegate.newTab(_:)), .newTab))
    // Cmd+W — close the tab/pane (not the whole window). For a terminal window, close the active
    // pane and cascade tab→window when it's the last. For a non-terminal window (Settings, etc.) close the window.
    fileMenu.addItem(menuItem("Close Tab", #selector(DamsonAppDelegate.closeTabOrWindow(_:)), .closeTab))
    // Cmd+Shift+W — explicitly close the whole window.
    fileMenu.addItem(menuItem("Close Window", #selector(NSWindow.performClose(_:)), .closeWindow))
}

private func buildEditMenu(into mainMenu: NSMenu) {
    // Copy/Paste — our view's copy:/paste: are caught via the responder chain.
    let editMenu = addSubmenu("Edit", to: mainMenu)
    editMenu.addItem(menuItem("Copy", #selector(NSText.copy(_:)), .copy))
    editMenu.addItem(menuItem("Paste", #selector(NSText.paste(_:)), .paste))
    editMenu.addItem(menuItem("Select All", #selector(NSResponder.selectAll(_:)), .selectAll))
    editMenu.addItem(menuItem("Copy Last Command Output",
                              #selector(DamsonSurfaceView.copyLastCommandOutput(_:)), .copyLastCommandOutput))
    editMenu.addItem(NSMenuItem.separator())
    editMenu.addItem(menuItem("Find…", NSSelectorFromString("performFindPanelAction:"), .find))
    editMenu.addItem(menuItem("Find Next", #selector(DamsonSurfaceView.findNextMatch), .findNext))
    editMenu.addItem(menuItem("Find Previous", #selector(DamsonSurfaceView.findPreviousMatch), .findPrevious))
}

private func buildViewMenu(into mainMenu: NSMenu) {
    let viewMenu = addSubmenu("View", to: mainMenu)
    viewMenu.addItem(menuItem("Zoom In", #selector(DamsonSurfaceView.zoomIn(_:)), .zoomIn))
    viewMenu.addItem(menuItem("Zoom Out", #selector(DamsonSurfaceView.zoomOut(_:)), .zoomOut))
    viewMenu.addItem(menuItem("Actual Size", #selector(DamsonSurfaceView.resetZoom(_:)), .resetZoom))
    viewMenu.addItem(NSMenuItem.separator())
    // ⌘↑ / ⌘↓ — prompt jump. The actual dispatch is handled by DamsonSurfaceView's key hook
    // (matching arrow+⌘); these items are for menu display + click. The store fills in keyEquivalent.
    viewMenu.addItem(menuItem("Jump to Previous Prompt",
                              #selector(DamsonSurfaceView.jumpToPreviousPrompt(_:)), .jumpPreviousPrompt))
    viewMenu.addItem(menuItem("Jump to Next Prompt",
                              #selector(DamsonSurfaceView.jumpToNextPrompt(_:)), .jumpNextPrompt))
    viewMenu.addItem(NSMenuItem.separator())
    // Full-screen toggle — the macOS-standard ⌃⌘F. toggleFullScreen: is implemented by NSWindow → responder chain.
    viewMenu.addItem(menuItem("Toggle Full Screen", #selector(NSWindow.toggleFullScreen(_:)), .toggleFullScreen))
    // Performance HUD toggle (⌃⌘H = our custom graph, ⌃⌘J = Apple Metal HUD).
    viewMenu.addItem(menuItem("Toggle Performance HUD",
                              #selector(DamsonSurfaceView.togglePerformanceHUD(_:)), .togglePerfHUD))
    viewMenu.addItem(menuItem("Toggle Apple Metal HUD",
                              #selector(DamsonSurfaceView.toggleAppleMetalHUD(_:)), .toggleAppleHUD))
}

private func buildWindowMenu(into mainMenu: NSMenu, delegate: DamsonAppDelegate) {
    let windowMenu = addSubmenu("Window", to: mainMenu)
    // Switching/numbering tabs only makes sense with 2+ tabs — `menuNeedsUpdate` hides the
    // tab items collected here whenever the active window has a single tab.
    windowMenu.delegate = delegate

    // --- Tab navigation ---
    // NSMenu's punctuation key-equivalent matching for ⌘⇧] / ⌘⇧[ is unreliable
    // (charactersIgnoringModifiers applies Shift → "}"/"{", and letters case-fold
    // but punctuation doesn't). These items stay for menu DISPLAY + click; the
    // actual keystroke is dispatched by DamsonSurfaceView's key hook, the same
    // path ⌘W already uses. (store fills the displayed equivalent.)
    let nextTab = menuItem("Show Next Tab", NSSelectorFromString("selectNextTab:"), .nextTab)
    let prevTab = menuItem("Show Previous Tab", NSSelectorFromString("selectPreviousTab:"), .previousTab)
    let tabInnerSeparator = NSMenuItem.separator()
    windowMenu.addItem(nextTab)
    windowMenu.addItem(prevTab)
    windowMenu.addItem(tabInnerSeparator)

    // Cmd+1..9 — go to the nth tab. tag holds the 1-based number; menuNeedsUpdate shows only
    // as many of these as there are tabs.
    var tabNumberItems: [NSMenuItem] = []
    for n in 1...9 {
        let item = NSMenuItem(
            title: "Tab \(n)",
            action: NSSelectorFromString("selectTabByNumber:"),
            keyEquivalent: "\(n)"
        )
        item.keyEquivalentModifierMask = [.command]
        item.tag = n
        windowMenu.addItem(item)
        tabNumberItems.append(item)
    }
    // The divider between tabs and panes belongs to the tab group, so hiding the tabs (single
    // tab) leaves the pane section below without a dangling leading separator.
    let tabSectionEnd = NSMenuItem.separator()
    windowMenu.addItem(tabSectionEnd)

    // All hidden until a second tab exists; `menuNeedsUpdate` re-evaluates before each open.
    let tabChrome = [nextTab, prevTab, tabInnerSeparator, tabSectionEnd]
    (tabChrome + tabNumberItems).forEach { $0.isHidden = true }
    delegate.windowTabItems = tabChrome
    delegate.windowTabNumberItems = tabNumberItems

    // --- Pane layout (formerly the standalone "Split" menu) ---
    // Panes are window subdivisions, so they belong next to tabs rather than in their own
    // top-level menu. Reaches the active window controller via the responder chain.
    // Split is always available — it's what creates the second pane.
    windowMenu.addItem(menuItem("Split Horizontally",
                                #selector(CompactWindowController.splitPaneHorizontally(_:)), .splitHorizontally))
    windowMenu.addItem(menuItem("Split Vertically",
                                #selector(CompactWindowController.splitPaneVertically(_:)), .splitVertically))

    // Focus/Swap only make sense with 2+ panes. Collected (with their leading dividers) so
    // `menuNeedsUpdate` hides them on a single pane, leaving just Split above.
    let paneFocusSeparator = NSMenuItem.separator()
    // Pane focus navigation — default Cmd+Opt+arrows (rebindable via the store).
    let focusLeft = menuItem("Focus Pane Left", NSSelectorFromString("focusPaneLeft:"), .focusPaneLeft)
    let focusRight = menuItem("Focus Pane Right", NSSelectorFromString("focusPaneRight:"), .focusPaneRight)
    let focusDown = menuItem("Focus Pane Down", NSSelectorFromString("focusPaneDown:"), .focusPaneDown)
    let focusUp = menuItem("Focus Pane Up", NSSelectorFromString("focusPaneUp:"), .focusPaneUp)
    let paneSwapSeparator = NSMenuItem.separator()
    // Cmd+Shift+arrows — swap position with the adjacent pane (the same swap as ⌘⇧+click).
    let swapLeft = menuItem("Swap Pane Left", NSSelectorFromString("swapPaneLeft:"), .swapPaneLeft)
    let swapRight = menuItem("Swap Pane Right", NSSelectorFromString("swapPaneRight:"), .swapPaneRight)
    let swapDown = menuItem("Swap Pane Down", NSSelectorFromString("swapPaneDown:"), .swapPaneDown)
    let swapUp = menuItem("Swap Pane Up", NSSelectorFromString("swapPaneUp:"), .swapPaneUp)
    let paneItems = [paneFocusSeparator, focusLeft, focusRight, focusDown, focusUp,
                     paneSwapSeparator, swapLeft, swapRight, swapDown, swapUp]
    paneItems.forEach { windowMenu.addItem($0); $0.isHidden = true }
    delegate.windowPaneItems = paneItems
}

private func buildToolsMenu(into mainMenu: NSMenu) {
    // Tools — integrations and utilities. Currently the tmux control-mode (-CC) entry points
    // (docs/TMUX-INTEGRATION.md); no default shortcuts, added directly rather than via the store.
    let toolsMenu = addSubmenu("Tools", to: mainMenu)
    let attachItem = NSMenuItem(
        title: "Attach tmux (-CC)…",
        action: #selector(DamsonAppDelegate.attachTmux(_:)),
        keyEquivalent: ""
    )
    toolsMenu.addItem(attachItem)
    // Enabled (via validateMenuItem) only while the key window is a tmux host. Leaves the
    // session running server-side; closing the window does the same (detach, never kill).
    let detachItem = NSMenuItem(
        title: "Detach tmux",
        action: #selector(DamsonAppDelegate.detachTmux(_:)),
        keyEquivalent: ""
    )
    toolsMenu.addItem(detachItem)
}

func installMainMenu() {
    let mainMenu = NSMenu()
    buildAppMenu(into: mainMenu)
    buildFileMenu(into: mainMenu)
    buildEditMenu(into: mainMenu)
    buildViewMenu(into: mainMenu)
    buildWindowMenu(into: mainMenu, delegate: appDelegate)
    buildToolsMenu(into: mainMenu)
    NSApp.mainMenu = mainMenu
}

// MARK: - Boot

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let appDelegate = DamsonAppDelegate()
app.delegate = appDelegate

// Hook that resolves app-level shortcuts (tab switch, prompt jump, close, quit) against
// the user's keybindings. Installed once; it reads the store live so rebinds take effect immediately.
DamsonSurfaceView.appKeyEquivalentHook = { view, event in
    KeyBindingStore.shared.handleViewKeyEquivalent(event, on: view)
}

installMainMenu()

app.activate(ignoringOtherApps: true)
app.run()
