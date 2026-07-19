import AppKit
import DamsonTerminal

/// Pane focus move direction (Cmd+Opt+arrow).
enum PaneFocusDirection {
    case left, right, up, down
}

/// Which edge of a hovered pane a dragged pane will dock to (Control+Command pane drag).
/// `left`/`right` build a horizontal split, `top`/`bottom` a vertical one; `center` means
/// "swap places" (no new split). Kept module-internal so the cross-window step can
/// reuse the same drop semantics.
enum PaneDropEdge {
    case left, right, top, bottom, center
}

/// The host (window controller) of a `PaneTreeView`, used by the cross-window pane drag to
/// reveal the destination tree after a drop: order its window forward and, in compact mode,
/// switch to the tab that holds the tree. Both `DamsonWindowController` (one tree per window)
/// and `CompactWindowController` (N tabbed trees per window) conform with a minimal method.
protocol PaneTreeHosting: AnyObject {
    /// Bring `tree` to the front: select its tab (if tabbed) and order its window forward.
    func revealTree(_ tree: PaneTreeView)
}

/// NSView that lays out the PaneNode tree on screen. Divider drag adjusts the ratio,
/// clicking a leaf selects the active pane. Cmd+D / Cmd+Shift+D split, Cmd+W closes the active pane.
final class PaneTreeView: NSView {
    private(set) var root: PaneNode
    private(set) var activeLeaf: PaneNode
    /// True while `rebuild()` re-creates the view tree — onFocus callbacks from
    /// surfaces being re-added are ignored so they don't clobber the active pane.
    private var rebuilding = false

    /// Called when the last leaf is closed (the host — the tab controller — closes the tab/window).
    var onAllPanesClosed: (() -> Void)?

    /// The window controller hosting this tree. Used by cross-window pane drag to reveal the
    /// destination (bring its window forward / select its tab) after a drop.
    weak var host: PaneTreeHosting?

    /// Set true when this tree's *sole* pane was moved out to another tree by a cross-window
    /// pane drag (see `moveLeafToOtherTree`). The moved `PaneNode` + its live session now belong
    /// to the destination tree, but `root` still references that node until `onAllPanesClosed`
    /// closes this (now-empty) host. So while this flag is set, NO source-teardown path may
    /// terminate it — `deinit` and `terminateAllForClose()` both honor the flag. This is the one
    /// cross-tree invariant that needs care: the session is orphaned from the source root before
    /// any source teardown, and the flag prevents the lingering `root` pointer from killing it.
    private var movedOutEmpty = false

    /// Terminate every session this tree still owns — the entry point host controllers call on
    /// tab/window close. Honors `movedOutEmpty`: if the sole pane was moved to another tree, this
    /// tree owns nothing, so it terminates nothing (the moved session lives on in its new tree).
    func terminateAllForClose() {
        guard !movedOutEmpty else { return }
        root.terminateAll()
    }

    /// When set, a user split request (Cmd+D / Cmd+Shift+D) is handed to this hook *instead*
    /// of mutating the tree locally. Used by tmux-backed tabs so a split issues a tmux
    /// `split-window` (tmux then drives the native split via `%layout-change`). Returning
    /// true means "handled externally — don't split locally". The argument is the active
    /// pane's session so the host can map it to a tmux pane id.
    var onSplitRequest: ((SplitDirection, DamsonSession) -> Bool)?

    /// When set, a user close-pane request (Cmd+W) is handed to this hook instead of closing
    /// the leaf locally — tmux-backed tabs issue `kill-pane` and let `%layout-change` collapse
    /// the split. Returning true means "handled externally". Argument is the active session.
    var onCloseRequest: ((DamsonSession) -> Bool)?

    /// Pane lifecycle animation intent threaded through `rebuild`. `.none` is the
    /// instant/legacy path; `.split` animates the newly-created pane in from the
    /// divider edge; `.close` slides the closing pane's snapshot out to its outer edge.
    private enum PaneAnimation {
        case none
        /// After rebuild, find the wrapper whose leaf === `newLeaf` and animate it in.
        case split(newLeaf: PaneNode)
        case close(snapshot: NSImage, closingFrame: NSRect, edge: ClosingEdge)
        /// Cross-slide swap: each pane's snapshot glides from its old slot to the
        /// other's. Frames are in self coords; differing sizes are interpolated too.
        case swap(snapA: NSImage, frameA: NSRect, snapB: NSImage, frameB: NSRect)
    }

    /// Direction (the outer edge) the closing pane slides toward as it disappears. self is non-flipped (y up).
    private enum ClosingEdge {
        case left, right, top, bottom

        /// (dx, dy) translation equal to a nudge of `size` (the closing frame's width/height) times 0.06.
        /// Since self is y-up, bottom is -y and top is +y.
        func offset(in size: CGSize) -> CGSize {
            let nudgeX = size.width * 0.06
            let nudgeY = size.height * 0.06
            switch self {
            case .left:   return CGSize(width: -nudgeX, height: 0)
            case .right:  return CGSize(width: nudgeX, height: 0)
            case .top:    return CGSize(width: 0, height: nudgeY)
            case .bottom: return CGSize(width: 0, height: -nudgeY)
            }
        }
    }

    init(rootSession: DamsonSession) {
        let leaf = PaneNode.leaf(rootSession)
        self.root = leaf
        self.activeLeaf = leaf
        super.init(frame: .zero)
        wantsLayer = true
        rebuild()
    }

    /// Session restore — construct from an already-built PaneNode tree. active is the first leaf.
    init(restoredRoot: PaneNode) {
        self.root = restoredRoot
        self.activeLeaf = PaneTreeView.firstLeafStatic(of: restoredRoot)
        super.init(frame: .zero)
        wantsLayer = true
        rebuild()
    }

    private static func firstLeafStatic(of node: PaneNode) -> PaneNode {
        switch node.kind {
        case .leaf: return node
        case .split(_, let a, _, _): return firstLeafStatic(of: a)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        // Honor a cross-window move: if this tree's sole pane was moved out, its session is now
        // owned by another tree and must not be terminated here (root still points at it).
        if !movedOutEmpty { root.terminateAll() }
    }

    // MARK: - Public actions

    func split(direction: SplitDirection) {
        guard case .leaf(let activeSession, _) = activeLeaf.kind else { return }
        // tmux-backed tab: let the host issue a tmux `split-window`; tmux drives the native
        // split back via `%layout-change`. (A local split would mint a non-tmux pane in a
        // tmux tab — see docs §8: a tab is all-tmux or all-local.)
        if let hook = onSplitRequest, hook(direction, activeSession) { return }
        // A split always inherits the current pane's working directory (shell-integration
        // OSC 7 report → falling back to the cwd at spawn time), since opening a pane
        // alongside within the same project is the common case.
        var config = DamsonConfig.fromUserDefaults()
        if let cwd = activeSession.currentDirectory { config.cwd = cwd }
        let newSession = DamsonSession(config: config)
        let newLeaf = PaneNode.leaf(newSession)
        let oldKind = activeLeaf.kind
        // Replace activeLeaf's kind with a split. The activeLeaf instance stays the same (preserving the parent link).
        let oldLeafCopy = PaneNode(kind: oldKind)
        oldLeafCopy.parent = activeLeaf
        newLeaf.parent = activeLeaf
        activeLeaf.kind = .split(
            direction: direction,
            first: oldLeafCopy,
            second: newLeaf,
            ratio: 0.5
        )
        activeLeaf = newLeaf
        // Animate the new pane in only when motion is enabled (live transform,
        // no snapshot → the only gate is Motion.enabled). Otherwise the instant
        // path (rebuild(animation: .none)) — identical end state to today.
        rebuild(animation: Motion.enabled ? .split(newLeaf: newLeaf) : .none)
    }

    /// Apply a preset layout in one shot: reuse existing panes where possible (preserving
    /// their sessions/scrollback), spawn fresh sessions for any extra panes the template
    /// needs, and terminate panes the template drops. New panes inherit the active pane's cwd.
    func applyLayout(_ template: PaneLayoutTemplate) {
        // tmux-backed tabs own their layout (driven by `%layout-change`) — don't re-layout locally.
        if onSplitRequest != nil { return }

        let needed = template.paneCount
        let existing = root.leafNodes()
        let activeSession: DamsonSession? = {
            if case .leaf(let s, _) = activeLeaf.kind { return s }
            if case .leaf(let s, _) = existing.first?.kind { return s }
            return nil
        }()

        var leaves: [PaneNode] = []
        for i in 0..<needed {
            if i < existing.count {
                leaves.append(existing[i])
            } else {
                var config = DamsonConfig.fromUserDefaults()
                if let cwd = activeSession?.currentDirectory { config.cwd = cwd }
                leaves.append(PaneNode.leaf(DamsonSession(config: config)))
            }
        }
        // Terminate sessions for panes the template doesn't keep.
        if existing.count > needed {
            for dropped in existing[needed...] {
                if case .leaf(let s, _) = dropped.kind { s.terminate() }
            }
        }

        let newRoot = template.build(leaves)
        setRoot(newRoot, active: leaves[0])
    }

    /// Replace the entire pane tree with a new root (a tmux `%layout-change` reconcile).
    /// Reused leaf nodes keep their existing sessions/surfaces — and thus their grids and
    /// scrollback — so output is continuous across reconciles; the view hierarchy is rebuilt
    /// around the new split structure. The active pane follows `active` when it's still in
    /// the new tree, otherwise the current active if still present, else the first leaf.
    /// Idempotent: applying the same shape twice is a no-op-equivalent rebuild.
    func setRoot(_ newRoot: PaneNode, active: PaneNode? = nil) {
        root = newRoot
        if let active, Self.contains(active, in: newRoot) {
            activeLeaf = active
        } else if !Self.contains(activeLeaf, in: newRoot) {
            activeLeaf = PaneTreeView.firstLeafStatic(of: newRoot)
        }
        rebuild()
    }

    /// True if `target` is `node` or lives anywhere inside it (by === identity).
    private static func contains(_ target: PaneNode, in node: PaneNode) -> Bool {
        if node === target { return true }
        if case .split(_, let a, let b, _) = node.kind {
            return contains(target, in: a) || contains(target, in: b)
        }
        return false
    }

    /// The active pane's surface view (damson-cli `zoom` etc. target it directly).
    var activeSurfaceView: DamsonSurfaceView? {
        if case .leaf(_, let surface) = activeLeaf.kind { return surface }
        return nil
    }

    func closeActive() {
        // tmux-backed tab: route Cmd+W to a tmux `kill-pane`; `%layout-change` then collapses
        // the split (or `%window-close` closes the tab). Falls through to a local close if no
        // hook is set (normal local tabs).
        if case .leaf(let s, _) = activeLeaf.kind, let hook = onCloseRequest, hook(s) { return }
        closeLeaf(activeLeaf)
    }

    /// Closes the leaf holding a session when that session ends (shell exit). The exit
    /// callback may arrive on another thread, so ensure this is invoked on main.
    func closeSession(_ session: DamsonSession) {
        guard let leaf = leafNode(for: session, in: root) else { return }
        closeLeaf(leaf)
    }

    /// Closes the given leaf (fires onAllPanesClosed if it was the last pane). Shared by
    /// closeActive and shell exit.
    func closeLeaf(_ leaf: PaneNode) {
        guard case .leaf(let s, _) = leaf.kind else { return }

        // --- Compute the animation intent (before mutating the tree). On disabled/snapshot-failure, .none → instant path. ---
        var animation: PaneAnimation = .none
        if Motion.enabled,
           let parent = leaf.parent,
           case .split(let dir, let first, _, _) = parent.kind,
           let wrapper = findWrapper(for: leaf, in: self),
           let snap = Motion.snapshot(of: wrapper) {
            let closingFrame = wrapper.convert(wrapper.bounds, to: self)
            let isFirst = (first === leaf)
            let edge: ClosingEdge
            switch dir {
            case .horizontal: edge = isFirst ? .left : .right   // first=left, second=right
            case .vertical:   edge = isFirst ? .top : .bottom  // first=top, second=bottom
            }
            animation = .close(snapshot: snap, closingFrame: closingFrame, edge: edge)
        }

        // Terminate the session (already dead on a shell exit, but idempotent).
        s.terminate()
        // The parent's other child is promoted into the parent's slot.
        guard let parent = leaf.parent,
              case .split(_, let first, let second, _) = parent.kind
        else {
            // Closed the root leaf — shut everything down.
            onAllPanesClosed?()
            return
        }
        let sibling = (first === leaf) ? second : first
        parent.kind = sibling.kind
        // If the sibling was a split, update its children's parent links.
        if case .split(_, let a, let b, _) = parent.kind {
            a.parent = parent
            b.parent = parent
        }
        // Set the new active to the first leaf of the promoted sub-tree.
        activeLeaf = firstLeaf(of: parent)
        rebuild(animation: animation)
    }

    /// Find the leaf node in the tree holding the given session (by === identity).
    private func leafNode(for session: DamsonSession, in node: PaneNode) -> PaneNode? {
        switch node.kind {
        case .leaf(let s, _):
            return s === session ? node : nil
        case .split(_, let a, let b, _):
            return leafNode(for: session, in: a) ?? leafNode(for: session, in: b)
        }
    }

    /// Externally invoked to change the active pane (e.g. on a mouse click).
    func setActive(_ leaf: PaneNode) {
        guard case .leaf(_, let surface) = leaf.kind else { return }
        let changed = activeLeaf !== leaf
        activeLeaf = leaf
        // A genuine focus move while the layout is stable → cross-fade the indicator
        // (rebuild() uses the instant path, so it never animates from a stale frame).
        updateBorderColors(animated: changed)
        // Only re-grab first responder on an actual change — onFocus→setActive
        // calls back in here when a pane is clicked, so re-asserting would loop.
        if changed, window?.firstResponder !== surface {
            window?.makeFirstResponder(surface)
        }
    }

    /// ⌘⇧+click — swap the *positions* of the clicked pane and the current active pane.
    /// Only the two leaf nodes' payloads (session+surface) are exchanged, so the tree
    /// shape/parent links/ratio stay intact. The active session moves to the new position
    /// and focus follows that session.
    func swapActive(with target: PaneNode) {
        guard target !== activeLeaf, target.isLeaf, activeLeaf.isLeaf else { return }

        // Before the swap, capture each pane's current position + snapshot (including the
        // Metal surface). Since rebuild places the content into the new slots instantly,
        // we lay these snapshots over the old positions and slide them to each other's
        // position to create the 'two panes trading places' motion.
        var animation: PaneAnimation = .none
        if Motion.enabled,
           let wrapperA = findWrapper(for: activeLeaf, in: self),
           let wrapperB = findWrapper(for: target, in: self),
           let snapA = Motion.snapshot(of: wrapperA),
           let snapB = Motion.snapshot(of: wrapperB) {
            animation = .swap(
                snapA: snapA, frameA: wrapperA.convert(wrapperA.bounds, to: self),
                snapB: snapB, frameB: wrapperB.convert(wrapperB.bounds, to: self)
            )
        }

        let activeKind = activeLeaf.kind
        activeLeaf.kind = target.kind
        target.kind = activeKind
        // The active session now lives in the target node, so move active there for focus to follow.
        activeLeaf = target
        rebuild(animation: animation)
    }

    /// Cmd+Opt+arrow — move focus to the nearest adjacent pane in the given direction,
    /// relative to the current active pane's on-screen position.
    func moveFocus(_ dir: PaneFocusDirection) {
        if let target = directionalNeighbor(dir) { setActive(target) }
    }

    /// damson-cli `resize-pane` — nudge the split divider that governs the active pane
    /// toward `dir` by `fraction` of the relevant axis (one nudge per call). Walks up from
    /// the active leaf to the nearest ancestor split whose axis matches the direction
    /// (horizontal split ↔ left/right, vertical split ↔ up/down), then shifts its ratio
    /// the same way SplitContainer.applyDrag does. Returns false if there's no such split.
    @discardableResult
    func resizeActiveDivider(_ dir: PaneFocusDirection, fraction: CGFloat) -> Bool {
        let wantHorizontal = (dir == .left || dir == .right)
        // Find the nearest ancestor split on the matching axis, and whether the active
        // pane lives in its `first` (left/top) subtree — that decides the ratio sign.
        var child: PaneNode = activeLeaf
        var node: PaneNode? = activeLeaf.parent
        while let parent = node {
            if case .split(let sdir, let first, let second, let ratio) = parent.kind {
                let axisMatches = (sdir == .horizontal) == wantHorizontal
                if axisMatches {
                    let inFirst = containsNode(child, in: first)
                    // Moving the divider "right"/"down" grows the first (left/top) pane.
                    // Mirror applyDrag's coordinate handling: vertical splits are bottom-up.
                    var delta: CGFloat
                    switch dir {
                    case .right, .down: delta = fraction
                    case .left, .up:    delta = -fraction
                    }
                    // If the active pane is the second child, a positive nudge in its own
                    // direction should grow IT, so flip the sign relative to the first pane.
                    if !inFirst { delta = -delta }
                    let newRatio = min(0.95, max(0.05, ratio + delta))
                    parent.kind = .split(direction: sdir, first: first, second: second, ratio: newRatio)
                    needsLayout = true
                    return true
                }
            }
            child = parent
            node = parent.parent
        }
        return false
    }

    /// True if `target` is `subtree` or lives anywhere inside it.
    private func containsNode(_ target: PaneNode, in subtree: PaneNode) -> Bool {
        if subtree === target { return true }
        if case .split(_, let a, let b, _) = subtree.kind {
            return containsNode(target, in: a) || containsNode(target, in: b)
        }
        return false
    }

    /// Leaf sessions in left-to-right / top-to-bottom traversal order, paired with whether each is active.
    /// For damson-cli `list-panes`.
    func paneSessionsInOrder() -> [(session: DamsonSession, active: Bool)] {
        var out: [(DamsonSession, Bool)] = []
        func walk(_ node: PaneNode) {
            switch node.kind {
            case .leaf(let s, _):
                out.append((s, node === activeLeaf))
            case .split(_, let a, let b, _):
                walk(a); walk(b)
            }
        }
        walk(root)
        return out
    }

    /// Cmd+Shift+arrow — swap *positions* with the nearest adjacent pane in the given direction.
    func swapDirectional(_ dir: PaneFocusDirection) {
        if let target = directionalNeighbor(dir) { swapActive(with: target) }
    }

    /// Find the leaf closest on screen in the `dir` direction relative to the active pane.
    /// Uses the leaf wrappers' frames in self's coordinate space. (Shared by focus move/swap.)
    private func directionalNeighbor(_ dir: PaneFocusDirection) -> PaneNode? {
        var wrappers: [PaneLeafWrapper] = []
        func collect(_ v: NSView) {
            if let w = v as? PaneLeafWrapper { wrappers.append(w) }
            for sub in v.subviews { collect(sub) }
        }
        collect(self)
        guard wrappers.count >= 2,
              let current = wrappers.first(where: { $0.leaf === activeLeaf })
        else { return nil }

        let cur = current.convert(current.bounds, to: self)
        let curMid = NSPoint(x: cur.midX, y: cur.midY)

        // Keep only candidates matching the direction (clearly offset along that axis), then pick the smallest center distance.
        var best: PaneLeafWrapper?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for w in wrappers where w !== current {
            let f = w.convert(w.bounds, to: self)
            let mid = NSPoint(x: f.midX, y: f.midY)
            let dx = mid.x - curMid.x
            let dy = mid.y - curMid.y
            // self is non-flipped (y up). up = increasing y, down = decreasing y.
            let matches: Bool
            switch dir {
            case .left: matches = dx < -1
            case .right: matches = dx > 1
            case .up: matches = dy > 1
            case .down: matches = dy < -1
            }
            guard matches else { continue }
            let dist = dx * dx + dy * dy
            if dist < bestDist { bestDist = dist; best = w }
        }
        return best?.leaf
    }

    // MARK: - Pane drag (Control+Command drag to re-dock a pane)

    /// In-flight Control+Command pane drag. Holds the dragged leaf, the floating drag-image
    /// layer that follows the cursor, and the drop-indicator layer, plus enough to animate a
    /// cancel back to where the pane started. nil when no pane drag is active.
    private struct PaneDragState {
        let leaf: PaneNode
        let startSelf: NSPoint           // mouseDown point in self coords (for the threshold)
        let dragImage: NSImage?          // snapshot of the dragged pane (may be nil → no image)
        let originalFrame: NSRect        // dragged wrapper's frame in self (cancel target)
        var armed: Bool                  // crossed the drag threshold → overlays shown
        var imageWindow: PaneDragImageWindow?  // floating snapshot following the cursor (crosses windows)
        var indicatorLayer: CALayer?     // drop-edge highlight over the hovered pane
        weak var indicatorTree: PaneTreeView?  // tree currently showing the indicator (may be another window)
    }
    private var paneDrag: PaneDragState?
    /// Movement (pt) required before a Control+Command press becomes a drag (vs. a stray click).
    private let paneDragThreshold: CGFloat = 6

    /// Begin a Control+Command pane drag from `leaf`. Returns false (no drag) when the pane
    /// can't be moved — i.e. it's the only pane (no parent split to collapse). Snapshots the
    /// pane now (live Metal content included) for the floating drag image. Called by the leaf
    /// wrapper, which then forwards drag/up events here.
    func beginPaneDrag(from leaf: PaneNode, startWindowPoint: NSPoint) -> Bool {
        // Any leaf can be picked up. A sole pane (no parent) has no in-window destination, but
        // it CAN be dropped into another window — which then closes this now-empty source.
        guard leaf.isLeaf else { return false }
        let startSelf = convert(startWindowPoint, from: nil)
        let wrapper = findWrapper(for: leaf, in: self)
        let image = wrapper.flatMap { Motion.snapshot(of: $0) }
        let frame = wrapper.map { $0.convert($0.bounds, to: self) } ?? bounds
        paneDrag = PaneDragState(leaf: leaf, startSelf: startSelf, dragImage: image,
                                 originalFrame: frame, armed: false,
                                 imageWindow: nil, indicatorLayer: nil, indicatorTree: nil)
        return true
    }

    /// A drag tick (cursor moved). Below the threshold this is a no-op; once crossed it lazily
    /// creates the floating drag image + drop indicator, then on every move repositions the
    /// image under the cursor and re-targets the indicator onto the hovered pane's drop edge.
    func updatePaneDrag(windowPoint: NSPoint) {
        guard var drag = paneDrag, let win = window else { return }
        let p = convert(windowPoint, from: nil)
        let screenPoint = win.convertPoint(toScreen: windowPoint)
        if !drag.armed {
            guard hypot(p.x - drag.startSelf.x, p.y - drag.startSelf.y) >= paneDragThreshold else { return }
            drag.armed = true
            // Floating snapshot in its own borderless window so it follows the cursor ACROSS
            // windows — a source-window CALayer can't draw over another window.
            if let img = drag.dragImage {
                let size = NSSize(width: drag.originalFrame.width * 0.5,
                                  height: drag.originalFrame.height * 0.5)
                let imageWindow = PaneDragImageWindow(image: img, size: size)
                imageWindow.center(on: screenPoint)
                imageWindow.orderFront(nil)
                drag.imageWindow = imageWindow
            }
        }
        drag.imageWindow?.center(on: screenPoint)
        // Re-target the drop indicator onto whatever pane — in ANY window — is under the cursor.
        if let hit = treeAndLeaf(atScreen: screenPoint),
           !(hit.tree === self && hit.leaf === drag.leaf),
           let rect = hit.tree.indicatorRect(for: hit.leaf, edge: hit.edge) {
            setIndicator(on: hit.tree, frame: rect, drag: &drag)
        } else {
            setIndicator(on: nil, frame: nil, drag: &drag)
        }
        paneDrag = drag
    }

    /// Drop: if the cursor is over a valid other pane, detach the dragged node and re-insert it
    /// at the chosen edge (or swap on a center drop), then rebuild with the split-in settle.
    /// Anything else (no target, dropped on itself, never armed) cancels and animates back.
    func endPaneDrag(windowPoint: NSPoint) {
        guard let drag = paneDrag, let win = window else { return }
        guard drag.armed else { cancelPaneDrag(); return }
        let screenPoint = win.convertPoint(toScreen: windowPoint)
        // The drop target may be in this tree OR another window's tree. Dropping on the dragged
        // pane itself (its only in-self target when it's the sole pane) is a no-op cancel.
        guard let hit = treeAndLeaf(atScreen: screenPoint),
              !(hit.tree === self && hit.leaf === drag.leaf) else {
            cancelPaneDrag(); return
        }
        // Valid drop — tear down the floating overlays; the rebuild settle takes over.
        paneDrag = nil
        drag.imageWindow?.orderOut(nil)
        drag.indicatorLayer?.removeFromSuperlayer()

        if hit.tree === self {
            performSameWindowDrop(dragged: drag.leaf, target: hit.leaf, edge: hit.edge)
        } else {
            performCrossWindowDrop(dragged: drag.leaf, to: hit.tree, target: hit.leaf, edge: hit.edge)
        }
    }

    /// Same-window re-dock (the original drop path). center = swap; otherwise detach + insert.
    private func performSameWindowDrop(dragged: PaneNode, target: PaneNode, edge: PaneDropEdge) {
        if edge == .center {
            activeLeaf = dragged
            swapActive(with: target)
            return
        }
        // Capture the target session BEFORE detaching: collapsing the dragged pane's old parent
        // can remap the target node (sibling payload hoisted). Re-find the live target by session.
        guard case .leaf(let targetSession, _) = target.kind else { return }
        guard detachLeafForMove(dragged) else { return }
        let liveTarget = leafNode(for: targetSession, in: root) ?? target
        insertLeaf(dragged, nextTo: liveTarget, edge: edge)
        activeLeaf = dragged
        rebuild(animation: Motion.enabled ? .split(newLeaf: dragged) : .none)
    }

    /// Move `dragged` (carrying its live session/surface) out of this tree into another window's
    /// `dest` tree. The dragged node's `.leaf(session, surface)` travels intact, so when `dest`
    /// rebuilds, the destination wrapper adopts the existing surface (AppKit reparents the NSView).
    /// CROSS-TREE INVARIANT: the dragged node is removed from this tree's live structure (detach,
    /// or — for a sole pane — flagged `movedOutEmpty`) BEFORE any source teardown, so the moved
    /// session is never terminated by the now-empty source closing.
    private func performCrossWindowDrop(dragged: PaneNode, to dest: PaneTreeView,
                                        target: PaneNode, edge: PaneDropEdge) {
        let dockEdge: PaneDropEdge = (edge == .center) ? .left : edge   // no "swap" across windows
        let soleSource = (dragged.parent == nil)   // dragged pane IS this tree's whole content
        if soleSource {
            movedOutEmpty = true                    // this tree empties; its close must not terminate
        } else {
            detachLeafForMove(dragged)              // collapse this tree's parent split
        }
        // dest's nodes are untouched by the source collapse, so `target` is still valid.
        dest.insertLeaf(dragged, nextTo: target, edge: dockEdge)
        dest.activeLeaf = dragged
        if !soleSource { rebuild() }                // source: relayout without the moved pane
        dest.rebuild(animation: Motion.enabled ? .split(newLeaf: dragged) : .none)
        dest.host?.revealTree(dest)                 // bring the destination forward / select its tab
        if soleSource { onAllPanesClosed?() }       // close the now-empty source tab/window
    }

    /// Cancel an in-flight drag: remove the indicator and (if motion is on) glide the drag
    /// image back to where the pane started before removing it. No tree mutation.
    func cancelPaneDrag() {
        guard let drag = paneDrag else { return }
        paneDrag = nil
        drag.indicatorLayer?.removeFromSuperlayer()
        guard let imageWindow = drag.imageWindow else { return }
        guard Motion.enabled, let win = window else { imageWindow.orderOut(nil); return }
        // Glide the floating image back to the source pane's on-screen spot, then remove it.
        let windowPt = convert(NSPoint(x: drag.originalFrame.midX, y: drag.originalFrame.midY), to: nil)
        let screenMid = win.convertPoint(toScreen: windowPt)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.duration
            imageWindow.animator().setFrameOrigin(NSPoint(x: screenMid.x - imageWindow.frame.width / 2,
                                                          y: screenMid.y - imageWindow.frame.height / 2))
        }, completionHandler: {
            imageWindow.orderOut(nil)
        })
    }

    // MARK: - Cross-window drop helpers

    /// The drop-indicator rect (self coords) for docking next to `leaf` on `edge`, or nil if the
    /// leaf isn't in this tree. Called on the DESTINATION tree during a cross-window drag.
    func indicatorRect(for leaf: PaneNode, edge: PaneDropEdge) -> NSRect? {
        guard let w = findWrapper(for: leaf, in: self) else { return nil }
        let f = w.convert(w.bounds, to: self)
        return indicatorFrame(for: edge, in: f)
    }

    /// Show/move the drop indicator on `tree` (possibly another window), migrating the layer
    /// between trees as the cursor crosses windows. nil tree hides it.
    private func setIndicator(on tree: PaneTreeView?, frame: NSRect?, drag: inout PaneDragState) {
        if drag.indicatorTree !== tree {
            drag.indicatorLayer?.removeFromSuperlayer()
            drag.indicatorLayer = nil
            if let tree {
                let ind = CALayer()
                ind.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
                ind.borderColor = NSColor.controlAccentColor.cgColor
                ind.borderWidth = 2
                ind.zPosition = 99_999
                tree.layer?.addSublayer(ind)
                drag.indicatorLayer = ind
            }
            drag.indicatorTree = tree
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let frame {
            drag.indicatorLayer?.frame = frame
            drag.indicatorLayer?.isHidden = false
        } else {
            drag.indicatorLayer?.isHidden = true
        }
        CATransaction.commit()
    }

    /// Frontmost pane under a SCREEN point across all visible windows: its tree, leaf, drop edge.
    private func treeAndLeaf(atScreen sp: NSPoint) -> (tree: PaneTreeView, leaf: PaneNode, edge: PaneDropEdge)? {
        for win in NSApp.orderedWindows where win.isVisible {
            guard let content = win.contentView else { continue }
            let winPt = win.convertPoint(fromScreen: sp)
            for tree in PaneTreeView.collectTrees(in: content) {
                let inTree = tree.convert(winPt, from: nil)
                guard tree.bounds.contains(inTree) else { continue }
                if let hit = tree.dropTarget(at: inTree) { return (tree, hit.leaf, hit.edge) }
            }
        }
        return nil
    }

    /// Collect the `PaneTreeView`s in a window's content view (does not descend into a found tree).
    private static func collectTrees(in view: NSView) -> [PaneTreeView] {
        var out: [PaneTreeView] = []
        func walk(_ v: NSView) {
            if let t = v as? PaneTreeView { out.append(t); return }
            for s in v.subviews { walk(s) }
        }
        walk(view)
        return out
    }

    // MARK: - Detach / insert (reusable; the cross-window step will call these)

    /// Detach `leaf` from the tree WITHOUT terminating its session — the inverse half of
    /// `closeLeaf` (which collapses + terminates). Collapses the parent split by hoisting the
    /// sibling subtree into the parent's slot, fixes the promoted children's parent links, and
    /// orphans `leaf` (parent = nil) so it carries its live session+surface out intact, ready to
    /// be re-inserted elsewhere. Returns false for the root leaf (nothing to collapse). Does NOT
    /// rebuild — the caller pairs this with `insertLeaf` then a single rebuild.
    @discardableResult
    func detachLeafForMove(_ leaf: PaneNode) -> Bool {
        guard leaf.isLeaf,
              let parent = leaf.parent,
              case .split(_, let first, let second, _) = parent.kind
        else { return false }
        let sibling = (first === leaf) ? second : first
        // Promote the sibling into the parent's slot (identical collapse to closeLeaf).
        parent.kind = sibling.kind
        if case .split(_, let a, let b, _) = parent.kind {
            a.parent = parent
            b.parent = parent
        }
        leaf.parent = nil   // orphaned, but still .leaf(session, surface) → the terminal travels with it
        return true
    }

    /// Insert the (already detached) `node` next to leaf `target`, docking on `edge`. Mirrors
    /// `split()`: the `target` NODE stays in place and becomes the new split (so its parent link
    /// — or the root pointer — is preserved automatically), with a copy carrying the target's
    /// payload as one child and `node` as the other. Order/direction come from the edge:
    /// left/top → node is `first`; right/bottom → node is `second`; horizontal for left/right,
    /// vertical for top/bottom; ratio 0.5. `center` is handled by the caller via swap, not here.
    func insertLeaf(_ node: PaneNode, nextTo target: PaneNode, edge: PaneDropEdge) {
        guard target.isLeaf else { return }
        let direction: SplitDirection
        let draggedFirst: Bool
        switch edge {
        case .left:   direction = .horizontal; draggedFirst = true
        case .right:  direction = .horizontal; draggedFirst = false
        case .top:    direction = .vertical;   draggedFirst = true
        case .bottom: direction = .vertical;   draggedFirst = false
        case .center: return
        }
        let targetCopy = PaneNode(kind: target.kind)
        targetCopy.parent = target
        node.parent = target
        let first  = draggedFirst ? node : targetCopy
        let second = draggedFirst ? targetCopy : node
        target.kind = .split(direction: direction, first: first, second: second, ratio: 0.5)
    }

    /// Hit-test `point` (self coords) to the leaf wrapper under it, returning the leaf and which
    /// drop edge the point falls in. nil when the point is over no pane.
    func dropTarget(at point: NSPoint) -> (leaf: PaneNode, edge: PaneDropEdge)? {
        var wrappers: [PaneLeafWrapper] = []
        func collect(_ v: NSView) {
            if let w = v as? PaneLeafWrapper { wrappers.append(w) }
            for sub in v.subviews { collect(sub) }
        }
        collect(self)
        for w in wrappers {
            let f = w.convert(w.bounds, to: self)
            if f.contains(point) { return (w.leaf, dropEdge(at: point, in: f)) }
        }
        return nil
    }

    /// Classify a point inside pane frame `f` (self coords, y-up) into a drop edge: the inner
    /// ~30% box is `center` (swap), otherwise the nearest of the four edges (diagonal quadrants).
    private func dropEdge(at point: NSPoint, in f: NSRect) -> PaneDropEdge {
        let lx = point.x - f.minX
        let ly = point.y - f.minY
        let w = max(f.width, 1), h = max(f.height, 1)
        if lx > w * 0.35, lx < w * 0.65, ly > h * 0.35, ly < h * 0.65 { return .center }
        // Normalized distance to each edge; the smallest wins.
        let dLeft = lx / w, dRight = (w - lx) / w
        let dBottom = ly / h, dTop = (h - ly) / h   // y-up: top edge is the higher-y side
        let m = min(dLeft, dRight, dTop, dBottom)
        if m == dLeft { return .left }
        if m == dRight { return .right }
        if m == dTop { return .top }
        return .bottom
    }

    /// The sub-rect of pane frame `f` (self coords, y-up) the drop indicator highlights for a
    /// given edge: the half on that side, or the whole pane for a center (swap) drop.
    private func indicatorFrame(for edge: PaneDropEdge, in f: NSRect) -> NSRect {
        switch edge {
        case .left:   return NSRect(x: f.minX, y: f.minY, width: f.width / 2, height: f.height)
        case .right:  return NSRect(x: f.midX, y: f.minY, width: f.width / 2, height: f.height)
        case .top:    return NSRect(x: f.minX, y: f.midY, width: f.width, height: f.height / 2)
        case .bottom: return NSRect(x: f.minX, y: f.minY, width: f.width, height: f.height / 2)
        case .center: return f
        }
    }

    // MARK: - Tree → NSView rebuild

    private func rebuild(animation: PaneAnimation = .none) {
        // Re-adding surfaces fires their viewDidMoveToWindow → makeFirstResponder →
        // onFocus, which would set the active pane to a stale node mid-rebuild.
        // Suppress onFocus during the rebuild; we set the correct active explicitly.
        rebuilding = true
        defer { rebuilding = false }
        for sub in subviews { sub.removeFromSuperview() }
        addSubviewsForNode(root, into: self)
        configureAccessibility()
        updateBorderColors()
        if case .leaf(_, let surface) = activeLeaf.kind {
            window?.makeFirstResponder(surface)
        }
        needsLayout = true
        // The live hierarchy was rebuilt to its final state above (the sibling snaps to full). Now handle the per-intent overlays.
        switch animation {
        case .none:
            break

        case .split(let newLeaf):
            // (Task 3) Motion of the new pane sliding in from the divider edge — derive the
            // direction from the parent split, then make the 2-arg call.
            guard let parent = newLeaf.parent,
                  case .split(let dir, _, _, _) = parent.kind
            else { break }
            animateSplitIn(newLeaf: newLeaf, direction: dir)

        case .close(let snapshot, let closingFrame, let edge):
            // (Task 5) Motion of the closed pane's snapshot disappearing — nudging from its
            // old frame toward the outer edge while fading out — extracted into a helper
            // (symmetric with animateSplitIn).
            animateCloseOut(snapshot: snapshot, closingFrame: closingFrame, edge: edge)

        case .swap(let snapA, let frameA, let snapB, let frameB):
            // The two pane snapshots cross-slide in straight lines into each other's slots.
            animateSwap(snapA: snapA, frameA: frameA, snapB: snapB, frameB: frameB)
        }
    }

    private func addSubviewsForNode(_ node: PaneNode, into container: NSView) {
        switch node.kind {
        case .leaf(let session, let surface):
            // leaf container — wrapper used to show the border. Fills via frame + autoresizing.
            let wrapper = PaneLeafWrapper(leaf: node, owner: self)
            wrapper.translatesAutoresizingMaskIntoConstraints = true
            wrapper.autoresizingMask = [.width, .height]
            wrapper.frame = container.bounds
            container.addSubview(wrapper)
            // The surface fills the wrapper completely — the active indicator (dim/border)
            // is drawn by an overlay layer on top, so no inset is needed. Adjacent panes
            // butt together, so the only visible seam is the 1px divider line.
            surface.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(surface)
            NSLayoutConstraint.activate([
                surface.topAnchor.constraint(equalTo: wrapper.topAnchor),
                surface.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
                surface.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
                surface.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            ])
            // Clicking a pane's content makes its surface first responder; mirror
            // that into the active-pane state (and indicator) since the surface now
            // fills the wrapper, so the wrapper no longer gets the click itself.
            surface.onFocus = { [weak self, weak node] in
                guard let self, let node, !self.rebuilding else { return }
                self.setActive(node)
            }
            // Shell exited (e.g. `exit`) → close this pane (collapses the split, or
            // closes the tab/window if it was the last). Fired on a PTY thread, so
            // hop to main. Found by session identity so a later split/rebuild that
            // moved the node doesn't matter.
            session.onExit = { [weak self, weak session] _ in
                guard let session else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.closeSession(session)
                }
            }

        case .split(_, let first, let second, _):
            // split — two sub-areas + divider. SplitContainer.layout() computes the frames
            // (direction/ratio are read directly from node.kind, so no binding is needed here).
            let splitContainer = SplitContainer(node: node, owner: self)
            splitContainer.translatesAutoresizingMaskIntoConstraints = true
            splitContainer.autoresizingMask = [.width, .height]
            splitContainer.frame = container.bounds
            container.addSubview(splitContainer)
            addSubviewsForNode(first, into: splitContainer.firstContainer)
            addSubviewsForNode(second, into: splitContainer.secondContainer)
        }
    }

    // MARK: - Split/Close animation helpers

    /// Recursively find the `PaneLeafWrapper` whose `leaf` is identical (===) to
    /// `target`. Walks the freshly-rebuilt subtree; returns nil if not found.
    /// Used by both the split-in (Task 3) and close (Task 5) animations.
    private func findWrapper(for target: PaneNode, in view: NSView) -> PaneLeafWrapper? {
        if let w = view as? PaneLeafWrapper, w.leaf === target {
            return w
        }
        for sub in view.subviews {
            if let found = findWrapper(for: target, in: sub) { return found }
        }
        return nil
    }

    /// Animate the new pane "opening from the split line": its wrapper is already
    /// at the final half-frame, so we animate the wrapper's `layer.transform` from
    /// a small nudge toward the divider back to identity, plus opacity 0→1.
    /// Pure visual layer animation — the live surface is never resized (no reflow).
    private func animateSplitIn(newLeaf: PaneNode, direction: SplitDirection) {
        // The wrapper's final half-frame is computed by SplitContainer.layout(),
        // which only runs during a layout pass. Force it now so wrapper.bounds is
        // final before we read it.
        layoutSubtreeIfNeeded()

        guard let wrapper = findWrapper(for: newLeaf, in: self),
              let layer = wrapper.layer,
              wrapper.bounds.width > 0, wrapper.bounds.height > 0
        else { return }

        // Small "nudge", not a full traverse, to keep the motion subtle. The new pane
        // may be either child: a Cmd+D split always makes it `second`, but a pane re-dock
        // (insertLeaf) can place it `first` (dropped on the target's left/top edge). Derive
        // which side it's on from the parent split so the nudge starts from the divider in
        // both cases. All views here are non-flipped (y grows upward), matching
        // SplitContainer.layout()'s bottom-up coordinate comments.
        let isFirst: Bool = {
            if let parent = newLeaf.parent, case .split(_, let first, _, _) = parent.kind {
                return first === newLeaf
            }
            return false
        }()
        let fromTransform: CATransform3D
        switch direction {
        case .horizontal:
            // The divider is on the side the pane butts against: a `second` (right) pane
            // starts nudged LEFT (-x) toward the divider; a `first` (left) pane nudged
            // RIGHT (+x). It then settles back into place.
            let mag = min(24, wrapper.bounds.width * 0.06)
            fromTransform = CATransform3DMakeTranslation(isFirst ? mag : -mag, 0, 0)
        case .vertical:
            // Bottom-up coords: a `second` (bottom) pane starts nudged UP (+y) toward the
            // divider; a `first` (top) pane nudged DOWN (-y). Then settles into place.
            let mag = min(24, wrapper.bounds.height * 0.06)
            fromTransform = CATransform3DMakeTranslation(0, isFirst ? -mag : mag, 0)
        }

        // Set the final state on the MODEL layer first, then add explicit
        // "from → identity" animations (same idiom as the bell-flash
        // CABasicAnimation in DamsonTerminalView). The model values are at their
        // final identity/1.0 state BEFORE add(), so when the animation finishes
        // (or is removed) the layer rests where it already is. Driven by
        // Motion.duration / Motion.timing only.
        layer.transform = CATransform3DIdentity
        layer.opacity = 1.0

        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = NSValue(caTransform3D: fromTransform)
        move.toValue = NSValue(caTransform3D: CATransform3DIdentity)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0

        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = Motion.duration
        group.timingFunction = Motion.timing
        // No removal/cleanup needed: animations are non-additive and the layer's
        // model values are already at their final identity/1.0 state, so when the
        // animation finishes the wrapper simply rests where it already is. Safe
        // under rapid splits — a later rebuild() nukes & rebuilds the subtree,
        // discarding any in-flight animation with its (removed) wrapper.
        layer.add(group, forKey: "damson.split-in")
    }

    /// Animate the closing pane "sliding out toward its outer edge": a bitmap
    /// snapshot of the closed pane sits at its old `closingFrame` and slides a small
    /// nudge toward `edge` (the outer edge, away from the divider) while fading
    /// α 1→0, then removes itself. The live sibling has already snapped to full size
    /// underneath. Mirrors `animateSplitIn` (a single call from `rebuild`'s switch).
    private func animateCloseOut(snapshot: NSImage, closingFrame: NSRect, edge: ClosingEdge) {
        // Unlike split, the overlay's frame is the precomputed `closingFrame`, so
        // this layout pass is NOT for sizing the overlay — it settles the live
        // sibling underneath (just added by rebuild) into its full-size final state
        // before the snapshot covers it, so the snap is complete on frame 0.
        layoutSubtreeIfNeeded()

        // The overlay is a sublayer of self.layer, so rebuild()'s subviews teardown doesn't
        // touch it → even under rapid/nested rebuilds it isn't stranded and is only removed in asyncAfter.
        let overlay = Motion.overlay(image: snapshot, frame: closingFrame, in: self)
        let off = edge.offset(in: closingFrame.size)
        let fromPos = overlay.position
        let toPos = CGPoint(x: fromPos.x + off.width, y: fromPos.y + off.height)

        // Same explicit CABasicAnimation idiom as closeTab: on a vanilla CALayer with no
        // delegate, a bare model assignment triggers CA's default implicit animation — so we don't touch the model before/after add().
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
        overlay.add(group, forKey: "damson.pane-close")

        // Remove the overlay after the animation. Each close captures only its own overlay,
        // so rapid successive closes are safe with no shared state.
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.duration) {
            overlay.removeFromSuperlayer()
        }
    }

    /// Cross-slide swap, tuned to read naturally: the initiating (active) pane A lifts
    /// slightly and passes OVER the other, which dips beneath — so the crossing reads as
    /// two panes trading places in depth rather than two images blending through each
    /// other. Both travel on a spring (accelerate, then settle organically), with a soft
    /// shadow under the lifted card.
    ///
    /// Different-sized panes: the content must NOT rubber-stretch to the destination size.
    /// Each traveling "card" is a small layer stack — an opaque theme-background base (also
    /// the shadow caster) with the snapshot on top at `.resizeAspect` (uniform scale, like
    /// a macOS window zoom; the base fills the letterbox). Near arrival the old snapshot
    /// dissolves into a snapshot of the re-flowed destination content, so the card lands
    /// pixel-identical to the live pane underneath and the overlay removal stays seamless.
    private func animateSwap(snapA: NSImage, frameA: NSRect, snapB: NSImage, frameB: NSRect) {
        // Settle the live content rebuild just placed into its final position/size (before the snapshot covers it).
        layoutSubtreeIfNeeded()

        // Arrival (re-flowed) content for the landing dissolve — only needed when the sizes
        // differ. Repaint synchronously first so the snapshots show the new-size render, not
        // a stale frame from before the swap.
        let sizesDiffer = frameA.size != frameB.size
        var arrivalAtB: NSImage?   // what now lives in slot B (the moved active pane)
        var arrivalAtA: NSImage?
        if sizesDiffer {
            repaintAllLeaves()
            if let w = findWrapper(for: activeLeaf, in: self) { arrivalAtB = Motion.snapshot(of: w) }
            if let w = wrapperAt(frame: frameA) { arrivalAtA = Motion.snapshot(of: w) }
        }

        // Opaque backdrops over both slots: rebuild has ALREADY placed the live content in
        // its final (swapped) arrangement, so as the traveling cards vacate their slots the
        // destination content would show through underneath (clearly visible while the panes
        // overlap mid-crossing). Theme-background backdrops hide it until the cards land.
        let bg: CGColor = {
            if case .leaf(let s, _) = activeLeaf.kind { return s.config.backgroundColor.cgColor }
            return DamsonConfig.fromUserDefaults().backgroundColor.cgColor
        }()
        var cleanup: [CALayer] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for f in [frameA, frameB] {
            let back = CALayer()
            back.frame = f
            back.backgroundColor = bg
            back.zPosition = 9_999   // under both traveling cards
            layer?.addSublayer(back)
            cleanup.append(back)
        }
        CATransaction.commit()

        // A (the pane the user is moving) rides above B so the crossing reads as "over".
        let settle = flyCard(
            CardSpec(old: snapA, arrival: arrivalAtB, bg: bg, lift: 1.03,
                     shadow: true, z: 10_010, key: "damson.swap-a"),
            from: frameA, to: frameB, cleanup: &cleanup)
        _ = flyCard(
            CardSpec(old: snapB, arrival: arrivalAtA, bg: bg, lift: 0.97,
                     shadow: false, z: 10_000, key: "damson.swap-b"),
            from: frameB, to: frameA, cleanup: &cleanup)
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            cleanup.forEach { $0.removeFromSuperlayer() }
        }
    }

    /// The leaf wrapper currently occupying `frame` (self coords) — used to snapshot a
    /// slot's re-flowed content after a swap rebuild. The tree shape is unchanged by a
    /// swap, so the slot rects match the pre-swap frames exactly.
    private func wrapperAt(frame: NSRect) -> PaneLeafWrapper? {
        var found: PaneLeafWrapper?
        func walk(_ v: NSView) {
            if let w = v as? PaneLeafWrapper,
               w.convert(w.bounds, to: self).insetBy(dx: -0.5, dy: -0.5).contains(
                   CGPoint(x: frame.midX, y: frame.midY)),
               abs(w.convert(w.bounds, to: self).width - frame.width) < 1 {
                found = w
            }
            for sub in v.subviews where found == nil { walk(sub) }
        }
        walk(self)
        return found
    }

    /// Uniformly fit `aspect` into `rect`, anchored at the TOP-LEFT (self is y-up, so the
    /// top edge is maxY). Terminal content starts at the top-left, so scaling a traveling
    /// pane from that corner reads naturally; the card's background fills the right/bottom.
    private func fitTopLeft(aspect: NSSize, in rect: NSRect) -> NSRect {
        guard aspect.width > 0, aspect.height > 0 else { return rect }
        let k = min(rect.width / aspect.width, rect.height / aspect.height)
        let size = NSSize(width: aspect.width * k, height: aspect.height * k)
        return NSRect(x: rect.minX, y: rect.maxY - size.height,
                      width: size.width, height: size.height)
    }

    /// Fly one swap "card" `from`→`to` and return the spring's settling duration.
    /// The card is a sibling stack sharing one flight path (each layer gets identical
    /// spring/scale animations — CA doesn't relayout sublayers along a parent's
    /// presentation-layer bounds animation, so siblings are simpler than a container):
    ///   base:    opaque theme background — fill behind the fitted content and the shadow
    ///            caster for the lifted card. Flies the full `from`→`to` rects.
    ///   old:     the pre-swap snapshot, flying to its aspect-fitted rect anchored at the
    ///            destination's top-left. The endpoint sizes are exact uniform multiples, so
    ///            every interpolated size keeps the image's aspect — no rubber-stretching —
    ///            and the card/content top-left corners coincide for the whole flight.
    ///   arrival: (sizes differ) the re-flowed destination snapshot flying the reverse
    ///            fit (top-left-fitted-in-`from` → full `to`), dissolving in over the last
    ///            ~45% so the card lands matching the live content underneath.
    /// Everything one traveling card needs besides its flight rects: the images,
    /// backdrop color, lift scale, shadow role, stacking order, and animation key.
    private struct CardSpec {
        var old: NSImage
        var arrival: NSImage?
        var bg: CGColor
        var lift: CGFloat
        var shadow: Bool
        var z: CGFloat
        var key: String
    }

    private func flyCard(_ spec: CardSpec, from: NSRect, to: NSRect,
                         cleanup: inout [CALayer]) -> TimeInterval {
        let (old, arrival, bg, lift, shadow, z, key) =
            (spec.old, spec.arrival, spec.bg, spec.lift, spec.shadow, spec.z, spec.key)
        let scaleFactor = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0

        let base = CALayer()
        base.backgroundColor = bg
        if shadow {
            base.shadowColor = NSColor.black.cgColor
            base.shadowRadius = 12
            base.shadowOffset = CGSize(width: 0, height: -4)   // self is y-up: cast downward
        }

        let oldLayer = CALayer()
        oldLayer.contents = old
        oldLayer.contentsGravity = .resize   // frames keep the image aspect (uniform multiples)
        oldLayer.contentsScale = scaleFactor

        // Per-layer flight rects (see doc comment).
        var stack: [(layer: CALayer, from: NSRect, to: NSRect)] = [
            (base, from, to),
            (oldLayer, from, fitTopLeft(aspect: from.size, in: to)),
        ]
        var arrivalLayer: CALayer?
        if let arrival {
            let n = CALayer()
            n.contents = arrival
            n.contentsGravity = .resize
            n.contentsScale = scaleFactor
            n.opacity = 0
            arrivalLayer = n
            stack.append((n, fitTopLeft(aspect: to.size, in: from), to))
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, entry) in stack.enumerated() {
            entry.layer.frame = entry.from
            entry.layer.zPosition = z + CGFloat(i)
            layer?.addSublayer(entry.layer)
        }
        CATransaction.commit()
        cleanup.append(contentsOf: stack.map { $0.layer })

        // ζ ≈ 0.8 — the same "organic settle" family as the tab-slide spring
        // (CompactWindowController.tabSlideSpring, 150/20), a touch stiffer so a pane swap
        // (a small, frequent gesture) lands quicker (~0.33s vs 0.42s).
        func spring(_ keyPath: String, _ fromValue: Any, _ toValue: Any) -> CASpringAnimation {
            let s = CASpringAnimation(keyPath: keyPath)
            s.fromValue = fromValue
            s.toValue = toValue
            s.mass = 1
            s.stiffness = 220
            s.damping = 24
            s.duration = s.settlingDuration
            s.isRemovedOnCompletion = false
            s.fillMode = .forwards
            return s
        }
        func keyframes(_ keyPath: String, _ values: [Any], _ keyTimes: [NSNumber],
                       _ duration: TimeInterval) -> CAKeyframeAnimation {
            let k = CAKeyframeAnimation(keyPath: keyPath)
            k.values = values
            k.keyTimes = keyTimes
            k.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut),
                                      count: max(values.count - 1, 1))
            k.duration = duration
            k.isRemovedOnCompletion = false
            k.fillMode = .forwards
            return k
        }

        let settle = spring("position", 0, 1).settlingDuration

        for (i, entry) in stack.enumerated() {
            let l = entry.layer
            l.add(spring("position",
                         NSValue(point: CGPoint(x: entry.from.midX, y: entry.from.midY)),
                         NSValue(point: CGPoint(x: entry.to.midX, y: entry.to.midY))),
                  forKey: "\(key).pos.\(i)")
            l.add(spring("bounds.size",
                         NSValue(size: entry.from.size), NSValue(size: entry.to.size)),
                  forKey: "\(key).size.\(i)")
            // Mid-flight lift/dip, back to exactly 1.0 on arrival for a seamless hand-off.
            l.add(keyframes("transform.scale", [1.0, lift, 1.0], [0, 0.45, 1], settle),
                  forKey: "\(key).scale.\(i)")
        }
        if shadow {
            base.add(keyframes("shadowOpacity", [0.0, 0.30, 0.0], [0, 0.45, 1], settle),
                     forKey: "\(key).shadow")
        }
        // Landing dissolve: old content out, re-flowed arrival content in, over the tail of
        // the flight — hides the aspect-fit crop/reflow difference exactly where it matters.
        if let arrivalLayer {
            oldLayer.add(keyframes("opacity", [1.0, 1.0, 0.0], [0, 0.55, 1], settle),
                         forKey: "\(key).fade-out")
            arrivalLayer.add(keyframes("opacity", [0.0, 0.0, 1.0], [0, 0.55, 1], settle),
                             forKey: "\(key).fade-in")
        }
        return settle
    }

    // MARK: - Border color update

    /// `animated` is true only on a genuine focus change while the layout is stable
    /// (`setActive`); `rebuild()` passes false so the indicator never animates from a
    /// stale frame. The flag is forwarded to each wrapper's indicator update.
    /// True when the tree has more than one pane (i.e. the root is a split). Border focus
    /// indicators only show when there are multiple panes — a lone pane needs no hint.
    var hasMultiplePanes: Bool {
        if case .split = root.kind { return true }
        return false
    }

    private func updateBorderColors(animated: Bool = false) {
        func walk(_ view: NSView) {
            if let wrapper = view as? PaneLeafWrapper {
                let active = (wrapper.leaf === activeLeaf)
                wrapper.setActiveState(active, animated: animated)
                // The surface has its own isActive (cursor blink runs only in the
                // active pane) — the wrapper flag only drives the dim/border overlay.
                if case .leaf(_, let surface) = wrapper.leaf.kind {
                    surface.isActive = active
                }
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(self)
    }

    /// Force every leaf surface to repaint its current grid right now.
    ///
    /// Called when this tree is re-shown (tab return). While a tab is backgrounded
    /// its pane surfaces are removed from the superview, so Metal draw requests for
    /// grid updates that arrive meanwhile are dropped (no visible drawable) — only
    /// the version-dedupe key advances. Re-adding the tree focuses just the active
    /// pane, so the inactive panes would keep their stale last-drawn frame until
    /// clicked. Walking every leaf and forcing a repaint makes off-screen output
    /// visible immediately on return, with no click required.
    func repaintAllLeaves() {
        for (_, surface) in root.leaves() {
            surface.repaintNow()
        }
    }

    /// Re-apply to every wrapper when the active-pane indicator setting changes (active state unchanged).
    func refreshIndicators() {
        func walk(_ view: NSView) {
            (view as? PaneLeafWrapper)?.applyIndicator()
            for sub in view.subviews { walk(sub) }
        }
        walk(self)
    }

    /// If node is a leaf, return it; if a split, descend to the first leaf.
    private func firstLeaf(of node: PaneNode) -> PaneNode {
        switch node.kind {
        case .leaf: return node
        case .split(_, let a, _, _): return firstLeaf(of: a)
        }
    }

    // MARK: - Accessibility (VoiceOver) — additive; does not affect layout/drag/focus

    /// Expose the split structure to assistive tech. When the tree holds at least one split,
    /// the whole tree is an AX "split group" (matching the AppKit splitter-group convention) so
    /// VoiceOver announces it as split panes containing the per-pane groups and adjustable
    /// dividers. A single pane is just a plain container — no split-group framing needed.
    /// Re-applied on every rebuild() since rebuild() recreates the child views (the dividers /
    /// pane groups configure themselves in their own init).
    private func configureAccessibility() {
        if case .split = root.kind {
            setAccessibilityRole(.splitGroup)
            setAccessibilityRoleDescription("split panes")
            setAccessibilityElement(true)
        } else {
            setAccessibilityRole(.group)
            setAccessibilityRoleDescription(nil)
            setAccessibilityElement(false)
        }
    }
}

/// Leaf wrapper view — shows the active pane in the configured style (dim / border).
private final class PaneLeafWrapper: NSView {
    let leaf: PaneNode
    weak var owner: PaneTreeView?
    /// Overlays that sit above the terminal's Metal layer (with a high zPosition).
    /// dimLayer = inactive-pane scrim, borderLayer = active-pane border.
    private let dimLayer = CALayer()
    private let borderLayer = CALayer()
    /// Whether this leaf is the active pane. Set only via `setActiveState(_:animated:)`
    /// so the caller controls whether the indicator transition animates.
    private(set) var isActive: Bool = false

    init(leaf: PaneNode, owner: PaneTreeView) {
        self.leaf = leaf
        self.owner = owner
        super.init(frame: .zero)
        wantsLayer = true
        dimLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.zPosition = 100
        dimLayer.isHidden = true
        borderLayer.zPosition = 101
        borderLayer.borderWidth = 0
        layer?.addSublayer(dimLayer)
        layer?.addSublayer(borderLayer)

        // Accessibility (VoiceOver): expose the pane as a labeled group. The label is computed
        // live in `accessibilityLabel()` (session title → cwd → fallback, plus an "active" tag),
        // so it tracks title/cwd/focus changes without any extra wiring. Role .group keeps this
        // a container so the terminal surface child stays reachable — we do NOT mark the wrapper
        // itself a leaf element, which would hide the surface.
        setAccessibilityRole(.group)
        setAccessibilityRoleDescription("terminal pane")

        // Focus-follows-mouse: hover over a pane to activate it. The terminal
        // surface sits on top with its own tracking areas, but tracking areas are
        // per-view and independent, so this one still fires when the cursor crosses
        // into the wrapper. `.inVisibleRect` keeps it sized across splits/resizes.
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self, userInfo: nil
        )
        addTrackingArea(tracking)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// VoiceOver label for the pane — computed live so it reflects the current title / cwd /
    /// focus without needing to be re-pushed on every change. Prefers the session title, falls
    /// back to the working directory's last path component, then a generic name; the active
    /// pane is tagged "(active)" so VoiceOver announces which pane has focus.
    override func accessibilityLabel() -> String? {
        var name = "Terminal pane"
        if case .leaf(let session, _) = leaf.kind {
            let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                name = title
            } else if let cwd = session.currentDirectory, !cwd.isEmpty {
                let leafName = (cwd as NSString).lastPathComponent
                name = leafName.isEmpty ? cwd : leafName
            }
        }
        return isActive ? "\(name) (active)" : name
    }

    /// When the cursor enters this pane (setting on + key window), make it the active
    /// pane — same path as a click. While the mouse button is held and dragged into
    /// another pane (drag-selection/divider), events are captured by the originating
    /// view so no enter arrives and it doesn't interfere.
    override func mouseEntered(with event: NSEvent) {
        guard FocusFollowsMouse.enabled,
              window?.isKeyWindow == true,
              owner?.activeLeaf !== leaf
        else { return }
        owner?.setActive(leaf)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.frame = bounds
        borderLayer.frame = bounds
        CATransaction.commit()
    }

    /// Update the active flag and refresh the indicator. When `animated` (and motion is
    /// enabled) the dim/border layers cross-fade; otherwise the change is instant. Called
    /// with `animated: true` only on a genuine focus move (`setActive`).
    func setActiveState(_ active: Bool, animated: Bool) {
        isActive = active
        applyIndicator(animated: animated)
    }

    /// Re-read the settings and refresh the indicator (on active change or settings change).
    /// `animated` cross-fades the dim scrim / active border via CoreAnimation, gated on
    /// `Motion.enabled`; the default instant path is the historical behaviour (and is what
    /// `rebuild()` / settings changes use, so the indicator never animates from a stale frame).
    func applyIndicator(animated: Bool = false) {
        let mode = ActivePaneIndicator.current
        let borderMode = (mode == .accentBorder || mode == .subtleBorder)

        // Target visibility, expressed as layer opacity so it can cross-fade:
        //  - dim scrim participates only in dimInactive mode, shown (0.4) on inactive panes.
        //  - border shows on the active pane in the two border modes.
        // A lone pane needs no focus hint — only show the border when the window is split.
        let multiPane = owner?.hasMultiplePanes ?? false
        let dimVisible = (mode == .dimInactive)
        let dimTarget: Float = (dimVisible && !isActive) ? 0.4 : 0.0
        let borderTarget: Float = (borderMode && isActive && multiPane) ? 1.0 : 0.0

        // Border color/width are static per mode (only opacity animates the fade), so set
        // them on BOTH panes in a border mode — the inactive one rests at opacity 0 and can
        // then fade its border out when it loses focus.
        if borderMode {
            let color = (mode == .accentBorder) ? Self.accentBorderColor()
                                                : Self.subtleBorderColor(leaf: leaf)
            borderLayer.borderColor = color.cgColor
            borderLayer.borderWidth = 1
        } else {
            borderLayer.borderWidth = 0
        }

        guard animated, Motion.enabled else {
            // Instant path — identical end state to the historical behaviour.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dimLayer.isHidden = !dimVisible
            dimLayer.opacity = dimTarget
            borderLayer.opacity = borderTarget
            CATransaction.commit()
            return
        }

        // Animated cross-fade. Un-hiding can't animate, so make the scrim present instantly
        // (it was already un-hidden + at its resting opacity by the prior instant pass) and
        // carry the transition on opacity. Border layers stay width 1 across a focus move
        // (the mode is unchanged), so only opacity animates there too.
        let dimFrom = dimLayer.isHidden ? Float(0) : dimLayer.opacity
        dimLayer.isHidden = !dimVisible
        animateOpacity(dimLayer, from: dimFrom, to: dimTarget, key: "damson.indicator-dim")
        animateOpacity(borderLayer, from: borderLayer.opacity, to: borderTarget, key: "damson.indicator-border")
    }

    /// Fade a layer's opacity `from`→`to` over Motion.duration/timing. Same explicit
    /// CABasicAnimation idiom as the pane split/close animations: set the model value to its
    /// final state, then add a non-additive from→to animation, so the layer rests at `to`
    /// once the animation completes (no cleanup needed). A no-op when `from == to`.
    private func animateOpacity(_ layer: CALayer, from: Float, to: Float, key: String) {
        layer.opacity = to
        guard from != to else { layer.removeAnimation(forKey: key); return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = Motion.duration
        fade.timingFunction = Motion.timing
        layer.add(fade, forKey: key)
    }

    /// A subtle border color shifted slightly from the background (dark theme → a bit lighter, light theme → a bit darker).
    /// A muted accent for the active-pane border. The raw system accent is too vivid and
    /// "pops", so blend it toward black and drop the alpha a little — still clearly the accent
    /// hue, just calmer.
    private static func accentBorderColor() -> NSColor {
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .controlAccentColor
        let darker = accent.blended(withFraction: 0.4, of: .black) ?? accent
        return darker.withAlphaComponent(0.8)
    }

    private static func subtleBorderColor(leaf: PaneNode) -> NSColor {
        guard case .leaf(let session, _) = leaf.kind else { return .clear }
        let bg = (session.config.backgroundColor.usingColorSpace(.sRGB)) ?? .black
        let lum = 0.299 * bg.redComponent + 0.587 * bg.greenComponent + 0.114 * bg.blueComponent
        let target: CGFloat = lum < 0.5 ? 1.0 : 0.0
        let t: CGFloat = 0.25
        func mix(_ a: CGFloat) -> CGFloat { a + (target - a) * t }
        return NSColor(srgbRed: mix(bg.redComponent), green: mix(bg.greenComponent),
                       blue: mix(bg.blueComponent), alpha: 1.0)
    }

    /// True between a ⌃⌘ mouseDown that started a pane drag and its mouseUp — so the wrapper
    /// forwards the drag/up events to the owner instead of treating them as normal clicks.
    private var paneDragging = false

    /// While ⌘⇧ (pane swap) or ⌃⌘ (pane drag) is held, claim the click for the wrapper instead
    /// of letting it fall through to the terminal surface underneath — this is also what lets a
    /// ⌃⌘ drag bypass mouse-reporting passthrough (the surface never sees the event).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit != nil else { return hit }
        let mods = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.isSuperset(of: [.command, .shift]) || mods.isSuperset(of: [.command, .control]) {
            return self
        }
        return hit
    }

    override func mouseDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if mods == [.command, .shift] {
            // ⌘⇧+click — swap this pane's position with the active pane. Don't forward to the surface.
            owner?.swapActive(with: leaf)
            return
        }
        if mods == [.command, .control] {
            // ⌃⌘+drag — begin moving this pane to a new dock location. Consumes the event
            // (no selection / no PTY passthrough). beginPaneDrag returns false for the sole
            // pane, in which case the gesture is simply a no-op.
            paneDragging = owner?.beginPaneDrag(from: leaf, startWindowPoint: event.locationInWindow) ?? false
            return
        }
        owner?.setActive(leaf)
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if paneDragging {
            owner?.updatePaneDrag(windowPoint: event.locationInWindow)
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if paneDragging {
            paneDragging = false
            owner?.endPaneDrag(windowPoint: event.locationInWindow)
            return
        }
        super.mouseUp(with: event)
    }
}

/// Split container — two sub-areas + a divider in the middle. Divider drag adjusts the ratio.
private final class SplitContainer: NSView {
    let node: PaneNode
    weak var owner: PaneTreeView?
    let firstContainer = NSView()
    let secondContainer = NSView()
    private let divider = DividerView()
    /// Width of the easy-to-grab hit zone. The divider is this wide but draws only a 1px line in the center.
    private let dividerDrag: CGFloat = 10
    /// How close (owner coords) a perpendicular divider must pass to a corner point to count as meeting it.
    private let cornerTolerance: CGFloat = 4
    /// The perpendicular split being driven alongside this one during a corner drag (nil = single-axis).
    private weak var cornerPartner: SplitContainer?

    init(node: PaneNode, owner: PaneTreeView) {
        self.node = node
        self.owner = owner
        super.init(frame: .zero)
        for v in [firstContainer, secondContainer] {
            v.wantsLayer = true
            addSubview(v)
        }
        divider.wantsLayer = true
        addSubview(divider)   // place above the panels to occupy the drag zone at the boundary
        divider.onDragBegin = { [weak self] p in self?.cornerPartner = self?.findCornerPartner(forWindowPoint: p) }
        divider.onDrag = { [weak self] dx, dy in self?.applyDrag(dx: dx, dy: dy) }
        divider.onDragEnd = { [weak self] in self?.cornerPartner = nil }
        // Cursor: a corner (two-axis) point exists only when a perpendicular divider meets an end here.
        divider.isCornerPoint = { [weak self] p in self?.findCornerPartner(forWindowPoint: p) != nil }
        // Accessibility (VoiceOver): let the divider report the current split ratio and resize the
        // panes via AXSplitter increment/decrement, reusing the same ratio path the mouse drag uses.
        divider.accessibilityRatio = { [weak self] in self?.currentRatio ?? 0.5 }
        divider.accessibilityNudge = { [weak self] increment in self?.accessibilityNudgeRatio(increment: increment) }
    }

    /// Current split ratio (0–1) for the divider's AX value.
    var currentRatio: CGFloat {
        guard case .split(_, _, _, let ratio) = node.kind else { return 0.5 }
        return ratio
    }

    /// VoiceOver AXSplitter increment/decrement: nudge the split ratio by ~2% of the divider's
    /// axis, routed through the same `applyAxisDrag` the mouse drag uses. `increment` grows the
    /// first (left/top) pane; `applyAxisDrag` handles the bottom-up sign flip for vertical splits,
    /// so we feed it a window-space delta with the matching sign.
    func accessibilityNudgeRatio(increment: Bool) {
        guard case .split(let dir, _, _, _) = node.kind else { return }
        let axis = (dir == .horizontal) ? bounds.width : bounds.height
        let step = axis * 0.02
        let delta: CGFloat
        switch dir {
        case .horizontal: delta = increment ? step : -step
        case .vertical:   delta = increment ? -step : step
        }
        applyAxisDrag(delta)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        guard case .split(let dir, _, _, let ratio) = node.kind else { return }
        // Butt the panels together (no gap) and overlay the divider on the boundary → only
        // a thin 1px line shows, while the wide hit zone keeps dragging easy.
        switch dir {
        case .horizontal:  // left/right split
            let total = bounds.width
            let firstW = (total * ratio).rounded()
            firstContainer.frame = NSRect(x: 0, y: 0, width: firstW, height: bounds.height)
            secondContainer.frame = NSRect(x: firstW, y: 0, width: total - firstW, height: bounds.height)
            divider.frame = NSRect(x: firstW - dividerDrag / 2, y: 0, width: dividerDrag, height: bounds.height)
            divider.orientation = .vertical
        case .vertical:    // top/bottom split
            let total = bounds.height
            let secondH = (total * (1 - ratio)).rounded()
            let firstH = total - secondH
            // bottom-up coordinate system — so first appears on top and second on the bottom.
            secondContainer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: secondH)
            firstContainer.frame = NSRect(x: 0, y: secondH, width: bounds.width, height: firstH)
            divider.frame = NSRect(x: 0, y: secondH - dividerDrag / 2, width: bounds.width, height: dividerDrag)
            divider.orientation = .horizontal
        }
    }

    /// One drag tick, reported as raw window-space deltas. Drives this divider's own axis
    /// always; when a corner partner was found at mouseDown, also drives that perpendicular
    /// divider — so dragging a corner moves both axes at once.
    private func applyDrag(dx: CGFloat, dy: CGFloat) {
        guard case .split(let dir, _, _, _) = node.kind else { return }
        applyAxisDrag(axisDelta(dir, dx, dy))
        if let partner = cornerPartner, case .split(let pdir, _, _, _) = partner.node.kind {
            partner.applyAxisDrag(partner.axisDelta(pdir, dx, dy))
        }
    }

    /// Pick the window-space delta component `applyAxisDrag` expects for a split of `dir`:
    /// a horizontal split (vertical divider) tracks the x delta; a vertical split (horizontal
    /// divider) tracks the y delta (negated inside `applyAxisDrag` for the bottom-up axis).
    private func axisDelta(_ dir: SplitDirection, _ dx: CGFloat, _ dy: CGFloat) -> CGFloat {
        switch dir {
        case .horizontal: return dx
        case .vertical:   return dy
        }
    }

    private func applyAxisDrag(_ delta: CGFloat) {
        guard case .split(let dir, let a, let b, let ratio) = node.kind else { return }
        let total: CGFloat
        let deltaRatio: CGFloat
        switch dir {
        case .horizontal:
            total = bounds.width
            deltaRatio = delta / max(total, 1)
        case .vertical:
            total = bounds.height
            deltaRatio = -delta / max(total, 1)  // bottom-up coord
        }
        let newRatio = min(0.95, max(0.05, ratio + deltaRatio))
        node.kind = .split(direction: dir, first: a, second: b, ratio: newRatio)
        needsLayout = true
    }

    /// If `windowPoint` sits in a corner zone — within `dividerDrag` of one of this divider's
    /// two ends — and a perpendicular divider passes through that end point, return that split.
    /// Otherwise nil (so the caller falls back to a normal single-axis drag). Pure geometry, so
    /// it finds the perpendicular partner whether it's an ancestor, descendant, or sibling split.
    private func findCornerPartner(forWindowPoint windowPoint: NSPoint) -> SplitContainer? {
        guard let owner else { return nil }
        let local = divider.convert(windowPoint, from: nil)
        let cornerLocal: NSPoint
        switch divider.orientation {
        case .vertical:    // long axis = y; ends at minY / maxY
            if local.y <= divider.bounds.minY + dividerDrag {
                cornerLocal = NSPoint(x: divider.bounds.midX, y: divider.bounds.minY)
            } else if local.y >= divider.bounds.maxY - dividerDrag {
                cornerLocal = NSPoint(x: divider.bounds.midX, y: divider.bounds.maxY)
            } else { return nil }
        case .horizontal:  // long axis = x; ends at minX / maxX
            if local.x <= divider.bounds.minX + dividerDrag {
                cornerLocal = NSPoint(x: divider.bounds.minX, y: divider.bounds.midY)
            } else if local.x >= divider.bounds.maxX - dividerDrag {
                cornerLocal = NSPoint(x: divider.bounds.maxX, y: divider.bounds.midY)
            } else { return nil }
        }
        let corner = divider.convert(cornerLocal, to: owner)
        // Walk the whole pane-view tree for a perpendicular divider whose line passes through
        // the corner. Pick the closest by perpendicular distance to disambiguate near-ties.
        var best: SplitContainer?
        var bestDist = CGFloat.greatestFiniteMagnitude
        func walk(_ view: NSView) {
            for sub in view.subviews {
                if let sc = sub as? SplitContainer, sc !== self,
                   sc.divider.orientation != divider.orientation {
                    let frame = sc.divider.convert(sc.divider.bounds, to: owner)
                    if frame.insetBy(dx: -cornerTolerance, dy: -cornerTolerance).contains(corner) {
                        let d = (sc.divider.orientation == .horizontal)
                            ? abs(corner.y - frame.midY)
                            : abs(corner.x - frame.midX)
                        if d < bestDist { bestDist = d; best = sc }
                    }
                }
                walk(sub)
            }
        }
        walk(owner)
        return best
    }
}

/// Borderless floating window holding the drag snapshot during a pane drag, so the image can
/// follow the cursor ACROSS windows (a CALayer in the source window can't draw over another).
private final class PaneDragImageWindow: NSWindow {
    init(image: NSImage, size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true   // never a drop target, never steals events
        level = .floating
        alphaValue = 0.85
        let iv = NSImageView(frame: NSRect(origin: .zero, size: size))
        iv.image = image
        iv.imageScaling = .scaleAxesIndependently
        contentView = iv
    }

    /// Position the window centered on a screen point (the cursor).
    func center(on screenPoint: NSPoint) {
        setFrameOrigin(NSPoint(x: screenPoint.x - frame.width / 2,
                               y: screenPoint.y - frame.height / 2))
    }
}

/// Draggable divider.
private final class DividerView: NSView {
    enum Orientation { case horizontal, vertical }
    var orientation: Orientation = .vertical {
        didSet { updateCursor(); needsDisplay = true; updateAccessibilityOrientation() }
    }
    /// Accessibility (VoiceOver): current split ratio (0–1) of the owning split, for the AX value.
    var accessibilityRatio: (() -> CGFloat)?
    /// Accessibility: nudge the split ratio one step; `true` grows the first (left/top) pane.
    var accessibilityNudge: ((Bool) -> Void)?
    /// One drag tick as raw window-space deltas. The owning SplitContainer routes one axis
    /// (normal drag) or both (corner drag).
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    /// mouseDown, with the window-space location, so the owner can detect a corner.
    var onDragBegin: ((NSPoint) -> Void)?
    /// mouseUp — clear any corner state.
    var onDragEnd: (() -> Void)?
    /// Given a window-space point, true if it sits in a valid two-axis corner zone.
    var isCornerPoint: ((NSPoint) -> Bool)?
    private var dragStart: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true   // background is clear — the drag zone is wide but only a 1px line is drawn in the center.
        updateCursor()
        // Accessibility (VoiceOver): an adjustable AXSplitter. Role + label are static; the value
        // (ratio) and increment/decrement are served live by the override methods below. Orientation
        // follows the divider's own orientation (a horizontal split's vertical divider is a .vertical
        // splitter, and vice-versa).
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Pane divider")
        setAccessibilityElement(true)
        updateAccessibilityOrientation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateAccessibilityOrientation() {
        switch orientation {
        case .vertical:   setAccessibilityOrientation(.vertical)
        case .horizontal: setAccessibilityOrientation(.horizontal)
        }
    }

    // MARK: - Accessibility (VoiceOver) — adjustable splitter

    override func accessibilityValue() -> Any? {
        accessibilityRatio?() ?? 0.5
    }

    override func accessibilityPerformIncrement() -> Bool {
        guard let accessibilityNudge else { return false }
        accessibilityNudge(true)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard let accessibilityNudge else { return false }
        accessibilityNudge(false)
        return true
    }

    /// Draw only a thin 1px separator line in the center of the wide hit zone (thin and subtle).
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        switch orientation {
        case .vertical:
            NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height).fill()
        case .horizontal:
            NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1).fill()
        }
    }

    private func updateCursor() {
        // Tracking area + cursor — show the appropriate drag cursor on mouse hover.
        let opts: NSTrackingArea.Options = [
            .activeInActiveApp, .inVisibleRect, .cursorUpdate,
        ]
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(rect: .zero, options: opts, owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func cursorUpdate(with event: NSEvent) {
        // Over a corner zone (a perpendicular divider meets an end here) → two-axis cursor.
        if let loc = window?.mouseLocationOutsideOfEventStream, isCornerPoint?(loc) == true {
            NSCursor.crosshair.set()
            return
        }
        switch orientation {
        case .vertical: NSCursor.resizeLeftRight.set()
        case .horizontal: NSCursor.resizeUpDown.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let loc = window?.mouseLocationOutsideOfEventStream
        dragStart = loc
        if let loc { onDragBegin?(loc) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart,
              let now = window?.mouseLocationOutsideOfEventStream
        else { return }
        let dx = now.x - start.x
        let dy = now.y - start.y
        dragStart = now
        onDrag?(dx, dy)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        onDragEnd?()
    }
}
