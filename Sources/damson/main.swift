import AppKit
import Combine
import DamsonControl
import DamsonAgents
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
final class DamsonWindowController: NSWindowController, NSWindowDelegate, PaneTreeHosting, PaneCommandTarget {
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
        tree.host = self
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

    @objc func applyPaneLayout(_ sender: NSMenuItem) {
        guard let template = sender.representedObject as? PaneLayoutTemplate else { return }
        tree.applyLayout(template)
    }

    /// For damson-cli IPC.
    func applyLayout(_ template: PaneLayoutTemplate) {
        tree.applyLayout(template)
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

    // Id-addressed pane commands (`--pane <id>`) — single tree, so each is the compact
    // controller's per-tab logic without the tab search.

    func surfaceView(for session: DamsonSession) -> DamsonSurfaceView? {
        tree.surfaceView(for: session)
    }

    func focusPane(from session: DamsonSession, _ dir: PaneFocusDirection) -> Bool {
        guard let leaf = tree.leaf(for: session) else { return false }
        tree.moveFocus(dir, from: leaf)
        return true
    }

    func closePane(for session: DamsonSession) -> Bool {
        guard let leaf = tree.leaf(for: session) else { return false }
        tree.requestClose(leaf)
        return true
    }

    func resizePane(for session: DamsonSession, _ dir: PaneFocusDirection, cells: Int) -> Bool? {
        guard let win = window, let leaf = tree.leaf(for: session) else { return nil }
        return tree.resizeDivider(
            from: leaf, dir,
            fraction: WindowResize.dividerFraction(dir, cells: cells,
                                                   session: session, window: win))
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
        // Terminate all of this window's pane sessions. `terminateAllForClose` (not
        // root.terminateAll) so a pane that was just dragged out to ANOTHER window — leaving
        // this window empty — keeps running there instead of being killed here.
        tree.terminateAllForClose()
        // If this is the last window, the application terminates automatically
        // (applicationShouldTerminateAfterLastWindowClosed == true).
    }

    /// `PaneTreeHosting` — a cross-window pane drop landed in this single-tree window: bring it forward.
    func revealTree(_ tree: PaneTreeView) {
        window?.makeKeyAndOrderFront(nil)
    }
}

final class DamsonAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Live single-session controllers (Standard/Auto mode).
    fileprivate var controllers: [DamsonWindowController] = []
    /// Live multi-session controllers (Compact mode).
    fileprivate var compactControllers: [CompactWindowController] = []
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    /// IPC with damson-cli. Bound after the first window is created.
    private var controlSocket: ControlSocketServer?
    /// Active tmux -CC integrations (one per attach). Kept alive here so the client + host
    /// window survive; removed on teardown — see docs/TMUX-INTEGRATION.md (P1).
    private var tmuxControllers: [TmuxIntegrationController] = []
    /// Agent-status badges for panes running Claude Code. Owned here so its sweep timer
    /// lives exactly as long as the app does.
    private var crew: CrewController?
    /// Fans agent state changes out to `watch-agents` subscribers.
    let agentEvents = AgentEventBroadcaster()

    // Restart-survival intent flags (see docs/SESSION-KEEPER.md). All three mean
    // "this termination should hand sessions to the keeper" when the feature is on:
    /// Sparkle is about to install an update and relaunch us (set by DamsonUpdater).
    var updateRelaunchPending = false
    /// The user picked "Restart Damson" (app menu) — relaunch after exit.
    private var restartRequested = false
    /// The user picked "Keep Sessions & Quit" in the quit dialog.
    private var keepQuitRequested = false

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
            // Restart survival: if the previous instance handed sessions to a keeper,
            // claim the fds back FIRST — the restore below then builds those leaves
            // around the still-running children instead of spawning fresh shells.
            // No keeper answering → empty map → every leaf takes today's fresh-spawn
            // path on its own.
            var adopted: [String: AdoptedSession] = [:]
            if let generation = state.handoffGeneration {
                var wanted: [String] = []
                func collect(_ pane: RestorablePane) {
                    switch pane {
                    case .leaf(_, _, let sessionID, _, _, _):
                        if let sessionID { wanted.append(sessionID) }
                    case .split(_, _, let a, let b):
                        collect(a)
                        collect(b)
                    }
                }
                for w in state.windows { for t in w.tabs { collect(t) } }
                if !wanted.isEmpty {
                    adopted = SessionHandoff.claim(generation: generation, wanted: wanted)
                }
            }
            for restoreWindow in state.windows {
                spawnCompactWindow(restoring: restoreWindow) { adopted.removeValue(forKey: $0) }
            }
            // A claimed fd whose leaf vanished from the layout (shouldn't happen — the
            // state and keeper are separate stores): close it, so the child gets SIGHUP
            // instead of leaking as an invisible, undrained orphan.
            for (_, leftover) in adopted { close(leftover.fd) }
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
        // Label panes with what the Claude Code session inside them is doing. Reads only —
        // a timer sweep, never the output path. Costs nothing on a machine with no agents.
        crew = CrewController(windows: { [weak self] in self?.compactControllers ?? [] },
                              broadcaster: agentEvents,
                              paneID: { PaneRegistry.shared.id(for: $0) })
        crew?.start()
    }

    /// Just before termination — save the layout + cwd of the current Compact windows.
    func applicationWillTerminate(_ notification: Notification) {
        for c in controllers { for s in c.sessions { s.terminate() } }

        // Restart survival: hand the compact panes' PTYs to the keeper instead of killing
        // them. ORDER MATTERS — handOffAll snapshots preamble/cwd and releases each PTY,
        // so it must run BEFORE any terminate sweep, and toRestorable(handoff:) must run
        // AFTER (it reads the released sessions' snapshots from the records). Whatever
        // could not be handed off (tmux panes, release failures) is terminated as always.
        let keep = SessionHandoff.keepEnabled
            && (updateRelaunchPending || restartRequested || keepQuitRequested)
            && !compactControllers.isEmpty
        var handoffRecords: [ObjectIdentifier: SessionHandoffRecord] = [:]
        var generation: String?
        if keep, let result = SessionHandoff.handOffAll(controllers: compactControllers) {
            generation = result.generation
            handoffRecords = result.records
        }
        for cc in compactControllers {
            for s in cc.allPaneSessions where handoffRecords[ObjectIdentifier(s)] == nil {
                s.terminate()
            }
        }
        // Save session state (Compact windows only — single-session/native-tab modes
        // aren't restored). Clear old scrollback files before capturing (toRestorable
        // writes fresh ones when the setting is on — and always for handed-off leaves).
        SessionRestore.resetScrollbackDir()
        let windows = compactControllers.map { $0.toRestorableWindow(handoff: handoffRecords) }
        if windows.isEmpty {
            SessionRestore.clear()
        } else {
            SessionRestore.save(RestorableState(windows: windows, handoffGeneration: generation))
        }

        // "Restart Damson": relaunch once we're fully gone. The helper outlives us (its
        // own session via /bin/sh; no controlling-tty tie to this process).
        if restartRequested {
            // -n: force a fresh instance of THIS bundle path — plain `open` may just
            // activate another running copy that shares the bundle identifier.
            let script = "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.1; done; "
                + "/usr/bin/open -n \"\(Bundle.main.bundlePath)\""
            let relauncher = Process()
            relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
            relauncher.arguments = ["-c", script]
            try? relauncher.run()
        }
    }

    /// App menu → "Restart Damson". With keep-sessions on, panes and their programs
    /// survive into the relaunched instance — same mechanism as an update relaunch.
    @objc func restartDamson(_ sender: Any?) {
        restartRequested = true
        NSApp.terminate(nil)
        // Reached only when termination was cancelled (e.g. a modal sheet objected).
        restartRequested = false
    }

    // MARK: - damson-cli IPC

    private func bindControlSocket() {
        let server = ControlSocketServer()
        // Before start(): start() launches the accept thread, and a client that connects in
        // that instant must already find the stream hook installed — otherwise `watch-agents`
        // falls through to the request/response dispatch and gets an error.
        server.streamHandler = { [weak self] fd in
            self?.serveAgentWatch(fd: fd)
        }
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
        case .sendText(let text):               return controlSendText(text, cmd.target)
        case .sendKeys(let names):              return controlSendKeys(names, cmd.target)
        case .resizeWindow(let cols, let rows): return controlResizeWindow(cols: cols, rows: rows)
        case .resizePane(let dir, let amount):  return controlResizePane(dir, amount, cmd.target)
        case .focusPane(let dir):               return controlFocusPane(dir, cmd.target)
        case .closePane:                        return controlClosePane(cmd.target)
        case .listPanes:                        return controlListPanes()
        case .dumpGrid:                         return controlDumpGrid(cmd.target)
        case .zoom(let action):                 return controlZoom(action, cmd.target)
        case .applyLayout(let name):            return controlApplyLayout(name)
        case .spawnPane(let spec):              return controlSpawnPane(spec)
        case .listAgents:                       return controlListAgents()
        case .paneInfo:                         return controlPaneInfo(cmd.target)
        case .setTitle(let title):              return controlSetTitle(title, cmd.target)
        case .listGroups:                       return controlListGroups()
        case .closeGroup(let name):             return controlCloseGroup(name)
        case .setGroupCollapsed(let n, let c):  return controlSetGroupCollapsed(n, c)
        case .renameGroup(let n, let to):       return controlRenameGroup(n, to: to)
        case .moveGroup(let n, let to):         return controlMoveGroup(n, to: to)
        case .watchAgents:
            // Never reached: the socket server intercepts this before dispatch, because it
            // is a stream rather than a request/response. Handled here only so the switch
            // stays exhaustive and a future command can't be forgotten.
            return .err("watch-agents is a streaming command")
        }
    }

    /// Serve one `watch-agents` subscription. Runs on that connection's own thread and
    /// owns the fd until the client leaves.
    ///
    /// Writes are the only liveness signal available: a subscriber that has gone away is
    /// discovered when a write fails (EPIPE — SIGPIPE is already disabled on the socket),
    /// which is why the loop keeps a heartbeat rather than blocking forever on a quiet
    /// machine. Without it a killed client would leave a thread parked on a semaphore for
    /// the life of the app.
    private func serveAgentWatch(fd: Int32) {
        let (handle, backlog) = agentEvents.subscribe()
        defer { agentEvents.unsubscribe(handle) }

        func send(_ lines: [AgentEventLine]) -> Bool {
            for line in lines {
                guard var data = try? JSONEncoder().encode(line) else { continue }
                data.append(0x0A)
                let ok = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
                    guard let base = raw.baseAddress else { return false }
                    var sent = 0
                    while sent < data.count {
                        let n = write(fd, base.advanced(by: sent), data.count - sent)
                        if n < 0 {
                            if errno == EINTR { continue }
                            return false   // EPIPE: the subscriber is gone
                        }
                        if n == 0 { return false }
                        sent += n
                    }
                    return true
                }
                if !ok { return false }
            }
            return true
        }

        // Start from the present: a coordinator connecting mid-run needs what is already
        // running, not just what changes next.
        guard send(backlog) else { return }
        while true {
            guard let lines = agentEvents.next(handle, timeout: 20) else { return }
            if lines.isEmpty {
                // Heartbeat — an empty JSON object, so a reader that parses per line sees
                // something harmless and a dead peer is detected by the write failing.
                guard send([AgentEventLine(event: "heartbeat", pane: "")]) else { return }
                continue
            }
            guard send(lines) else { return }
        }
    }

    // MARK: Addressable panes

    /// Panes opened through `spawn-pane`, keyed by the caller's idempotency token.
    ///
    /// The control handler waits only 2s for the main actor and then reports a timeout —
    /// *while the queued work still runs*. So a spawn that overruns (easy behind a tab
    /// animation) tells the client it failed for a pane that did open. Without this table a
    /// retry would mint a second agent; with it, the retry gets the first pane's id.
    /// Entries are dropped once their pane is gone, so the table cannot grow without bound.
    private var spawnedByKey: [String: UUID] = [:]

    @MainActor
    private func controlSpawnPane(_ spec: SpawnSpec) -> ControlResponse {
        if let key = spec.key, let existing = spawnedByKey[key] {
            if let session = PaneRegistry.shared.session(for: existing) {
                return .pane(paneInfo(for: session, id: existing))
            }
            spawnedByKey.removeValue(forKey: key)   // its pane closed; a repeat opens a new one
        }
        guard !spec.argv.isEmpty else { return .err("spawn-pane requires a non-empty argv") }
        // Checked before a tab is created, so a bad path costs nothing. Without this the
        // pane opened, ran in whatever the app inherited (`/`), and reported success —
        // and a driver that read the cwd back was told the placement had happened.
        if let cwd = spec.cwd, let problem = PTYHost.cwdProblem(cwd) {
            return .err("cannot use cwd '\(cwd)': \(problem)")
        }
        guard let window = activeCompact() ?? { spawnWindow(); return activeCompact() }() else {
            return .err("no window to spawn into")
        }
        var config = DamsonConfig.fromUserDefaults()
        config.argv = spec.argv
        config.cwd = spec.cwd ?? window.activePaneDirectory
        let session: DamsonSession?
        if let split = spec.split {
            window.splitActivePane(direction: split == .vertical ? .vertical : .horizontal,
                                   configOverride: config)
            session = window.activeSession
        } else {
            session = window.addNewTab(configOverride: config)
        }
        guard let session else { return .err("failed to open a pane") }
        // Label before answering: a coordinator opening several agents in a loop would
        // otherwise show a row of identically-named tabs until each follow-up call lands.
        if let title = spec.title { _ = window.setTabTitle(containing: session, to: title) }
        // Grouping can move the tab, so it must happen before the id is reported — the
        // caller's next command may address this pane immediately.
        if let group = spec.group { window.joinGroup(containing: session, named: group) }
        let id = PaneRegistry.shared.id(for: session)
        if let key = spec.key { spawnedByKey[key] = id }
        return .pane(paneInfo(for: session, id: id))
    }

    /// Every pane in every compact window, with the id that addresses it.
    @MainActor
    private func controlListAgents() -> ControlResponse {
        var out: [PaneInfo] = []
        for controller in compactControllers {
            for (tabIndex, session) in controller.sessionsByTab() {
                out.append(paneInfo(for: session, id: PaneRegistry.shared.id(for: session),
                                    tab: tabIndex,
                                    active: session === controller.activeSession))
            }
        }
        return .panes(out)
    }

    // MARK: Pane-target resolution

    /// A `PaneTarget` resolved to a live session, or the typed error to answer with.
    private enum ResolvedPane {
        case session(DamsonSession)
        case failure(ControlResponse)
    }

    /// One resolution path for every pane-addressed command. `.id` NEVER falls back to the
    /// active pane: a driver that addressed "pane X" must be told X is gone, not have its
    /// bytes land in whatever pane happens to be focused.
    @MainActor
    private func resolvePane(_ target: PaneTarget) -> ResolvedPane {
        switch target {
        case .active:
            guard let session = activeControlSession() else {
                return .failure(.err("no active pane"))
            }
            return .session(session)
        case .id(let raw):
            guard let uuid = UUID(uuidString: raw) else {
                return .failure(.err("not a pane id: \(raw)"))
            }
            guard let session = PaneRegistry.shared.session(for: uuid) else {
                return .failure(.err("no such pane: \(raw)"))
            }
            return .session(session)
        }
    }

    /// Every controller that can own an addressed pane — compact first (spawn-pane only
    /// opens panes there), then single-session windows (whose active pane can also be
    /// handed an id via pane-info).
    @MainActor
    private var paneTargets: [PaneCommandTarget] {
        compactControllers as [PaneCommandTarget] + controllers
    }

    @MainActor
    private func controlPaneInfo(_ target: PaneTarget) -> ControlResponse {
        switch resolvePane(target) {
        case .failure(let resp): return resp
        case .session(let session):
            // The tab index matters here as much as in `list-agents`: it is how a driver
            // brings a pane it is holding an id for into view, and without it a coordinator
            // can tell the user which agent is blocked but not take them to it.
            let (tab, active) = placement(of: session)
            return .pane(paneInfo(for: session, id: PaneRegistry.shared.id(for: session),
                                  tab: tab, active: active))
        }
    }

    /// Which tab a pane is in, and whether it is the focused one. `pane-info` reported
    /// neither: it defaulted `active` to false, so the focused pane described itself as not
    /// focused, and omitted `tab` entirely — which left a driver holding an id with no way
    /// to bring that pane into view.
    @MainActor
    private func placement(of session: DamsonSession) -> (tab: Int?, active: Bool) {
        for controller in compactControllers {
            if let index = controller.tabIndex(containing: session) {
                return (index, session === controller.activeSession)
            }
        }
        return (nil, false)
    }

    /// Label the tab holding the addressed pane. An empty title clears the label and hands
    /// the tab back to the child's own title, which is what a double-click rename to "" does.
    ///
    /// Tab-level rather than pane-level on purpose: `spawn` without a split opens a tab per
    /// agent, and the tab is what the user reads when scanning for the one that needs them.
    @MainActor
    private func controlSetTitle(_ title: String, _ target: PaneTarget) -> ControlResponse {
        switch resolvePane(target) {
        case .failure(let resp): return resp
        case .session(let session):
            // A pane can live in any window, not just the active one — addressing it must
            // not depend on which window happens to be in front.
            for controller in compactControllers
            where controller.setTabTitle(containing: session, to: title) {
                return .ok()
            }
            return .err("pane is not in any open tab")
        }
    }

    // MARK: Tab groups

    @MainActor
    private func controlListGroups() -> ControlResponse {
        .groups(compactControllers.flatMap { $0.groupRows() })
    }

    /// Close a whole group. Destructive — several tabs and the processes inside them — so a
    /// name that matches nothing is a typed error, never a quiet success. A coordinator
    /// mistyping a run name must not be told the run was cleaned up.
    @MainActor
    private func controlCloseGroup(_ name: String) -> ControlResponse {
        for controller in compactControllers {
            if let closed = controller.closeGroup(named: name) {
                return closed > 0 ? .ok() : .err("group '\(name)' has no tabs")
            }
        }
        return .err("no such group: \(name)")
    }

    @MainActor
    private func controlSetGroupCollapsed(_ name: String, _ collapsed: Bool) -> ControlResponse {
        for controller in compactControllers {
            switch controller.setGroupCollapsed(named: name, collapsed) {
            case .ok: return .ok()
            case .wouldHideEverything:
                return .err("group '\(name)' holds every tab in its window; folding it would leave nothing visible")
            case .noSuchGroup: continue
            }
        }
        return .err("no such group: \(name)")
    }

    @MainActor
    private func controlRenameGroup(_ name: String, to newName: String) -> ControlResponse {
        for controller in compactControllers where controller.renameGroup(named: name, to: newName) {
            return .ok()
        }
        return .err("no such group: \(name)")
    }

    /// Move a whole group. Exercises the same controller path the header drag uses, so the
    /// two cannot drift.
    @MainActor
    private func controlMoveGroup(_ name: String, to index: Int) -> ControlResponse {
        for controller in compactControllers where controller.groupName(exists: name) {
            controller.moveGroup(named: name, to: index)
            return .ok()
        }
        return .err("no such group: \(name)")
    }

    /// The group holding a pane's tab, for `agents` / `pane-info`. A coordinator joins its
    /// task list against these rows, so a group it just created has to be readable back.
    @MainActor
    private func groupName(for session: DamsonSession) -> String? {
        for controller in compactControllers {
            if let name = controller.groupName(containing: session) { return name }
        }
        return nil
    }

    /// What the user actually reads on the tab: a pinned label if one is set, otherwise the
    /// program's own title. A coordinator maps its tasks onto tabs by this field, so
    /// reporting the raw OSC title would hide the very label it just set.
    @MainActor
    private func effectiveTitle(for session: DamsonSession) -> String? {
        for controller in compactControllers {
            if let label = controller.tabTitle(containing: session), !label.isEmpty {
                return label
            }
        }
        return session.title.isEmpty ? nil : session.title
    }

    @MainActor
    private func paneInfo(for session: DamsonSession, id: UUID,
                          tab: Int? = nil, active: Bool = false) -> PaneInfo {
        PaneInfo(index: 0, cols: session.grid.cols, rows: session.grid.rows, active: active,
                 id: id.uuidString, tab: tab,
                 pid: session.foregroundProcessID,
                 // Observed before tracked. `currentDirectory` starts life as the cwd that
                 // was REQUESTED and is only corrected by OSC 7, which most non-shells never
                 // emit — so preferring it reports an intention as a fact.
                 cwd: session.currentWorkingDirectory ?? session.currentDirectory,
                 title: effectiveTitle(for: session),
                 agent: crew?.badge(for: session)?.rawValue,
                 group: groupName(for: session))
    }

    // MARK: Tab / window control

    @MainActor
    private func controlSplit(_ dir: SplitDir) -> ControlResponse {
        let direction: SplitDirection = (dir == .vertical) ? .vertical : .horizontal
        guard withActiveTarget({ $0.splitActive(direction: direction) }) != nil else {
            return .err("no active window to split")
        }
        return .ok()
    }

    @MainActor
    private func controlApplyLayout(_ name: String) -> ControlResponse {
        guard let template = PaneLayoutTemplate(rawValue: name) else {
            let names = PaneLayoutTemplate.allCases.map { $0.rawValue }.joined(separator: ", ")
            return .err("unknown layout '\(name)'. options: \(names)")
        }
        guard withActiveTarget({ $0.applyLayout(template) }) != nil else {
            return .err("no active window")
        }
        return .ok()
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
    private func controlSendText(_ text: String, _ target: PaneTarget) -> ControlResponse {
        switch resolvePane(target) {
        case .failure(let resp): return resp
        case .session(let session):
            guard let data = text.data(using: .utf8) else { return .err("invalid UTF-8 text") }
            session.write(data)
            return .ok()
        }
    }

    @MainActor
    private func controlSendKeys(_ names: [String], _ target: PaneTarget) -> ControlResponse {
        switch resolvePane(target) {
        case .failure(let resp): return resp
        case .session(let session):
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
    }

    // MARK: Pane / window sizing, focus & inspection

    @MainActor
    private func controlResizeWindow(cols: Int, rows: Int) -> ControlResponse {
        guard let ok = withActiveTarget({ $0.resizeWindowToGrid(cols: cols, rows: rows) }) else {
            return .err("no active window to resize")
        }
        return ok ? .ok() : .err("no active pane to size")
    }

    @MainActor
    private func controlResizePane(_ dir: PaneDir, _ amount: Int,
                                   _ target: PaneTarget) -> ControlResponse {
        let focusDir = paneFocusDirection(dir)
        if case .active = target {
            guard let ok = withActiveTarget({ $0.resizeActivePane(focusDir, cells: amount) }) else {
                return .err("no active window")
            }
            return ok ? .ok() : .err("active pane has no split to resize toward \(dir.rawValue)")
        }
        switch resolvePane(target) {
        case .failure(let resp): return resp
        case .session(let session):
            for owner in paneTargets {
                guard let resized = owner.resizePane(for: session, focusDir, cells: amount) else {
                    continue
                }
                return resized ? .ok()
                    : .err("pane has no split to resize toward \(dir.rawValue)")
            }
            return .err("pane is not attached to any window")
        }
    }

    @MainActor
    private func controlFocusPane(_ dir: PaneDir, _ target: PaneTarget) -> ControlResponse {
        let focusDir = paneFocusDirection(dir)
        if case .active = target {
            guard withActiveTarget({ $0.focusActivePane(focusDir) }) != nil else {
                return .err("no active window")
            }
            return .ok()
        }
        switch resolvePane(target) {
        case .failure(let resp): return resp
        case .session(let session):
            guard paneTargets.contains(where: { $0.focusPane(from: session, focusDir) }) else {
                return .err("pane is not attached to any window")
            }
            return .ok()
        }
    }

    @MainActor
    private func controlClosePane(_ target: PaneTarget) -> ControlResponse {
        if case .active = target {
            guard withActiveTarget({ $0.closeActivePane() }) != nil else {
                return .err("no active window")
            }
            return .ok()
        }
        switch resolvePane(target) {
        case .failure(let resp): return resp
        case .session(let session):
            guard paneTargets.contains(where: { $0.closePane(for: session) }) else {
                return .err("pane is not attached to any window")
            }
            return .ok()
        }
    }

    @MainActor
    private func controlListPanes() -> ControlResponse {
        guard let list = withActiveTarget({ $0.paneList() }) else {
            return .err("no active window")
        }
        return .panes(list)
    }

    @MainActor
    private func controlDumpGrid(_ target: PaneTarget) -> ControlResponse {
        switch resolvePane(target) {
        case .failure(let resp): return resp
        case .session(let session): return .grid(Self.gridText(of: session))
        }
    }

    @MainActor
    private func controlZoom(_ action: String, _ target: PaneTarget) -> ControlResponse {
        let surface: DamsonSurfaceView
        if case .active = target {
            guard let active = activeCompact()?.activeSurfaceView
                    ?? activeSingleController()?.activeSurfaceView else {
                return .err("no active pane")
            }
            surface = active
        } else {
            switch resolvePane(target) {
            case .failure(let resp): return resp
            case .session(let session):
                guard let owned = paneTargets.lazy
                        .compactMap({ $0.surfaceView(for: session) }).first else {
                    return .err("pane is not attached to any window")
                }
                surface = owned
            }
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
        // No `?? controllers.first` fallback: when the key window is a non-terminal window
        // (Settings/About), return nil so control commands error out rather than silently
        // applying to an arbitrary background terminal. Mirrors activeCompact().
        return controllers.first(where: { $0.window === keyWindow })
    }

    /// Dispatch a pane-level command to whichever controller kind owns the active window
    /// (compact first, then single-session). Returns nil when there's no active window —
    /// the one place the "try compact, else single, else none" resolution lives.
    @MainActor
    private func withActiveTarget<T>(_ body: (PaneCommandTarget) -> T) -> T? {
        if let compact = activeCompact() { return body(compact) }
        if let single = activeSingleController() { return body(single) }
        return nil
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

    /// "About Damson" — a custom branded panel (icon, version, links) instead of the standard
    /// AppKit about box. Single reused window.
    @objc func showAbout(_ sender: Any?) {
        let win = aboutWindow ?? makeAboutWindow()
        aboutWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        // Hide the redundant title text — the tab bar already labels the window — and
        // make the titlebar transparent so the tab strip reads as one cohesive top area
        // rather than being crammed under a separate title row.
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
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
    /// With the keep-sessions feature on, the dialog gains "Keep Sessions & Quit" — the panes'
    /// programs keep running in the background and the next launch reattaches to them.
    /// Restart-type terminations (update install, Restart Damson) never ask: keeping the
    /// sessions is the point of those, and Sparkle already ran its own confirmation UI.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if updateRelaunchPending || restartRequested { return .terminateNow }
        let sessions = allSessions()
        let busy = sessions.filter { $0.hasRunningForegroundJob }.count
        let total = sessions.count
        guard busy > 0 || total > 1 else { return .terminateNow }

        let keepOffered = SessionHandoff.keepEnabled && !compactControllers.isEmpty

        let alert = NSAlert()
        alert.alertStyle = .warning
        if busy > 0 {
            alert.messageText = busy == 1
                ? "A process is still running."
                : "\(busy) processes are still running."
            alert.informativeText = keepOffered
                ? "\"Keep Sessions & Quit\" leaves "
                    + (busy == 1 ? "it" : "them")
                    + " running in the background; the next launch picks them up right where they are. "
                    + "\"Quit\" terminates " + (busy == 1 ? "it." : "them.")
                : "Quitting Damson will terminate "
                    + (busy == 1 ? "it." : "them.") + " Quit anyway?"
        } else {
            alert.messageText = "Damson has \(total) open tabs/panes."
            alert.informativeText = keepOffered
                ? "\"Keep Sessions & Quit\" keeps their shells running in the background; "
                    + "the next launch picks them up right where they are. \"Quit\" closes them all."
                : "Quitting will close them all. Quit anyway?"
        }
        if keepOffered {
            alert.addButton(withTitle: "Keep Sessions & Quit")  // first (default / Return)
            alert.addButton(withTitle: "Quit")                  // second
            alert.addButton(withTitle: "Cancel")                // third (Esc via key equivalent)
            alert.buttons.last?.keyEquivalent = "\u{1b}"
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                keepQuitRequested = true
                return .terminateNow
            case .alertSecondButtonReturn:
                return .terminateNow
            default:
                return .terminateCancel
            }
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

    /// Open a pane running Claude Code, in the active pane's directory.
    ///
    /// damson mints the session id so the pane and the conversation share an identifier it
    /// chose — that is what lets a later `--resume` reattach a pane to its own transcript.
    /// The prompt (when there is one) would go in argv; damson never types into the pane.
    @MainActor
    @objc func newAgentTab(_ sender: Any?) {
        openAgent(inNewTab: true)
    }

    @MainActor
    @objc func newAgentPane(_ sender: Any?) {
        openAgent(inNewTab: false)
    }

    @MainActor
    private func openAgent(inNewTab: Bool) {
        guard let active = activeCompact() else {
            // No compact window to host it — make one first, then place the agent in it.
            spawnWindow()
            if activeCompact() != nil { openAgent(inNewTab: inNewTab) }
            return
        }
        let cwd = active.activePaneDirectory
        let config = AgentLaunch.config(
            base: DamsonConfig.fromUserDefaults(), cwd: cwd,
            sessionID: UUID(), label: AgentLaunch.label(for: cwd))
        let session: DamsonSession?
        if inNewTab {
            session = active.addNewTab(configOverride: config)
        } else {
            active.splitActivePane(direction: .horizontal, configOverride: config)
            session = active.activeSession
        }
        // Give it a stable id up front: an agent pane is exactly the kind a driver will want
        // to address later, and minting now means the id exists before anyone asks.
        if let session { PaneRegistry.shared.id(for: session) }
    }

    /// Enabled only when `claude` is actually installed — a menu item that opens a pane and
    /// immediately prints "command not found" is worse than one that is greyed out.
    @objc func validateAgentMenuItem(_ item: NSMenuItem) -> Bool {
        AgentLaunch.isAvailable(env: DamsonConfig.fromUserDefaults().env)
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
        // Block observers keyed on `object:` are NOT auto-removed when the window
        // deallocs, so a discarded token leaks one dead observer per window open/close
        // cycle. Capture the token and remove it when it fires (once, on window close).
        let box = ObserverTokenBox()
        box.token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window, queue: .main
        ) { [weak self, weak controller] _ in
            if let t = box.token {
                NotificationCenter.default.removeObserver(t)
                box.token = nil
            }
            guard let self = self, let controller = controller else { return }
            self.controllers.removeAll { $0 === controller }
        }
        controllers.append(controller)
        controller.showWindow(nil)
    }

    private func spawnCompactWindow(restoring: RestorableWindow? = nil,
                                    adopt: (String) -> AdoptedSession? = { _ in nil }) {
        let controller = CompactWindowController(restoring: restoring, adopt: adopt)
        let box = ObserverTokenBox()
        box.token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window, queue: .main
        ) { [weak self, weak controller] _ in
            if let t = box.token {
                NotificationCenter.default.removeObserver(t)
                box.token = nil
            }
            guard let self = self, let controller = controller else { return }
            self.compactControllers.removeAll { $0 === controller }
        }
        compactControllers.append(controller)
        controller.showWindow(nil)
    }
}

/// Reference holder so a one-shot NotificationCenter block observer can remove itself
/// from inside its own handler without the "var mutated after capture by a @Sendable
/// closure" warning (the closure captures this immutable `let` and mutates its property).
private final class ObserverTokenBox {
    var token: NSObjectProtocol?
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
    // About — custom branded window (DamsonAboutView). No target → routes up the responder
    // chain to the app delegate's showAbout(_:).
    appMenu.addItem(NSMenuItem(
        title: "About Damson",
        action: #selector(DamsonAppDelegate.showAbout(_:)),
        keyEquivalent: ""
    ))
    // Disabled version line under About (standard macOS app-menu pattern).
    let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    let versionItem = NSMenuItem(title: "Version \(short) (\(build))", action: nil, keyEquivalent: "")
    versionItem.isEnabled = false
    appMenu.addItem(versionItem)
    appMenu.addItem(NSMenuItem.separator())
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
    // With "Keep sessions running across restarts" on, this restarts the app while every
    // pane's program keeps running — same survival mechanism as an update relaunch.
    let restartItem = NSMenuItem(
        title: "Restart Damson",
        action: #selector(DamsonAppDelegate.restartDamson(_:)),
        keyEquivalent: ""
    )
    appMenu.addItem(restartItem)
    appMenu.addItem(menuItem("Quit Damson", #selector(NSApplication.terminate(_:)), .quit))
}

private func buildFileMenu(into mainMenu: NSMenu) {
    let fileMenu = addSubmenu("File", to: mainMenu)
    fileMenu.addItem(menuItem("New Window", #selector(DamsonAppDelegate.newWindow(_:)), .newWindow))
    // Cmd+T — in Compact mode add a tab to the active window, otherwise a new window (native tab group join).
    fileMenu.addItem(menuItem("New Tab", #selector(DamsonAppDelegate.newTab(_:)), .newTab))
    // Agent panes. No default shortcut on purpose — these are new, and claiming a chord
    // risks colliding with one the user already relies on. They stay menu-only until the
    // rebindable catalogue grows entries for them.
    fileMenu.addItem(NSMenuItem.separator())
    let agentTab = NSMenuItem(title: "New Claude Code Tab",
                              action: #selector(DamsonAppDelegate.newAgentTab(_:)), keyEquivalent: "")
    let agentPane = NSMenuItem(title: "New Claude Code Pane",
                               action: #selector(DamsonAppDelegate.newAgentPane(_:)), keyEquivalent: "")
    // Greyed out when `claude` isn't installed, rather than opening a pane that immediately
    // prints "command not found".
    for item in [agentTab, agentPane] {
        item.isEnabled = AgentLaunch.isAvailable(env: DamsonConfig.fromUserDefaults().env)
        fileMenu.addItem(item)
    }
    fileMenu.addItem(NSMenuItem.separator())
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

    // One-shot preset layouts — split the active tab into a template arrangement at once.
    let layoutsItem = NSMenuItem(title: "Pane Layouts", action: nil, keyEquivalent: "")
    let layoutsMenu = NSMenu(title: "Pane Layouts")
    layoutsItem.submenu = layoutsMenu
    for template in PaneLayoutTemplate.allCases {
        let item = menuItem(template.title,
                            #selector(CompactWindowController.applyPaneLayout(_:)),
                            template.actionID)
        item.representedObject = template
        layoutsMenu.addItem(item)
    }
    windowMenu.addItem(layoutsItem)

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
