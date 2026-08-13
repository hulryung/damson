import AppKit
import Combine
import DamsonControl
import DamsonAgents
import DamsonTerminal

/// NSWindow that delivers tab-bar clicks immediately. The tab bar lives in the
/// titlebar region of a `fullSizeContentView` window; the theme frame holds
/// every titlebar click for the system double-click interval (~0.5s) to detect
/// the title-bar double-click action (zoom/minimize), which made clicking a tab
/// feel laggy (~0.5s before anything happened — measured). When a left-mouse
/// event hits a tab (an `ImmediateTitlebarClick` view) we forward it straight to
/// that view and return, skipping the theme-frame delay. The whole down→drag→up
/// sequence routes to the same target. Everything else (empty bar area, the +
/// button, terminal content) goes through `super`, so window drag-to-move and
/// double-click-to-zoom on the empty titlebar are unchanged.
final class CompactWindow: NSWindow {
    private weak var clickTarget: NSView?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if let target = contentView?.hitTest(event.locationInWindow) as? ImmediateTitlebarClick {
                clickTarget = target
                target.mouseDown(with: event)
                return
            }
            clickTarget = nil
        case .leftMouseDragged:
            if let target = clickTarget {
                target.mouseDragged(with: event)
                return
            }
        case .leftMouseUp:
            if let target = clickTarget {
                clickTarget = nil
                target.mouseUp(with: event)
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }
}

/// Window controller dedicated to compact mode. A single NSWindow multiplexes N
/// DamsonSessions. NSWindow's native tabs are disabled (`tabbingMode = .disallowed`)
/// and a custom CompactTabBarView sits at the top of contentView so the tabs share a
/// row with the traffic lights.
///
/// Borrows the MainWindowController structure from hiterm (`~/dev/hiterm`).
final class CompactWindowController: NSWindowController, NSWindowDelegate, TabSwipeHandler, PaneTreeHosting, PaneCommandTarget {
    /// A tab = (PaneTreeView, a subscription to the title of that tree's first leaf session).
    /// Splitting within a tab via Cmd+D / Cmd+Shift+D adds a leaf to that tab's tree.
    struct Tab {
        let tree: PaneTreeView
        var titleSub: AnyCancellable
        /// User-assigned title set via double-click. If nil, follows the session (process/OSC) title.
        var customTitle: String?
        /// Live agent status for this tab's first pane, appended to whatever title is shown.
        /// Deliberately NOT folded into `customTitle`: that is the user's rename slot, it
        /// short-circuits `displayTitle`, and it is persisted per-tab into the restore blob —
        /// writing a transient status there would both hide the real title and survive a restart.
        var agentSuffix: String?
    }

    /// Animation intent threaded through `selectTab` / `addTab`. `.none` = instant
    /// (today's behavior; restore, keyboard nav, tab-bar click, close-show-next).
    /// `.create` = a brand-new tab's content fades + scales in (Task 2).
    /// `.switch(fromIndex:towardRight:)` = the tab-switch crossfade/slide (Task 6);
    /// carries the index we came **from**. `towardRight` is the direction the content
    /// should travel, for the callers where the index sign is not the intent: ⌘→ off
    /// the LAST tab wraps to index 0, and sliding rightward there — as the indices
    /// imply — plays the animation backwards against the key that was pressed. nil
    /// means derive it from the indices, which is right for a click or ⌘1…9, where
    /// the index order IS what the user asked for.
    enum TabTransition {
        case none
        case create
        case `switch`(fromIndex: Int, towardRight: Bool?)
    }
    private(set) var tabs: [Tab] = []
    private(set) var currentIndex: Int = 0

    /// Tab cross-slide / create motion and the interactive trackpad swipe.
    ///
    /// `private(set)` is load-bearing, not style: the coordinator's `unowned host` is safe only
    /// because this is the ONLY strong reference to it, so no other file may alias or replace it.
    /// `lazy` lets it capture `self` without an init-ordering dance; it first materialises in
    /// `selectTab`, which runs after `setupViews()`. `selectTab` is therefore main-thread-only in
    /// a newly load-bearing way — a concurrent first call could torn-initialise a lazy var into
    /// two coordinators and split the swipe state.
    private(set) lazy var tabTransitions = TabTransitionCoordinator(host: self)

    /// Session representation for external list-tabs / switch-tab, etc.
    /// Each tab's root pane (first leaf) session — used to track the tab title.
    var sessions: [DamsonSession] {
        tabs.compactMap { $0.tree.root.leaves().first?.session }
    }

    /// All sessions across all tabs × all panes (for exhaustive checks like quit confirmation — `sessions` gives only the first leaf per tab).
    var allPaneSessions: [DamsonSession] {
        tabs.flatMap { $0.tree.root.leaves().map { $0.session } }
    }

    /// damson-cli `zoom` — the active tab's active pane surface.
    var activeSurfaceView: DamsonSurfaceView? {
        guard currentIndex < tabs.count else { return nil }
        return tabs[currentIndex].tree.activeSurfaceView
    }

    /// The active pane of the current active tab (the focused side when split).
    var activeSession: DamsonSession? {
        guard currentIndex < tabs.count else { return nil }
        let tree = tabs[currentIndex].tree
        if case .leaf(let s, _) = tree.activeLeaf.kind { return s }
        return nil
    }

    private(set) var tabBar: CompactTabBarView!
    private var tabBarBackground: NSVisualEffectView!   // for transparent (frosted) mode
    private var tabBarSolid: NSView!                    // for solid (theme-colored) mode — over the vibrancy
    private(set) var contentContainer: NSView!
    private static let tabBarHeight: CGFloat = 38
    private var tabBarTopConstraint: NSLayoutConstraint!
    /// Frame observers on the traffic lights — see `observeTrafficLights`.
    private var trafficLightObservers: [NSObjectProtocol] = []
    /// Identities of the buttons those observers are bound to, so a titlebar rebuild
    /// (which recreates the buttons) is detected and observation re-registers.
    private var observedTrafficLightIDs: [ObjectIdentifier] = []
    private var tabBarBackgroundHeightConstraint: NSLayoutConstraint!
    private var tabBarSolidHeightConstraint: NSLayoutConstraint!
    /// Tab-bar top inset. Kept at 0 even in full screen so the tab bar shows as a single
    /// top row. (Lowering it to make room for the menu bar created an empty band, making it
    /// look like two rows — and since the menu bar is normally hidden in full screen and
    /// only briefly overlaps on top-edge hover per standard macOS behavior, a single row is preferred.)
    private var fullScreenTopInset: CGFloat { 0 }

    // Tab-slide motion. The trackpad swipe settle uses the longer duration: the
    // finger has already dragged the content most of the way, so the 0.42s is
    // just the release deceleration and reads as natural follow-through.
    static let tabSlideDuration: TimeInterval = 0.42
    // A discrete click/keyboard switch settles with a real spring (tabSlideSpring): the tab
    // rushes in and eases organically into place. A spring's deceleration reads more naturally
    // ("elastic") than a fixed bezier, and the long, smooth tail is the visible "arrival".
    /// Spring for the click/keyboard slide. ζ ≈ 0.82 — underdamped enough to feel elastic, damped
    /// enough that it doesn't bounce awkwardly (a whisper of overshoot, ~1% of the travel). Tuned
    /// to settle a touch slower than the old 0.30s ease (the "lengthen it" ask). Works for any
    /// keyPath — `transform.translation.x` (content) or `position` (the tab-bar pill).
    static func tabSlideSpring(_ keyPath: String, from: Any, to: Any) -> CASpringAnimation {
        let s = CASpringAnimation(keyPath: keyPath)
        s.fromValue = from
        s.toValue = to
        s.mass = 1
        s.stiffness = 150
        s.damping = 20
        s.initialVelocity = 0
        s.duration = s.settlingDuration
        return s
    }
    /// The spring's natural settling time — paces the wrapping animation group / pill transaction.
    static var tabSlideSpringDuration: TimeInterval { tabSlideSpring("x", from: 0, to: 1).settlingDuration }
    static func tabSlideTiming() -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)   // strong ease-out (trackpad swipe)
    }

    var hasTabs: Bool { !tabs.isEmpty }

    /// If `restoring` is present, restore that tab/pane layout + cwd; otherwise a single
    /// empty tab. `adopt` resolves a saved leaf's sessionID to a surviving PTY reclaimed
    /// from the keeper (restart survival) — the default adopts nothing.
    init(restoring: RestorableWindow? = nil,
         adopt: (String) -> AdoptedSession? = { _ in nil }) {
        let window = CompactWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Damson"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentMinSize = NSSize(width: 480, height: 240)
        window.center()
        // Native tabs OFF — use our own custom-drawn tab bar.
        window.tabbingMode = .disallowed
        window.appearance = NSAppearance(named: .darkAqua)

        super.init(window: window)
        window.delegate = self

        setupViews()
        WindowChrome.applyFromDefaults(to: window)

        if let restore = restoring, !restore.tabs.isEmpty {
            for (i, paneRestore) in restore.tabs.enumerated() {
                let root = PaneNode.from(restorable: paneRestore, adopt: adopt)
                let title = restore.tabTitles.flatMap { i < $0.count ? $0[i] : nil }
                addTab(tree: PaneTreeView(restoredRoot: root), customTitle: title)
            }
            let sel = restore.selectedTab
            if sel >= 0 && sel < tabs.count { selectTab(sel) }
        } else {
            addNewTab()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Serialize the current window's tab/pane layout + cwd. `handoff` marks the sessions
    /// just released to the keeper so their leaves carry adoption ids (see toRestorable).
    func toRestorableWindow(handoff: [ObjectIdentifier: SessionHandoffRecord] = [:]) -> RestorableWindow {
        RestorableWindow(
            tabs: tabs.map { $0.tree.root.toRestorable(handoff: handoff) },
            selectedTab: currentIndex,
            tabTitles: tabs.map { $0.customTitle }
        )
    }

    deinit {
        for s in sessions { s.terminate() }
        for token in trafficLightObservers { NotificationCenter.default.removeObserver(token) }
    }

    private func setupViews() {
        guard let contentView = window?.contentView else { return }

        // Vibrancy laid under the titlebar area (background behind the traffic lights + tabs).
        tabBarBackground = NSVisualEffectView()
        tabBarBackground.material = .hudWindow
        tabBarBackground.blendingMode = .behindWindow
        tabBarBackground.state = .followsWindowActiveState
        tabBarBackground.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabBarBackground)

        // Solid (theme-colored) background — over the vibrancy, under the tabs. Covers the vibrancy in solid mode.
        tabBarSolid = NSView()
        tabBarSolid.wantsLayer = true
        tabBarSolid.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabBarSolid)

        // Custom tab bar.
        tabBar = CompactTabBarView()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onTabSelected = { [weak self] idx in
            guard let self = self else { return }
            self.selectTab(idx, transition: .switch(fromIndex: self.currentIndex, towardRight: nil))
        }
        tabBar.onTabClosed = { [weak self] idx in self?.closeTab(idx) }
        tabBar.onNewTab = { [weak self] in self?.addNewTab() }
        tabBar.onTabReordered = { [weak self] from, to in self?.reorderTab(from: from, to: to) }
        tabBar.onTabRenamed = { [weak self] idx, title in self?.renameTab(idx, to: title) }
        contentView.addSubview(tabBar)

        // Container holding the session surfaces — fills below the tab bar.
        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        // Host for the tab-close animation overlay (snapshot layer) — made layer-backed up front.
        contentContainer.wantsLayer = true
        contentView.addSubview(contentContainer)

        // Our tab bar is drawn in the titlebar's place (starting at 0). In full screen it is
        // lowered by the menu-bar height (`tabBarTopConstraint.constant`) so the tabs aren't
        // covered when the menu bar appears. tabBarBackground (vibrancy) covers from the very
        // top down to below the tab bar as a single band.
        let tabBarHeight = Self.tabBarHeight
        let inset = fullScreenTopInset
        tabBarTopConstraint = tabBar.topAnchor.constraint(
            equalTo: contentView.topAnchor, constant: inset)
        tabBarBackgroundHeightConstraint = tabBarBackground.heightAnchor.constraint(
            equalToConstant: tabBarHeight + inset)
        tabBarSolidHeightConstraint = tabBarSolid.heightAnchor.constraint(
            equalToConstant: tabBarHeight + inset)

        NSLayoutConstraint.activate([
            tabBarBackground.topAnchor.constraint(equalTo: contentView.topAnchor),
            tabBarBackground.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tabBarBackground.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tabBarBackgroundHeightConstraint,

            tabBarSolid.topAnchor.constraint(equalTo: contentView.topAnchor),
            tabBarSolid.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tabBarSolid.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tabBarSolidHeightConstraint,

            tabBarTopConstraint,
            tabBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: tabBarHeight),

            contentContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        applyTabBarBackground()
        // Re-position the traffic lights after the window buttons are laid out. On the next
        // runloop, since they do not exist yet during setup.
        DispatchQueue.main.async { [weak self] in
            self?.centerTrafficLights()
            self?.observeTrafficLights()
        }
    }

    /// Update the tab-bar top inset and background height on full-screen enter/exit.
    private func updateFullScreenInset() {
        let inset = fullScreenTopInset
        tabBarTopConstraint?.constant = inset
        tabBarBackgroundHeightConstraint?.constant = Self.tabBarHeight + inset
        tabBarSolidHeightConstraint?.constant = Self.tabBarHeight + inset
        tabBar.needsLayout = true
    }

    /// Tab-bar background: solid theme background color by default, with transparent (frosted) selectable via settings.
    func applyTabBarBackground() {
        let transparent = UserDefaults.standard.bool(forKey: "damson.tabBarTransparent")
        tabBarSolid?.isHidden = transparent
        let theme = activeSession?.config.theme ?? DamsonConfig.fromUserDefaults().theme
        let bg = (theme.background.usingColorSpace(.sRGB)) ?? theme.background
        // The selected tab's Chrome-style shape is filled with the EXACT content
        // background, so tab and terminal read as one connected surface.
        tabBar?.contentFill = bg
        if !transparent {
            // Slightly darken the current theme background color (active session → settings value if none) for a titlebar feel.
            // A bit darker (dark theme) / a bit lighter (light theme) to distinguish it from the terminal background.
            let lum = 0.299 * bg.redComponent + 0.587 * bg.greenComponent + 0.114 * bg.blueComponent
            let shade: CGFloat = lum < 0.5 ? 0.06 : -0.06
            func adj(_ c: CGFloat) -> CGFloat { max(0, min(1, c + shade)) }
            tabBarSolid?.layer?.backgroundColor = NSColor(
                srgbRed: adj(bg.redComponent), green: adj(bg.greenComponent),
                blue: adj(bg.blueComponent), alpha: 1).cgColor
        }
    }

    /// Vertically center the traffic lights in the tab bar (38pt). The system draws them
    /// centered in the standard titlebar (~28pt), making them sit higher, so we lower the
    /// button origins to align them with the tab labels. In full screen the traffic lights
    /// are hidden, so this is skipped.
    ///
    /// Idempotent: it returns without touching a button already at its target, which is what
    /// makes it safe to drive from the buttons' own frame notifications (see
    /// `observeTrafficLights`) without looping on the change it makes itself.
    func centerTrafficLights() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        // Sweep for rebuilt buttons on every pass (identity-compare no-op when nothing
        // changed): if AppKit recreated just the zoom button, ITS observer is gone, but
        // any surviving sibling's observer landing here re-adopts the whole current set.
        // Terminates: observeTrafficLights only calls back on an identity CHANGE, and the
        // set it just adopted compares equal on reentry.
        observeTrafficLights()
        for b in Self.trafficLightTypes.compactMap({ window.standardWindowButton($0) }) {
            // Compute each target in the button's OWN superview. `setFrameOrigin` is
            // relative to that superview, so deriving one y from a sibling's container —
            // as this used to — silently misplaces any button AppKit has re-parented.
            // The zoom button is the one that happens to: it hosts the full-screen hover
            // widget, so it is rebuilt and re-homed far more than its siblings, and it
            // alone then sits at the wrong height. That is the "only the green light is
            // off" report, and it is why the target must be per-button.
            guard let container = b.superview else { continue }
            let y = container.bounds.height - (Self.tabBarHeight + b.frame.height) / 2
            guard abs(b.frame.origin.y - y) > 0.5 else { continue }
            b.setFrameOrigin(NSPoint(x: b.frame.origin.x, y: y))
        }
    }

    private static let trafficLightTypes: [NSWindow.ButtonType] =
        [.closeButton, .miniaturizeButton, .zoomButton]

    /// Re-center the traffic lights whenever AppKit moves them.
    ///
    /// AppKit owns these buttons and restores its own layout on any titlebar relayout — not
    /// just the window resize this used to hook. Becoming key, a title change (which
    /// `selectTab` does on every tab switch), moving to another screen, an appearance change
    /// and the tab-bar style toggling `styleMask` all do it. Any one of them not covered left
    /// the buttons sitting at the system position, higher than the tab labels, until something
    /// else happened to trigger a re-center.
    ///
    /// So react to the buttons MOVING rather than to a list of things that move them: the
    /// event is the same for every cause, including causes not enumerated here.
    ///
    /// And observe the buttons AppKit has NOW, not the ones it had at setup: titlebar
    /// reconfiguration (a full-screen round-trip, styleMask changes) REBUILDS the standard
    /// window buttons. Observers bound to the old instances then watch dead views while the
    /// fresh buttons sit wherever the system put them — the "one stray traffic light" bug,
    /// with the zoom button (which hosts the full-screen hover widget, so AppKit touches it
    /// most) as the usual victim. Cheap to call anywhere: it no-ops while the instance set
    /// is unchanged, and re-registers + re-centers when it isn't.
    private func observeTrafficLights() {
        guard let window else { return }
        let buttons = Self.trafficLightTypes.compactMap { window.standardWindowButton($0) }
        let ids = buttons.map(ObjectIdentifier.init)
        guard ids != observedTrafficLightIDs else { return }
        for token in trafficLightObservers { NotificationCenter.default.removeObserver(token) }
        trafficLightObservers.removeAll()
        observedTrafficLightIDs = ids
        for b in buttons {
            b.postsFrameChangedNotifications = true
            trafficLightObservers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: b, queue: .main
            ) { [weak self] _ in self?.centerTrafficLights() })
        }
        centerTrafficLights()
    }

    // MARK: - Tab management

    /// Open a tab. `configOverride` runs a tab on something other than the user's default
    /// shell — the caller has already decided argv/cwd (see `AgentLaunch`). Without it the
    /// behaviour is exactly what ⌘T has always done.
    @discardableResult
    func addNewTab(configOverride: DamsonConfig? = nil) -> DamsonSession {
        let config: DamsonConfig
        if let configOverride {
            config = configOverride
        } else {
            var c = DamsonConfig.fromUserDefaults()
            // Under the "inherit current directory" policy, start from the current active pane's cwd (keep home if none).
            if NewTabDirectory.current == .inheritCwd,
               let cwd = activeSession?.currentDirectory {
                c.cwd = cwd
            }
            config = c
        }
        let session = DamsonSession(config: config)
        addTab(tree: PaneTreeView(rootSession: session), transition: .create)
        return session
    }

    /// The working directory a newly opened pane should start in: the active pane's, as
    /// reported by shell integration (OSC 7), falling back to where it was spawned.
    var activePaneDirectory: String? {
        activeSession?.currentDirectory ?? activeSession?.currentWorkingDirectory
    }

    /// Add a tab backed by an externally-built session (e.g. a tmux `-CC` pane). Returns the
    /// tree so the caller can later close exactly this tab via `closeTab(matching:)`.
    @discardableResult
    func addExternalTab(session: DamsonSession, customTitle: String? = nil) -> PaneTreeView {
        let tree = PaneTreeView(rootSession: session)
        addTab(tree: tree, transition: .create, customTitle: customTitle)
        return tree
    }

    /// Adopt an already-built `PaneTreeView` as a new tab (e.g. a tmux window reconciled
    /// into native splits). Unlike `addExternalTab(session:)`, the tree may already hold a
    /// multi-pane split structure. Returns the tree for later `closeTab(matching:)`.
    @discardableResult
    func adoptExternalTree(_ tree: PaneTreeView, customTitle: String? = nil) -> PaneTreeView {
        addTab(tree: tree, transition: .create, customTitle: customTitle)
        return tree
    }

    /// Update the custom title of an externally-owned tab (e.g. a tmux `%window-renamed`).
    func setExternalTabTitle(matching tree: PaneTreeView, title: String?) {
        guard let idx = tabs.firstIndex(where: { $0.tree === tree }) else { return }
        tabs[idx].customTitle = title
        refreshTabBar()
    }

    /// Close the tab whose tree matches (by reference). No-op if it's already gone.
    func closeTab(matching tree: PaneTreeView) {
        if let idx = tabs.firstIndex(where: { $0.tree === tree }) {
            closeTab(idx)
        }
    }

    /// `PaneTreeHosting` — a cross-window pane drop landed in `tree`: select its tab and bring
    /// the window forward so the moved pane is visible.
    func revealTree(_ tree: PaneTreeView) {
        if let idx = tabs.firstIndex(where: { $0.tree === tree }), idx != currentIndex {
            selectTab(idx)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    /// Add an already-built PaneTreeView as a new tab (a new or restored tree).
    private func addTab(tree: PaneTreeView, transition: TabTransition = .none,
                        customTitle: String? = nil) {
        tree.translatesAutoresizingMaskIntoConstraints = false
        // Layer-backed from the start: the swipe pins a tree's offset onto its layer BEFORE
        // attaching it, and a tab that has never been shown would otherwise have no layer yet.
        tree.wantsLayer = true
        tree.host = self   // cross-window pane drop reveals this tab via PaneTreeHosting.revealTree
        // Close this tab when its last pane closes. Must be found by tree reference, not by
        // the current index into the tabs array (stays correct even if tabs are reordered).
        tree.onAllPanesClosed = { [weak self, weak tree] in
            guard let self = self, let tree = tree,
                  let idx = self.tabs.firstIndex(where: { $0.tree === tree })
            else { return }
            self.closeTab(idx)
        }
        // The tab title follows the root pane's first leaf session title. Since it shows the
        // current directory when there's no explicit OSC title, also subscribe to cwd changes
        // (OSC 7) so it refreshes on those too.
        let titleSub: AnyCancellable
        if let session = tree.root.leaves().first?.session {
            titleSub = session.$title.receive(on: RunLoop.main).sink { [weak self] _ in
                self?.refreshTabBar()
            }
            session.onCwdChanged = { [weak self] _ in
                DispatchQueue.main.async { self?.refreshTabBar() }
            }
        } else {
            titleSub = AnyCancellable {}
        }
        tabs.append(Tab(tree: tree, titleSub: titleSub, customTitle: customTitle))
        selectTab(tabs.count - 1, transition: transition)
        refreshTabBar()
    }

    func selectTab(_ index: Int, transition: TabTransition = .none) {
        guard index >= 0, index < tabs.count else { return }
        tabTransitions.abortSwipeIfNeeded()

        // Cross-slide the LIVE outgoing tree instead of a snapshot. Snapshotting was the
        // visible pre-animation hitch: cacheDisplay + one offscreen Metal re-render and
        // GPU→CPU readback per pane + CPU compositing, all synchronous on main BEFORE the
        // first animation frame. Keeping the outgoing view attached until the animation
        // completes costs nothing up front AND is pixel-faithful — the dim/border overlay
        // layers ride along live (the snapshot composited the Metal frame OVER the dim
        // scrim, so inactive panes flashed undimmed during the slide).
        var switchOutgoing: (tree: PaneTreeView, fromIndex: Int, towardRight: Bool?)?
        var reentry = TabTransitionCoordinator.SwitchReentry()
        if case .switch(let fromIndex, let towardRight) = transition,
           Motion.enabled,
           TabTransitionStyle.current != .none,
           fromIndex >= 0, fromIndex < tabs.count, fromIndex != index {
            let outgoing = tabs[fromIndex].tree
            // Only animate if that tree is actually the one on screen right now.
            if outgoing.superview === contentContainer {
                switchOutgoing = (outgoing, fromIndex, towardRight)
                // Capture current on-screen positions NOW, before the detach/reset below
                // clears the incoming tree's in-flight animation — so a reversed switch
                // continues from where the two trees currently are.
                reentry.incomingX = tabTransitions.inFlightSwitchTranslationX(tabs[index].tree.layer)
                reentry.outgoingX = tabTransitions.inFlightSwitchTranslationX(outgoing.layer)
                reentry.incomingOpacity = tabTransitions.inFlightSwitchOpacity(tabs[index].tree.layer)
                reentry.outgoingOpacity = tabTransitions.inFlightSwitchOpacity(outgoing.layer)
            }
        }

        currentIndex = index
        let tree = tabs[index].tree
        // Keep the animating outgoing tree attached; everything else detaches as before —
        // EXCEPT the incoming tree, which may already be in the container as a swipe preview.
        // Detaching it would be the whole bug: off-window, a surface loses its drawable (see
        // the repaint comment below), so re-adding it would leave the tab blank for the frame
        // or two until it paints again. Leaving it attached means the commit reveals nothing
        // — the tab has been live and painting since the gesture began.
        for t in tabs where t.tree !== switchOutgoing?.tree && t.tree !== tree {
            t.tree.removeFromSuperview()
        }
        // The pane last used in this tab. When addSubview attaches the tree to the window,
        // each surface's viewDidMoveToWindow → makeFirstResponder → onFocus fires synchronously
        // and overwrites activeLeaf (with the last pane in traversal order), so we capture the
        // intended value *up front* and restore it afterward.
        let restoreTarget = tree.activeLeaf
        if tree.superview !== contentContainer {
            contentContainer.addSubview(tree)
            NSLayoutConstraint.activate([
                tree.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                tree.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
                tree.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                tree.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            ])
        }
        // This tab is now the real one, whatever it was a moment ago.
        tree.isSwipePreview = false
        // Restore active + first responder to the last-used pane (undoing the onFocus clobber
        // above). `focusActiveLeaf` covers the already-attached case, where there was no
        // clobber to undo and so nothing has moved first responder off the outgoing tab.
        tree.setActive(restoreTarget)
        tree.focusActiveLeaf()
        // Every pane in the incoming tab must repaint its current grid — not just the
        // focused one. Output that arrived while the tab was backgrounded couldn't be
        // drawn (the surfaces were off-window, so Metal had no drawable), and only the
        // active pane gets focused above. Lay out the re-added tree first so the Metal
        // drawables are sized to the content area, then force every leaf to repaint.
        contentContainer.layoutSubtreeIfNeeded()
        tree.repaintAllLeaves()
        if index < tabs.count {
            window?.title = displayTitle(tabs[index])
        }
        refreshTabBar()

        // The incoming tree may carry a leftover from-state if a prior create/switch
        // animation on this same view was superseded. Remove any in-flight switch animation
        // and reset to the final visual state unconditionally; the branches below re-apply a
        // from-state if they animate. (Without the removeAnimation, a leftover off-screen
        // switch animation would keep this tree shifted/black when shown via the instant path.)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clearSwitchAnimations(tree.layer)
        // A swipe committed mid-settle (a chained flick) leaves the settle still playing on
        // this very tree — it is the incoming side now, not a separate snapshot layer — and it
        // would drag the tab back off-screen from under the identity transform set below.
        tree.layer?.removeAnimation(forKey: "swipeSettle")
        tree.layer?.opacity = 1
        tree.swipeTranslationX = 0
        CATransaction.commit()

        if case .create = transition, Motion.enabled {
            tabTransitions.animateTabCreate(tree)
        }

        // Run the switch animation only if the outgoing tree is still attached (decided
        // above). Otherwise this is the instant path (disabled / create / first show) —
        // identical to today.
        if let out = switchOutgoing, out.tree !== tree {
            tabTransitions.animateTabSwitch(incoming: tree, outgoing: out.tree,
                                            fromIndex: out.fromIndex, toIndex: index,
                                            towardRight: out.towardRight, reentry: reentry)
        }
    }

    /// Re-apply the active-pane indicator setting to every tab's pane tree.
    func refreshPaneIndicators() {
        for tab in tabs { tab.tree.refreshIndicators() }
    }

    // MARK: - Interactive 2-finger swipe (TabSwipeHandler)

    // The gesture lives in TabTransitionCoordinator; these two are only the protocol
    // witnesses. The conformance has to stay on the window controller because the engine
    // resolves the handler with `window?.windowController as? TabSwipeHandler`
    // (DamsonTerminalView) — so they forward instead of moving.
    func tabSwipeUpdate(translation dx: CGFloat) {
        tabTransitions.tabSwipeUpdate(translation: dx)
    }

    func tabSwipeEnd(translation dx: CGFloat, velocity: CGFloat) {
        tabTransitions.tabSwipeEnd(translation: dx, velocity: velocity)
    }

    // The swallow window lives on the coordinator with the rest of the swipe state;
    // these relays exist because the engine resolves the handler to the window
    // controller (see the conformance note above).
    var tabSwipeMomentumActive: Bool { tabTransitions.swallowingMomentum }

    func tabSwipeMomentumEnded() { tabTransitions.momentumEnded() }

    /// Put the swipe's incoming tab in the container as a LIVE tree, translated to `offset` so
    /// it starts off-screen, and hand input straight back to the tab the user is still on.
    ///
    /// Live rather than a snapshot, because a snapshot is what created the blank this used to
    /// paper over: the tab had to be attached for real at commit, and a just-attached surface
    /// has no drawable yet. A tree that has been attached since the gesture began is already
    /// painting when the commit lands, so there is no first frame to wait for.
    func attachSwipePreview(_ tree: PaneTreeView, offset: CGFloat) {
        // Offset it BEFORE it enters the hierarchy. This is what makes the swipe structurally
        // the same as ⌘←/⌘→: that path attaches the incoming tree and then slides it, and
        // position 0 is harmless there because 0 is where the tab is going. For a swipe,
        // position 0 is the neighbour covering the tab the user is still on — so the tree must
        // never be composited there at all, not even for the frame before the offset lands.
        // `swipeTranslationX` is carried by a filled animation on the layer, which exists
        // independently of the hierarchy, so it can be set while detached.
        tree.swipeTranslationX = offset
        tree.isSwipePreview = true

        // Usually detached, but not always: a keyboard/click cross-slide keeps its OUTGOING
        // tree in the container for the 0.42s animation, and a swipe started in that window
        // can pick exactly that tab as its neighbor. Adopt it rather than re-adding it —
        // re-adding means removeFromSuperview first, which costs it its drawable.
        if tree.superview !== contentContainer {
            contentContainer.addSubview(tree)
            NSLayoutConstraint.activate([
                tree.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                tree.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
                tree.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                tree.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            ])
            // Each surface's viewDidMoveToWindow grabs first responder as it enters the
            // window. Harmless when attaching a tab the user just switched to; here they have
            // not switched yet, so hand input back to the tab they are still on. Re-asserting
            // the current tab unconditionally rather than restoring a captured responder:
            // capturing left focus stranded on the preview whenever there was nothing to
            // capture, and detaching that preview later then left the window with a dead
            // first responder — keyboard input silently stopped working.
        } else {
            // Whatever motion it was under belongs to the switch it is being pulled out of.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            clearSwitchAnimations(tree.layer)
            tree.layer?.opacity = 1
            CATransaction.commit()
        }
        // Size the Metal drawables to the content area before asking for pixels, exactly as
        // the real attach in `selectTab` does.
        refocusCurrentTab()
        contentContainer.layoutSubtreeIfNeeded()
        tree.repaintAllLeaves()
    }

    /// Put keyboard focus back on the tab the user is actually on.
    ///
    /// The swipe puts a second live tree in the window, and both attaching and detaching it
    /// can move first responder off the current tab — attaching because entering the window
    /// makes a surface grab it, detaching because the holder disappears.
    private func refocusCurrentTab() {
        guard tabs.indices.contains(currentIndex) else { return }
        tabs[currentIndex].tree.focusActiveLeaf()
    }

    /// Take a swipe preview back out — the gesture was cancelled, or something else took over.
    /// Only ever called for a tree that did NOT become current; the committed one stays.
    func detachSwipePreview(_ tree: PaneTreeView) {
        guard tree.isSwipePreview else { return }
        tree.isSwipePreview = false
        tree.removeFromSuperview()
        // Removing a view that holds first responder leaves the window without one, and
        // nothing puts it back — every keystroke goes nowhere from then on.
        refocusCurrentTab()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tree.layer?.removeAnimation(forKey: "swipeSettle")
        tree.swipeTranslationX = 0
        CATransaction.commit()
    }

    /// Move a tab from one position to another (drag-to-reorder).
    func reorderTab(from: Int, to: Int) {
        guard from != to, from >= 0, from < tabs.count, to >= 0, to < tabs.count else {
            refreshTabBar()
            return
        }
        let moved = tabs.remove(at: from)
        tabs.insert(moved, at: to)
        // Keep currentIndex pointing at the same tab after the shuffle.
        if currentIndex == from {
            currentIndex = to
        } else if from < currentIndex && to >= currentIndex {
            currentIndex -= 1
        } else if from > currentIndex && to <= currentIndex {
            currentIndex += 1
        }
        refreshTabBar()
    }

    func closeTab(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }

        // Animate only when the tab being closed is the "currently visible" one, tabs remain
        // after closing, animation is enabled, and a snapshot can be captured. Everything else
        // (closing a background tab / the last tab / snapshot failure / Reduce Motion / toggle
        // off) keeps the existing instant path.
        //
        // The tabs.count > 1 guard is checked *before* remove(at:) — i.e. it guarantees a next
        // tab exists. If tabs.isEmpty after remove(at:), that path ends here (window close, no
        // overlay to clean up). Otherwise overlay cleanup + next-tab selection follow.
        //
        // The overlay is laid pixel-for-pixel over the still-alive closing tree before teardown,
        // so that even when selectTab instantly swaps in the next tree the overlay covers it without a flicker.
        var overlay: CALayer?
        if Motion.enabled,
           index == currentIndex,
           tabs.count > 1,
           let image = Motion.snapshot(of: tabs[index].tree) {
            overlay = Motion.overlay(
                image: image,
                frame: contentContainer.bounds,
                in: contentContainer
            )
        }

        let closingTree = tabs[index].tree
        closingTree.terminateAllForClose()   // honors a pane dragged out to another window
        // Detach the closed tree from the container. Without this it lingers as a live
        // subview BEHIND the current tab: selectTab's detach loop only iterates the
        // surviving `tabs`, and this tree is already gone from that array, so it's never
        // removed. A trackpad swipe that slides the current tab aside (especially a
        // chained double-swipe) then reveals the previously-closed tab underneath.
        // The close-animation overlay is an independent snapshot layer, so removing the
        // real view here doesn't affect the fade-out.
        closingTree.removeFromSuperview()
        tabs.remove(at: index)

        if tabs.isEmpty {
            // The last tab was closed — close the window (out of scope here). Thanks to the
            // guard above (tabs.count > 1), no overlay is ever created here, so there's nothing to clean up.
            window?.performClose(nil)
            return
        }
        if index < currentIndex {
            // A tab BEFORE the current one went away, so everything after it — including the
            // tab being looked at — slid down a slot. Follow it, or `currentIndex` keeps its
            // number while naming the neighbor to the right: closing a background tab would
            // silently switch tabs on the user, and every later ⌘←/⌘→ would count from there.
            // Reachable without touching the tab bar, since a background tab whose last shell
            // exits closes itself through here.
            currentIndex -= 1
        } else if currentIndex >= tabs.count {
            // The active tab was the last one — fall back to the new last tab.
            currentIndex = tabs.count - 1
        }
        // Closing the ACTIVE tab leaves currentIndex alone on purpose: the tab that shifted
        // into that slot is the next one to the right, which is what should be shown.
        // Show the next tab live, instantly (.none). The overlay slides/fades on top of it.
        selectTab(currentIndex)

        guard let overlay else { return }
        // Closing-content snapshot: slides down (~6% of height) while fading out → removed.
        // In the non-flipped coordinate system, "down" is -y. Since it's a detached CALayer
        // (no view .animator()), it uses the same explicit CABasicAnimation idiom as bell-flash.
        let dy = overlay.bounds.height * 0.06
        let fromPos = overlay.position
        let toPos = CGPoint(x: fromPos.x, y: fromPos.y - dy)

        let slide = CABasicAnimation(keyPath: "position")
        slide.fromValue = NSValue(point: fromPos)
        slide.toValue = NSValue(point: toPos)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0

        let group = CAAnimationGroup()
        group.animations = [slide, fade]
        group.duration = Motion.duration
        group.timingFunction = Motion.timing
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards

        // We don't write the model values separately. fillMode = .forwards pins the
        // slid/faded final state from completion until removal, so no model update is needed.
        // (On a vanilla CALayer with no delegate, a bare model assignment triggers Core
        // Animation's default implicit animation — like the handleBell idiom, we don't touch the model before/after add.)
        overlay.add(group, forKey: "tabClose")

        // Remove the overlay after the animation. Each close captures only its own overlay
        // (not self), so rapid successive closes are safe with no shared state.
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.duration) {
            overlay.removeFromSuperlayer()
        }
    }

    func closeCurrentTab() {
        closeTab(currentIndex)
    }

    /// Received when DamsonSurfaceView sends Cmd+W up the responder chain. Closes the active
    /// tab's active pane (if it's the last pane in the tree, PaneTreeView cascades through
    /// onAllPanesClosed to close the tab/window).
    @objc func performCloseTab(_ sender: Any?) {
        guard currentIndex < tabs.count else { return }
        tabs[currentIndex].tree.closeActive()
    }

    /// Cmd+D — horizontal split (left/right).
    @objc func splitPaneHorizontally(_ sender: Any?) {
        guard currentIndex < tabs.count else { return }
        tabs[currentIndex].tree.split(direction: .horizontal)
    }

    /// Cmd+Shift+D — vertical split (top/bottom).
    @objc func splitPaneVertically(_ sender: Any?) {
        guard currentIndex < tabs.count else { return }
        tabs[currentIndex].tree.split(direction: .vertical)
    }

    /// For damson-cli IPC — takes the direction directly and splits the active tab's active pane.
    func splitActive(direction: SplitDirection) {
        guard currentIndex < tabs.count else { return }
        tabs[currentIndex].tree.split(direction: direction)
    }

    /// Split the active pane onto a caller-supplied config (see `AgentLaunch`). Deliberately
    /// separate from `splitActive` rather than a defaulted parameter on it: that one is a
    /// `PaneCommandTarget` requirement implemented by two controllers, and widening a
    /// protocol for one caller's convenience is how the seam starts to rot.
    func splitActivePane(direction: SplitDirection, configOverride: DamsonConfig) {
        guard currentIndex < tabs.count else { return }
        tabs[currentIndex].tree.split(direction: direction, configOverride: configOverride)
    }

    /// Apply a one-shot preset pane layout to the active tab.
    @objc func applyPaneLayout(_ sender: NSMenuItem) {
        guard currentIndex < tabs.count,
              let template = sender.representedObject as? PaneLayoutTemplate else { return }
        tabs[currentIndex].tree.applyLayout(template)
    }

    /// For damson-cli IPC — apply a preset layout to the active tab.
    func applyLayout(_ template: PaneLayoutTemplate) {
        guard currentIndex < tabs.count else { return }
        tabs[currentIndex].tree.applyLayout(template)
    }

    /// damson-cli `focus-pane` — move focus in the active tab's pane tree.
    func focusActivePane(_ dir: PaneFocusDirection) {
        guard currentIndex < tabs.count else { return }
        tabs[currentIndex].tree.moveFocus(dir)
    }

    /// damson-cli `close-pane` — close the active tab's active pane (cascades to tab/window when last).
    func closeActivePane() {
        guard currentIndex < tabs.count else { return }
        tabs[currentIndex].tree.closeActive()
    }

    /// damson-cli `resize-pane` — nudge the divider governing the active pane by `cells`
    /// in `dir`. Returns false when there's no split on that axis.
    @discardableResult
    func resizeActivePane(_ dir: PaneFocusDirection, cells: Int) -> Bool {
        guard currentIndex < tabs.count, let win = window else { return false }
        return tabs[currentIndex].tree.resizeActiveDivider(
            dir, fraction: WindowResize.dividerFraction(dir, cells: cells,
                                                         session: activeSession, window: win))
    }

    /// damson-cli `list-panes` — panes of the active tab in traversal order.
    func paneList() -> [PaneInfo] {
        guard currentIndex < tabs.count else { return [] }
        return tabs[currentIndex].tree.paneSessionsInOrder().enumerated().map { (i, pair) in
            PaneInfo(index: i, cols: pair.session.grid.cols,
                     rows: pair.session.grid.rows, active: pair.active)
        }
    }

    /// damson-cli `resize-window` — size the window so the active terminal is `cols`×`rows`.
    @discardableResult
    func resizeWindowToGrid(cols: Int, rows: Int) -> Bool {
        guard let win = window, let session = activeSession else { return false }
        return WindowResize.resize(window: win, to: (cols, rows), basedOn: session)
    }

    /// Number of panes (leaves) in each tab — for the list-tabs IPC response.
    var tabPaneCounts: [Int] {
        tabs.map { $0.tree.root.leaves().count }
    }

    // MARK: - Tab keyboard navigation

    /// Cmd+Shift+] / Ctrl+Tab / ⌘→ — next tab (wrap). Always slides leftward, wrap
    /// included: "next" is one direction to the user no matter what it does to the index.
    @objc func selectNextTab(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        let from = currentIndex
        selectTab((currentIndex + 1) % tabs.count,
                  transition: .switch(fromIndex: from, towardRight: true))
    }

    /// Cmd+Shift+[ / Ctrl+Shift+Tab / ⌘← — previous tab (wrap). Mirror of the above.
    @objc func selectPreviousTab(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        let from = currentIndex
        selectTab((currentIndex - 1 + tabs.count) % tabs.count,
                  transition: .switch(fromIndex: from, towardRight: false))
    }

    /// Cmd+1..9 — the nth tab (9 is the last tab). NSMenuItem.tag holds the 1-based number.
    @objc func selectTabByNumber(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let n = item.tag
        let idx = (n == 9) ? tabs.count - 1 : n - 1
        if idx >= 0 && idx < tabs.count {
            selectTab(idx, transition: .switch(fromIndex: currentIndex, towardRight: nil))
        }
    }

    // MARK: - Pane focus keyboard navigation

    /// Cmd+Opt+arrow — move focus to an adjacent pane.
    @objc func focusPaneLeft(_ sender: Any?) { moveFocus(.left) }
    @objc func focusPaneRight(_ sender: Any?) { moveFocus(.right) }
    @objc func focusPaneUp(_ sender: Any?) { moveFocus(.up) }
    @objc func focusPaneDown(_ sender: Any?) { moveFocus(.down) }

    private func moveFocus(_ dir: PaneFocusDirection) {
        guard currentIndex < tabs.count else { return }
        tabs[currentIndex].tree.moveFocus(dir)
    }

    /// Cmd+Shift+arrow — swap positions with an adjacent pane.
    @objc func swapPaneLeft(_ sender: Any?) { swapDirectional(.left) }
    @objc func swapPaneRight(_ sender: Any?) { swapDirectional(.right) }
    @objc func swapPaneUp(_ sender: Any?) { swapDirectional(.up) }
    @objc func swapPaneDown(_ sender: Any?) { swapDirectional(.down) }

    private func swapDirectional(_ dir: PaneFocusDirection) {
        guard currentIndex < tabs.count else { return }
        tabs[currentIndex].tree.swapDirectional(dir)
    }

    private func refreshTabBar() {
        let titles = tabs.map { displayTitle($0) }
        tabBar.update(titles: titles, selectedIndex: currentIndex)
        // The traffic lights share this row, and a title change is one of the things that
        // makes AppKit relayout the titlebar — so this is both the moment a light can be
        // knocked out of place and the cheapest moment to notice. `windowDidUpdate` alone
        // recovers it eventually, but "eventually" measured ~24s in a soak; a pane running
        // a spinner-animating TUI calls this several times a second, which makes the
        // correction immediate in exactly the situation that produces the bug.
        centerTrafficLights()
    }

    /// Title to show on the tab: user-assigned title > session (OSC/process) title > current directory > "Damson".
    /// An agent status suffix, when present, rides on top of whichever of those won.
    private func displayTitle(_ tab: Tab) -> String {
        let base = baseTitle(tab)
        guard let suffix = tab.agentSuffix, !suffix.isEmpty else { return base }
        return "\(base) \(suffix)"
    }

    private func baseTitle(_ tab: Tab) -> String {
        if let custom = tab.customTitle, !custom.isEmpty { return custom }
        guard let session = tab.tree.root.leaves().first?.session else { return "Damson" }
        if !session.title.isEmpty { return session.title }
        // If there's no cwd tracked via OSC 7, fall back to the actual process cwd (proc_pidinfo).
        if let dir = session.currentDirectory ?? session.currentWorkingDirectory {
            return Self.prettyDir(dir)
        }
        return "Damson"
    }

    /// Refresh every pane's agent badge in this window and mirror the first pane's state
    /// into each tab's title. Called from `CrewController`'s sweep — never from a hot path.
    /// The tab bar is only rebuilt when a suffix actually changed.
    func refreshAgentBadges(_ badge: (DamsonSession) -> AgentBadge?) {
        var changed = false
        for i in tabs.indices {
            let leadBadge = tabs[i].tree.refreshAgentBadges(badge)
            // Only `waiting` reaches the tab title. A tab bar that relabels every few
            // seconds as agents flip busy↔idle is noise; the one state a user must not
            // miss while looking at another tab is "this agent is blocked on you".
            let suffix = leadBadge?.isAttention == true ? leadBadge?.label : nil
            if tabs[i].agentSuffix != suffix {
                tabs[i].agentSuffix = suffix
                changed = true
            }
        }
        if changed {
            refreshTabBar()
            if currentIndex >= 0, currentIndex < tabs.count {
                window?.title = displayTitle(tabs[currentIndex])
            }
        }
    }

    /// Make a path tab-friendly — home becomes "~", otherwise the last path component (folder name).
    static func prettyDir(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        let base = (path as NSString).lastPathComponent
        return base.isEmpty ? path : base
    }

    /// Tab double-click → inline edit result. An empty string clears the user title and reverts to the automatic title.
    private func renameTab(_ index: Int, to title: String) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].customTitle = title.isEmpty ? nil : title
        refreshTabBar()
        // Return the focus lost when editing ended back to the active pane.
        if currentIndex < tabs.count,
           case .leaf(_, let surface) = tabs[currentIndex].tree.activeLeaf.kind {
            window?.makeFirstResponder(surface)
        }
    }

    // MARK: - NSWindowDelegate

    /// Invoked at the very start of `windowWillClose`, BEFORE the per-tab terminate sweep.
    /// A tmux-backed host uses this to send `detach-client` first, so the kill-panes the
    /// sweep would otherwise fire at live panes are suppressed (closing the window means
    /// detach — leave the tmux session intact — never kill).
    var onWindowWillClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onWindowWillClose?()
        for t in tabs { t.tree.terminateAllForClose() }   // honor panes dragged out to other windows
    }

    // On full-screen enter/exit: update the leading reservation (traffic lights) + top inset (menu bar).
    func windowDidEnterFullScreen(_ notification: Notification) {
        updateFullScreenInset()
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        updateFullScreenInset()
        // The exit rebuilds the titlebar buttons — re-OBSERVE (which re-centers), not
        // just re-center: observers on the pre-full-screen instances are dead now.
        DispatchQueue.main.async { [weak self] in self?.observeTrafficLights() }
    }
    // The system resets the traffic-light positions on resize, so re-center them —
    // and re-observe first, in case this resize came with a titlebar rebuild.
    func windowDidResize(_ notification: Notification) {
        observeTrafficLights()
        centerTrafficLights()
    }

    /// Last line of defence for the traffic lights.
    ///
    /// Everything else here reacts to a button MOVING, which cannot see the case that
    /// actually strands one: AppKit rebuilds a button, the replacement has no observer,
    /// and no sibling ever moves again — so nothing re-adopts it and it simply stays at
    /// the system position. That is why the stray light shows up after hours rather than
    /// at a moment you can point to: it needs a titlebar relayout to coincide with a
    /// rebuild, and a pane running a spinner-animating TUI drives thousands of them
    /// (every OSC title change refreshes the tab bar).
    ///
    /// `windowDidUpdate` is AppKit's own once-per-event-cycle hook and does not depend on
    /// our bookkeeping being intact. The work is three `standardWindowButton` lookups and
    /// three float compares that early-out when nothing moved — cheap enough to run
    /// unconditionally, and it never touches the PTY or render path.
    func windowDidUpdate(_ notification: Notification) {
        centerTrafficLights()
    }
}
