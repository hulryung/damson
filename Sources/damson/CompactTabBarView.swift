import AppKit
import DamsonTerminal  // Motion (shared animation timing)

/// Custom tab bar for compact mode only. Disables NSWindow's native tabs
/// (tabbingMode = .disallowed) and places this at the very top of contentView → tabs
/// appear in the same row as the traffic lights.
///
/// Layout:
///   [80pt reserved (traffic-light area)][tab 1][tab 2]...[tab N][+ new tab][margin]
///
/// Reorder: the bar lives in the window's titlebar region, where the window
/// server normally eats horizontal drags as a window-move before they reach a
/// subview's mouseDragged. Reordering is gated behind Cmd+Shift: holding it
/// "pops out" the tabs and pins the window immovable (isMovable=false), which
/// lets the drag flow through TabButton's responder chain. A local event
/// monitor only watches the chord; the slide animations ride AppKit's normal
/// display cycle.
final class CompactTabBarView: NSView {
    var onTabSelected: ((Int) -> Void)?
    var onTabClosed: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    /// Reorder result after a drag: move the tab from `from` to `to`.
    var onTabReordered: ((Int, Int) -> Void)?
    /// Double-click rename result: set tab `index`'s title to `title` ("" = revert to auto).
    var onTabRenamed: ((Int, String) -> Void)?

    private var tabButtons: [TabButton] = []
    private let newTabButton = NSButton()
    private var selectedIndex: Int = 0

    /// The selection highlight, detached from the buttons so it can SLIDE between tabs on a
    /// switch (the buttons are recreated on every update, which can only ever snap). Lives
    /// at the bottom of the bar's layer stack; buttons render on top of it.
    private let selectionPill = CALayer()
    /// The tab index the pill currently sits on (-1 = not placed yet → first placement snaps).
    private var pillDisplayedIndex: Int = -1

    // Drag-reorder state.
    private var perTab: CGFloat = 100   // current per-tab width (updated in layout)
    private var dragTargetIndex: Int?
    // Reorder mode (Cmd+Shift held). A local event monitor owns the drag so the
    // events never reach the window's titlebar drag machinery.
    private var reorderModeActive = false
    private var draggingIndex: Int?
    private var lastGapTarget: Int?   // insertion slot currently shown, to animate only on change
    private var eventMonitor: Any?
    // The window server handles titlebar drag-to-move from the draggable region,
    // before our monitor sees leftMouseDragged. Pinning isMovable=false for the
    // duration of the chord stops that so the drag events reach us. We capture
    // the prior value and always restore it (release, window change, teardown).
    private var savedIsMovable: Bool?

    // Space for the traffic lights (close/minimize/zoom buttons). In full screen the traffic
    // lights are hidden, so drop the reservation and let tabs start from the left edge
    // (removes the awkward empty gap).
    private var leadingReservation: CGFloat {
        (window?.styleMask.contains(.fullScreen) ?? false) ? 12 : 80
    }
    private let trailingReservation: CGFloat = 12
    private let tabSpacing: CGFloat = 2
    private let maxTabWidth: CGFloat = 200
    private let minTabWidth: CGFloat = 80
    private let tabHeight: CGFloat = 24

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Transparent — so the NSVisualEffectView behind it shows through.
        layer?.backgroundColor = NSColor.clear.cgColor

        // Selection pill UNDER the buttons (insert at 0; subview layers append above).
        selectionPill.cornerRadius = 5
        selectionPill.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        selectionPill.isHidden = true
        layer?.insertSublayer(selectionPill, at: 0)

        newTabButton.title = "+"
        newTabButton.bezelStyle = .inline
        newTabButton.isBordered = false
        newTabButton.font = NSFont.systemFont(ofSize: 16, weight: .light)
        newTabButton.contentTintColor = .secondaryLabelColor
        newTabButton.target = self
        newTabButton.action = #selector(newTabClicked)
        addSubview(newTabButton)

        // Right-side badge — git hash (orange) for dev builds, build time (muted color) for release builds.
        if let badge = BuildInfo.badgeText {
            let l = NSTextField(labelWithString: badge)
            l.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            l.textColor = BuildInfo.isDevBuild ? .systemOrange : .tertiaryLabelColor
            l.alignment = .right
            addSubview(l)
            devLabel = l
        }
    }

    private var devLabel: NSTextField?

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(titles: [String], selectedIndex: Int) {
        self.selectedIndex = selectedIndex
        // Remove the existing buttons and recreate them. Fine since the tab count doesn't change often.
        tabButtons.forEach { $0.removeFromSuperview() }
        tabButtons.removeAll()
        for (i, title) in titles.enumerated() {
            let btn = TabButton(title: title.isEmpty ? "Damson" : title,
                                isSelected: i == selectedIndex)
            btn.onClick = { [weak self] in self?.onTabSelected?(i) }
            btn.onClose = { [weak self] in self?.onTabClosed?(i) }
            btn.onRename = { [weak self] title in self?.onTabRenamed?(i, title) }
            btn.isReorderActive = { [weak self] in self?.reorderModeActive ?? false }
            btn.onDragBegan = { [weak self] in self?.beginDrag(i) }
            btn.onDragMoved = { [weak self] dx in self?.updateDrag(dx) }
            btn.onDragEnded = { [weak self] in self?.finishDrag() }
            if reorderModeActive { btn.setReorderMode(true) }
            addSubview(btn)
            tabButtons.append(btn)
        }
        needsLayout = true
    }

    // MARK: - Reorder mode (Cmd+Shift)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { installMonitor() } else { removeMonitor() }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // Restore the outgoing window's movability while we still hold its
        // reference; viewDidMoveToWindow runs after `window` is already nil.
        restoreWindowMovable()
    }

    deinit { removeMonitor() }

    /// Enter/leave reorder mode: pop the tabs out and pin window movability so
    /// the server doesn't eat the drag.
    private func setReorderMode(active: Bool) {
        guard active != reorderModeActive else { return }
        reorderModeActive = active
        tabButtons.forEach { $0.setReorderMode(active) }
        // The pill doesn't track the chip drag — hide it for the mode, re-place on exit.
        positionSelectionPill()
        if active {
            if savedIsMovable == nil { savedIsMovable = window?.isMovable }
            window?.isMovable = false
        } else {
            if draggingIndex != nil { finishDrag() }
            restoreWindowMovable()
        }
    }

    private func restoreWindowMovable() {
        if let saved = savedIsMovable {
            window?.isMovable = saved
            savedIsMovable = nil
        }
    }

    private func installMonitor() {
        guard eventMonitor == nil else { return }
        // Only the Cmd+Shift chord is watched here. The drag runs through
        // TabButton's responder chain so AppKit's normal display cycle drives
        // the slide animations (no manual flush, no judder).
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged]
        ) { [weak self] event in
            self?.handleMonitorEvent(event) ?? event
        }
    }

    private func removeMonitor() {
        setReorderMode(active: false)
        restoreWindowMovable()
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
    }

    /// Toggle reorder mode on the Cmd+Shift chord. We never consume the event —
    /// the drag is handled by TabButton, and pinning `isMovable=false` (in
    /// setReorderMode) is what stops the window server from eating the drag.
    private func handleMonitorEvent(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, event.type == .flagsChanged else {
            return event
        }
        let active = event.modifierFlags.contains([.command, .shift])
        if active != reorderModeActive {
            setReorderMode(active: active)
        }
        return event
    }

    // MARK: - Titlebar double-click

    /// Double-clicking an empty (non-tab) area (beside the traffic lights / between tabs /
    /// the right margin) zooms the window. Since this view covers the titlebar area of a
    /// `.fullSizeContentView` window, the system's default double-click doesn't reach it, so
    /// we handle it directly. It always zooms, regardless of the system preference ("Double-click
    /// a window's title bar to…").
    /// Tab buttons / close / + buttons are separate subviews, so hitTest routes to them and they never reach here.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, !reorderModeActive {
            window?.performZoom(nil)
            return
        }
        super.mouseDown(with: event)
    }

    private func tabBaseX(_ i: Int) -> CGFloat {
        leadingReservation + CGFloat(i) * (perTab + tabSpacing)
    }

    /// Move a tab to a new x. View-backed layers have implicit animation
    /// disabled, so `animator().frame` is unreliable here; we set the model
    /// frame and add an explicit position animation from the current
    /// presentation point (smooth even if a prior slide was mid-flight).
    private func moveTab(_ view: NSView, toX x: CGFloat, animated: Bool) {
        let tabY = (bounds.height - tabHeight) / 2
        let newFrame = NSRect(x: x, y: tabY, width: perTab, height: tabHeight)
        guard animated, let layer = view.layer else {
            view.frame = newFrame
            return
        }
        let from = layer.presentation()?.position ?? layer.position
        view.frame = newFrame
        let anim = CABasicAnimation(keyPath: "position")
        anim.fromValue = NSValue(point: NSPoint(x: from.x, y: from.y))
        anim.toValue = NSValue(point: NSPoint(x: layer.position.x, y: layer.position.y))
        anim.duration = 0.16
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(anim, forKey: "reorderSlide")
    }

    private func beginDrag(_ idx: Int) {
        guard idx < tabButtons.count else { return }
        draggingIndex = idx
        dragTargetIndex = idx
        lastGapTarget = idx
        let btn = tabButtons[idx]
        btn.layer?.zPosition = 10   // float above its neighbors
        btn.setGrabbed(true)
    }

    /// `dx` is the cursor offset from where this tab was grabbed, supplied by
    /// TabButton's responder-chain drag. The grabbed tab tracks the cursor; the
    /// neighbors glide to open a gap at the insertion slot.
    private func updateDrag(_ dx: CGFloat) {
        guard let idx = draggingIndex, idx < tabButtons.count else { return }
        let btn = tabButtons[idx]
        // The grabbed tab follows the cursor 1:1 (no animation on this one).
        btn.frame.origin.x = tabBaseX(idx) + dx
        // Insertion slot from displacement. Rounding gives a half-slot
        // hysteresis (no start jitter); the small same-direction bias commits
        // the swap a bit earlier (~⅓ slot) so wide tabs don't feel sluggish.
        let slotW = perTab + tabSpacing
        let step = (dx / slotW + CGFloat(copysign(0.15, Double(dx)))).rounded()
        let target = max(0, min(tabButtons.count - 1, idx + Int(step)))
        dragTargetIndex = target
        // Re-open the gap (animated) only when the insertion slot changes, so
        // neighbors glide once per crossing instead of restarting per pixel.
        guard target != lastGapTarget else { return }
        lastGapTarget = target
        var slot = 0
        for (i, other) in tabButtons.enumerated() where i != idx {
            if slot == target { slot += 1 }  // leave room for the dragged tab
            moveTab(other, toX: tabBaseX(slot), animated: true)
            slot += 1
        }
    }

    private func finishDrag() {
        guard let idx = draggingIndex else { return }
        draggingIndex = nil
        lastGapTarget = nil
        let target = dragTargetIndex ?? idx
        dragTargetIndex = nil
        guard idx < tabButtons.count else { return }
        let btn = tabButtons[idx]
        btn.setGrabbed(false)
        btn.layer?.zPosition = 0
        // Neighbors already sit in their final slots; glide the dropped tab into
        // its slot, then commit the model once the settle finishes so the
        // rebuild lands on positions that already match (no snap).
        guard target != idx else {
            moveTab(btn, toX: tabBaseX(idx), animated: true)   // snap back home
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.onTabReordered?(idx, target)
        }
        moveTab(btn, toX: tabBaseX(target), animated: true)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let btnSize: CGFloat = 24
        // dev label — at the far right. newTabButton sits to its left.
        var rightEdge = bounds.width - trailingReservation
        if let dev = devLabel {
            dev.sizeToFit()
            let w = dev.frame.width
            dev.frame = NSRect(x: rightEdge - w, y: (bounds.height - dev.frame.height) / 2,
                               width: w, height: dev.frame.height)
            rightEdge -= w + 8
        }
        newTabButton.frame = NSRect(
            x: max(leadingReservation, rightEdge - btnSize),
            y: (bounds.height - btnSize) / 2,
            width: btnSize, height: btnSize
        )

        guard !tabButtons.isEmpty else { return }
        let count = CGFloat(tabButtons.count)
        let available = bounds.width - leadingReservation - trailingReservation - btnSize - 4
            - tabSpacing * (count - 1)
        perTab = max(minTabWidth, min(maxTabWidth, available / count))
        let tabY = (bounds.height - tabHeight) / 2

        for (i, btn) in tabButtons.enumerated() {
            btn.frame = NSRect(
                x: leadingReservation + CGFloat(i) * (perTab + tabSpacing),
                y: tabY,
                width: perTab,
                height: tabHeight
            )
        }
        // Pin the new-tab button just to the right of the last tab.
        if let last = tabButtons.last {
            let nx = last.frame.maxX + 6
            if nx + btnSize + trailingReservation <= bounds.width {
                newTabButton.frame.origin.x = nx
            }
        }
        positionSelectionPill()
    }

    /// Place the selection pill on the selected tab. A selection CHANGE slides it there
    /// (same 0.16s/easeOut as the content cross-slide, so the bar and the content move as
    /// one gesture); anything else — title refresh, window resize, tab add/remove — snaps,
    /// so the pill simply tracks layout. Hidden while reorder mode rearranges the buttons.
    private func positionSelectionPill() {
        guard !reorderModeActive, selectedIndex >= 0, selectedIndex < tabButtons.count else {
            selectionPill.isHidden = true
            if reorderModeActive { pillDisplayedIndex = -1 }  // re-place (snap) after reorder
            return
        }
        let target = tabButtons[selectedIndex].frame
        let isSwitch = pillDisplayedIndex != -1 && pillDisplayedIndex != selectedIndex
        pillDisplayedIndex = selectedIndex

        CATransaction.begin()
        if isSwitch && Motion.enabled {
            CATransaction.setAnimationDuration(Motion.duration)
            CATransaction.setAnimationTimingFunction(Motion.timing)
        } else {
            CATransaction.setDisableActions(true)
        }
        selectionPill.isHidden = false
        selectionPill.frame = target
        CATransaction.commit()
    }

    @objc private func newTabClicked() {
        onNewTab?()
    }
}

/// One tab: title + trailing close X. Click selects, the X closes. In reorder
/// mode (Cmd+Shift) a horizontal drag is reported to the bar; the window is
/// pinned immovable then, so these drag events actually reach us.
private final class TabButton: NSView {
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    /// Committed inline rename (Return or focus loss). "" reverts to the auto title.
    var onRename: ((String) -> Void)?
    /// Returns whether the bar is in Cmd+Shift reorder mode right now.
    var isReorderActive: (() -> Bool)?
    /// Drag-to-reorder callbacks. `dx` is the cursor's horizontal offset from
    /// the grab point, in window coordinates.
    var onDragBegan: (() -> Void)?
    var onDragMoved: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?

    private var dragStartX: CGFloat?
    private var didDrag = false

    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var isSelected: Bool

    init(title: String, isSelected: Bool) {
        self.isSelected = isSelected
        super.init(frame: .zero)
        wantsLayer = true
        updateBackground()

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 11)
        titleLabel.textColor = isSelected ? .labelColor : .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        closeButton.title = "✕"
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.font = NSFont.systemFont(ofSize: 9)
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),
        ])

        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self, userInfo: nil
        )
        addTrackingArea(tracking)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Route all events to self except the close button, otherwise the title
    // label (an NSTextField) swallows mouseDown and clicks miss the tab.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !closeButton.isHidden, closeButton.frame.contains(local) {
            return closeButton
        }
        return bounds.contains(local) ? self : nil
    }

    private func updateBackground() {
        layer?.cornerRadius = 5
        // The selection highlight is the bar's sliding pill (rendered beneath the buttons),
        // so the button itself stays clear in normal mode — a per-button background could
        // only ever snap, since buttons are recreated on every update.
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    /// Pop-out styling while Cmd+Shift reorder mode is active: accent border +
    /// a subtle lift so it reads as a draggable chip.
    func setReorderMode(_ on: Bool) {
        if on {
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.backgroundColor = NSColor.white
                .withAlphaComponent(isSelected ? 0.18 : 0.10).cgColor
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.25
            layer?.shadowRadius = 3
            layer?.shadowOffset = CGSize(width: 0, height: -1)
        } else {
            layer?.borderWidth = 0
            layer?.shadowOpacity = 0
            updateBackground()
        }
    }

    /// Stronger "lifted" styling while this tab is being dragged: deeper shadow
    /// and a brighter fill so it clearly reads as picked up. Releasing returns
    /// to the (still active) reorder-mode look.
    func setGrabbed(_ on: Bool) {
        if on {
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.24).cgColor
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.5
            layer?.shadowRadius = 7
            layer?.shadowOffset = CGSize(width: 0, height: -2)
        } else {
            setReorderMode(true)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Claim the sequence; the click is acted on in mouseUp, a drag (in
        // reorder mode) in mouseDragged.
        dragStartX = event.locationInWindow.x
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startX = dragStartX, isReorderActive?() == true else { return }
        let dx = event.locationInWindow.x - startX
        if !didDrag, abs(dx) > 4 {
            didDrag = true
            onDragBegan?()
        }
        if didDrag { onDragMoved?(dx) }
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            onDragEnded?()
        } else if event.clickCount >= 2, isReorderActive?() != true {
            // Double-click → inline title editing. (Single click is selection.)
            beginEditing()
        } else {
            onClick?()
        }
        dragStartX = nil
        didDrag = false
    }

    @objc private func closeClicked() {
        onClose?()
    }

    // MARK: - Inline rename

    private var editField: NSTextField?

    private func beginEditing() {
        guard editField == nil else { return }
        let f = NSTextField(string: titleLabel.stringValue)
        f.font = titleLabel.font
        f.isBezeled = false
        f.drawsBackground = true
        f.backgroundColor = .textBackgroundColor
        f.textColor = .labelColor
        f.focusRingType = .none
        f.usesSingleLineMode = true
        f.lineBreakMode = .byTruncatingTail
        f.delegate = self
        f.translatesAutoresizingMaskIntoConstraints = false
        addSubview(f)
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            f.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            f.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        editField = f
        titleLabel.isHidden = true
        window?.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
    }

    /// End editing — remove the field and restore the label. editField is set to nil first to prevent re-entry (controlTextDidEndEditing).
    private func endEditing() -> String? {
        guard let f = editField else { return nil }
        editField = nil
        let text = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        f.removeFromSuperview()
        titleLabel.isHidden = false
        return text
    }
}

extension TabButton: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            if let text = endEditing() { onRename?(text) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            _ = endEditing()   // Esc — discard changes
            return true
        default:
            return false
        }
    }

    // If editing ends via focus loss (clicking elsewhere), commit the current value.
    func controlTextDidEndEditing(_ obj: Notification) {
        if let text = endEditing() { onRename?(text) }
    }
}
