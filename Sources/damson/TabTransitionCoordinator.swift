import AppKit
import DamsonTerminal

/// Owns the tab CROSS-SLIDE / CREATE animations and (in a follow-up step) the interactive
/// trackpad tab-swipe, extracted from `CompactWindowController` so that ~450 lines of
/// self-contained motion machinery stop competing for space with tab/pane/window lifecycle.
///
/// Seam: the coordinator reaches its controller through `host` and nothing else. It reads
/// `tabs` / `currentIndex` LIVE at every use (never caches them) because the tab array can
/// be mutated — reordered, closed — between an animation's start and its completion block.
///
/// Ownership: `host` is `unowned`, which is safe for two reasons that must both keep holding.
/// (1) The controller owns the coordinator through a single `private(set) lazy var` and nothing
/// else stores it, so a completion block outliving the controller finds `self` (the coordinator)
/// already nil and returns before it can touch `host`. (2) The controller cannot be deallocated
/// *inside* a coordinator call: its strong owners are the app delegate's `compactControllers`
/// and TmuxIntegrationController, and removal from the former happens in a
/// `willCloseNotification` block enqueued on the main queue, never within the current call
/// stack — and the gesture entry points are invoked on a `windowController` the engine is
/// holding for the duration of the call. So a `guard let self` here yields a live coordinator
/// AND a live `host`, exactly as it yielded a live controller before the extraction.
///
/// Corollary rule for the bodies below, which nothing enforces: an escaping closure must never
/// capture a `host` local — reach the controller only as `self.host` under an existing
/// `if let self`. A captured `host` would put a strong controller reference inside a 0.42s CA
/// animation and keep the window (and its PTYs) alive past close.
///
/// The `tabSlide*` motion constants deliberately stay on `CompactWindowController`: the tab
/// bar's selection pill reads them too (CompactTabBarView), and both must animate off the
/// same spring or the pill and the content would drift apart.
final class TabTransitionCoordinator {
    private unowned let host: CompactWindowController

    init(host: CompactWindowController) {
        self.host = host
    }

    /// Bumped on every `animateTabSwitch`. A re-entrant switch (Cmd+arrow again mid-slide)
    /// supersedes the previous one; the prior completion block checks this and bails so it
    /// can't detach/reset a view the new switch is now using.
    private var tabSwitchGeneration = 0

    // Interactive 2-finger swipe (TabSwipeHandler). During a horizontal swipe the
    // neighbor tab's live tree is added beside the current one and both follow the
    // finger; on release past a threshold the switch commits, else it snaps back.
    private var swipeActive = false
    private var swipeAnimating = false
    /// The incoming tab, attached live and excluded from hit-testing (`isSwipePreview`).
    /// Non-nil exactly while a preview is in the container.
    private var swipeNeighborTree: PaneTreeView?
    private var swipeNeighborIndex = -1
    /// Gesture updates since the preview was attached — trace-only, see `PREVIEW_TX_LOST`.
    private var swipeUpdatesSinceAttach = 0
    private var swipeFromRight = false   // neighbor (next tab) enters from the right
    // Where the in-flight settle is heading, so a new swipe that interrupts it can
    // finalize it instantly and chain (flick-flick-flick through tabs "슥슥") instead
    // of being locked out until the 0.42s arrival finishes.
    private var swipePendingCommit = false
    private var swipePendingIndex = -1

    /// Tab-create motion (Task 2): the new tab's content fades + scales in.
    /// `opacity` 0→1 and `transform` 0.98→1.0 over `Motion.duration` easeOut.
    /// The tree already holds its final frame (constraints active); the transform
    /// is purely visual → zero surface reflow.
    func animateTabCreate(_ tree: PaneTreeView) {
        // Final frame must exist before we read layer.bounds for the
        // center-composed scale; force a layout pass first.
        host.contentContainer.layoutSubtreeIfNeeded()
        guard let layer = tree.layer,
              layer.bounds.width > 0, layer.bounds.height > 0 else {
            // Zero-size (e.g. first tab before the window is shown) — skip motion.
            // This is NORMAL and CORRECT: the unconditional reset block above already
            // set the tree to opacity 1 / identity transform, so the tab ends at its
            // final visual state — just without an animation. Not a bug.
            return
        }

        // Center-composed scale: correct for ANY layer anchorPoint (a layer-backed
        // NSView's anchorPoint is not reliably 0.5,0.5; a plain MakeScale would
        // drift toward a corner instead of popping from the center).
        let s: CGFloat = 0.98
        let w = layer.bounds.width
        let h = layer.bounds.height
        let ap = layer.anchorPoint
        let v = CGPoint(x: w * (0.5 - ap.x), y: h * (0.5 - ap.y))
        let fromTransform = CATransform3DConcat(
            CATransform3DConcat(
                CATransform3DMakeTranslation(-v.x, -v.y, 0),
                CATransform3DMakeScale(s, s, 1)
            ),
            CATransform3DMakeTranslation(v.x, v.y, 0)
        )

        // Instantly set the FROM-state (no implicit animation here).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        layer.transform = fromTransform
        CATransaction.commit()

        // Animate TO the final state inside the shared 0.16s easeOut group.
        // Motion.run sets allowsImplicitAnimation = true, so these bare layer
        // assignments animate implicitly (see Task 1 Step 1's contract note).
        Motion.run({
            layer.opacity = 1
            layer.transform = CATransform3DIdentity
        }, done: {
            // Guarantee the resting state even if the run was interrupted.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = 1
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
        })
    }

    /// Tab-switch motion: the outgoing tab and the incoming tab — BOTH live views — slide
    /// horizontally while crossfading. Direction follows the index sign: moving to a higher
    /// index slides content left (new tab enters from the right), lower slides right.
    /// Layer-only — never touches frames — so the live surfaces never reflow.
    /// (Index order == visual order, even after drag-reorder; see Task 6 preamble.)
    ///
    /// No snapshot: the outgoing tree stays attached until the animation completes (then
    /// detaches in the completion). Both sides use EXPLICIT CABasicAnimations because both
    /// are live NSView backing layers under Auto Layout — an implicit transform animation
    /// gets clobbered by AppKit's layout-driven geometry updates. Hit-testing during the
    /// 0.16s overlap resolves to the incoming view (added later = topmost).
    /// A layer's current on-screen `transform.translation.x` if a tab-switch slide is in
    /// flight on it, else nil — used to continue a reversed switch from where it is. Must be
    /// read BEFORE `selectTab` detaches/resets the incoming tree (which clears its animation).
    func inFlightSwitchTranslationX(_ layer: CALayer?) -> CGFloat? {
        guard let layer,
              layer.animation(forKey: "switchIn") != nil
                || layer.animation(forKey: "switchOut") != nil,
              let x = layer.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat
        else { return nil }
        return x
    }

    /// A layer's current on-screen opacity if a tab-switch slide is in flight (crossfade).
    func inFlightSwitchOpacity(_ layer: CALayer?) -> Float? {
        guard let layer,
              layer.animation(forKey: "switchIn") != nil
                || layer.animation(forKey: "switchOut") != nil,
              let pres = layer.presentation() else { return nil }
        return pres.opacity
    }

    /// Re-entry state captured before `selectTab` mutates the trees, so a reversed
    /// mid-slide switch continues from the current on-screen positions.
    struct SwitchReentry {
        var incomingX: CGFloat?
        var outgoingX: CGFloat?
        var incomingOpacity: Float?
        var outgoingOpacity: Float?
    }

    func animateTabSwitch(incoming tree: PaneTreeView, outgoing: PaneTreeView,
                          fromIndex: Int, toIndex: Int, reentry: SwitchReentry) {
        guard let incomingLayer = tree.layer, let outgoingLayer = outgoing.layer else { return }
        // Ensure constraints have produced the final frame before we read/animate it.
        host.contentContainer.layoutSubtreeIfNeeded()

        // Re-entrancy: pressing Cmd+arrow again mid-slide reuses one of these layers (the prior
        // incoming becomes the new outgoing, or vice-versa). `reentry` holds where each layer
        // was on screen when the caller (`selectTab`) started — captured before it detached/reset
        // the incoming tree — so a reversed switch (Cmd+Left then Cmd+Right mid-slide) continues
        // from that position and smoothly changes direction instead of snapping back to the
        // off-screen start and restarting. Clear the stale animations so the new translations
        // don't stack with them (which would break the "glued" invariant). Bump the generation
        // so the previous switch's completion bails.
        let incomingReentryX = reentry.incomingX
        let outgoingReentryX = reentry.outgoingX
        let incomingReentryOpacity = reentry.incomingOpacity
        let outgoingReentryOpacity = reentry.outgoingOpacity
        clearSwitchAnimations(incomingLayer)
        clearSwitchAnimations(outgoingLayer)
        tabSwitchGeneration += 1
        let generation = tabSwitchGeneration

        // Cross-slide geometry (matches Rust halite). Higher target index = new tab
        // is to the right → it enters from the right while the old one exits left.
        let goingRight = toIndex > fromIndex
        let width = host.contentContainer.bounds.width
        let style = TabTransitionStyle.current

        // Per-style offsets + fade + duration. `slide` = full-width page swipe
        // (no fade), with a longer duration so the moving content is legible —
        // a full-width slide at the default 0.16s reads as an instant cut.
        // `crossfade` = the gentle 24pt slide + opacity; `none` handled upstream.
        let fade: Bool
        let incomingStart: CGFloat   // incoming layer's start x (ends at 0)
        let outgoingEnd: CGFloat     // outgoing overlay's end x (starts at 0)
        let dur: TimeInterval
        let timing: CAMediaTimingFunction
        switch style {
        case .slide:
            fade = false
            incomingStart = goingRight ? width : -width
            outgoingEnd = goingRight ? -width : width
            // Spring settle (built below). Paint the container so the few points the spring
            // briefly overshoots past the edge match the terminal bg instead of flashing the
            // window behind. The group is paced linearly; the spring carries its own curve.
            let themeBG = (host.activeSession?.config.theme ?? DamsonConfig.fromUserDefaults().theme).background
            host.contentContainer.layer?.backgroundColor = themeBG.cgColor
            dur = CompactWindowController.tabSlideSpringDuration
            timing = CAMediaTimingFunction(name: .linear)
        case .crossfade, .none:
            fade = true
            let delta: CGFloat = 24
            incomingStart = goingRight ? delta : -delta
            outgoingEnd = goingRight ? -delta : delta
            dur = Motion.duration
            timing = Motion.timing
        }

        // Models stay at their final values; the explicit animations drive the
        // presentation. The outgoing's end state (off-screen/faded) is pinned by
        // fillMode=.forwards until the completion detaches the view.
        incomingLayer.opacity = 1

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak tree, weak outgoing] in
            // Superseded by a newer switch? It now owns these views' cleanup — bail so we
            // don't detach/reset something the new switch is mid-animating.
            if let self, self.tabSwitchGeneration != generation { return }
            if let outgoing {
                // Detach unless something re-selected it mid-animation (it would then be
                // the currently-shown tree and must stay).
                if let self, self.host.tabs.indices.contains(self.host.currentIndex),
                   self.host.tabs[self.host.currentIndex].tree === outgoing {
                    // re-selected — leave attached
                } else {
                    outgoing.removeFromSuperview()
                }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                outgoing.layer?.removeAnimation(forKey: "switchOut")
                outgoing.layer?.transform = CATransform3DIdentity
                outgoing.layer?.opacity = 1
                CATransaction.commit()
            }
            tree?.layer?.removeAnimation(forKey: "switchIn")
        }

        // Incoming: slide from off-screen (or its current on-screen x if reversing mid-slide) to 0.
        let iSlide = tabSlideTranslation(style: style, from: incomingReentryX ?? incomingStart, to: 0)
        var inAnims = [iSlide]
        if fade {
            let iFade = CABasicAnimation(keyPath: "opacity")
            iFade.fromValue = incomingReentryOpacity.map(Double.init) ?? 0.0
            iFade.toValue = 1.0
            inAnims.append(iFade)
        }
        let iGroup = CAAnimationGroup()
        iGroup.animations = inAnims
        iGroup.duration = dur
        iGroup.timingFunction = timing
        incomingLayer.add(iGroup, forKey: "switchIn")

        // Outgoing live layer: slide from 0 (or its current on-screen x if reversing mid-slide) →
        // outgoingEnd. Same spring params as the incoming, so the two stay rigidly glued.
        // fillMode=.forwards pins the end state until completion detaches it.
        let oSlide = tabSlideTranslation(style: style, from: outgoingReentryX ?? 0, to: outgoingEnd)
        var outAnims = [oSlide]
        if fade {
            let oFade = CABasicAnimation(keyPath: "opacity")
            oFade.fromValue = outgoingReentryOpacity.map(Double.init) ?? 1.0
            oFade.toValue = 0.0
            outAnims.append(oFade)
        }
        let oGroup = CAAnimationGroup()
        oGroup.animations = outAnims
        oGroup.duration = dur
        oGroup.timingFunction = timing
        oGroup.isRemovedOnCompletion = false
        oGroup.fillMode = .forwards
        outgoingLayer.add(oGroup, forKey: "switchOut")

        CATransaction.commit()
    }

    /// The `selectTab` entry gate, lifted verbatim so both swipe flags stay private here:
    /// any non-swipe switch (keyboard, tab click, damson-cli) tears an in-flight swipe down
    /// first so nothing is left offset. Still invoked from the same position in `selectTab`.
    func abortSwipeIfNeeded() {
        if swipeActive || swipeAnimating { abortSwipe() }
    }

    // MARK: - Interactive 2-finger swipe (TabSwipeHandler)

    /// Live finger-tracking. Both tabs are live trees and both follow the accumulated
    /// translation. The current one remains the sole scroll/event target — its layer
    /// transform is visual-only and doesn't move its hit-test frame — and the incoming one
    /// is marked `isSwipePreview`, which takes it out of hit-testing for the same reason.
    ///
    /// The neighbor used to be a snapshot layer instead, to keep a live sibling view from
    /// intercepting events or stealing first responder. That bought event isolation at the
    /// cost of the tab not existing until commit, which is where the blank came from — so the
    /// isolation is now explicit (`isSwipePreview` + a first-responder handback in
    /// `attachSwipePreview`) and the tab is real for the whole gesture.
    func tabSwipeUpdate(translation dx: CGFloat) {
        // A new swipe arriving mid-settle finalizes the previous one instantly and
        // then starts fresh from the (now committed) current tab, so successive
        // flicks flip through tabs without waiting for the arrival animation.
        if swipeAnimating { finalizeSwipeSettleNow() }
        guard !swipeAnimating, host.tabs.count > 1 else { return }
        let width = host.contentContainer.bounds.width
        guard width > 1 else { return }

        if !swipeActive {
            guard abs(dx) > 1 else { return }   // wait for a clear direction
            guard aimSwipe(goPrev: dx > 0, width: width) else { return }
            swipeActive = true
        } else if abs(dx) > 1, (dx > 0) == swipeFromRight {
            // The finger crossed back through zero and is now heading the other way. Re-aim at
            // the neighbor on THAT side instead of holding the one picked at gesture start:
            // only one neighbor is ever attached, so keeping the original would push the
            // current tab off the bare side of the container — a grey band where no tab is.
            // Clamping the drag instead was the first attempt, and it made reversing a swipe
            // feel stuck, which is worse than the band it prevented.
            _ = aimSwipe(goPrev: dx > 0, width: width)
        }

        let neighborStart = swipeFromRight ? width : -width
        // Regression detector for the flash, sampled BEFORE the write below overwrites it.
        //
        // The preview's offset has to survive AppKit's layout pass, which runs at the end of
        // the runloop turn the attach happened in — after every log the attach itself could
        // write. When it did not survive, the tab was composited at x=0 for the single frame
        // between that pass and this update: the incoming tab flashing over the current one at
        // the start of a swipe. `PaneTreeView.swipeTranslationX` holds the offset in a filled
        // animation for exactly this reason, so a hit here means that stopped working.
        // Sample from the SECOND update on: on the attach's own turn CA has not committed yet,
        // so the presentation layer still reads the pre-attach value and every sample would be
        // a false alarm. (This must not `return` — the translation below has to run on every
        // update, including the ones this skips.)
        if SwipeLog.enabled, let preview = swipeNeighborTree, swipeUpdatesSinceAttach < 5 {
            swipeUpdatesSinceAttach += 1
            // The PRESENTATION layer: the offset is held by a filled animation and the model
            // transform stays identity, so `layer.transform` would read 0 even when correct.
            let observed = preview.layer?.presentation()?
                .value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0
            if swipeUpdatesSinceAttach > 1, abs(observed - preview.swipeTranslationX) > 1 {
                SwipeLog.log("swipe.PREVIEW_TX_LOST",
                             String(format: "update=%d observed=%.1f expected=%.1f",
                                    swipeUpdatesSinceAttach, observed,
                                    preview.swipeTranslationX))
            }
        }
        setSwipeTranslation(host.tabs[host.currentIndex].tree, dx)
        setSwipeTranslation(swipeNeighborTree, neighborStart + dx)

        // Track the tab-bar selection pill to the swipe progress so it moves with
        // the finger (like the keyboard switch animation) instead of snapping only
        // after the settle completes.
        let fraction = min(1, abs(dx) / width)
        host.tabBar.swipePillTrack(fromIndex: host.currentIndex, toIndex: swipeNeighborIndex,
                              fraction: fraction)
    }

    /// Release: commit the switch if dragged past ~20% of the width in the locked
    /// direction, otherwise snap back. Commit hands off to the normal `selectTab`
    /// path (same as keyboard) once the slide finishes, so focus + tab-bar stay
    /// consistent; the snapshot layer is removed after the live tab is in place.
    func tabSwipeEnd(translation dx: CGFloat, velocity: CGFloat) {
        guard swipeActive else { return }
        let width = host.contentContainer.bounds.width
        let neighborStart = swipeFromRight ? width : -width
        // Commit on distance OR a fast flick. swipeFromRight (next) commits on a
        // negative drag/flick; prev on positive. The flick check makes a quick
        // short swipe switch immediately instead of needing to drag 1/8 of the width.
        let distThreshold = width * 0.12
        let velThreshold: CGFloat = 6
        let commit = swipeFromRight ? (dx < -distThreshold || velocity < -velThreshold)
                                    : (dx > distThreshold || velocity > velThreshold)
        let neighborIndex = swipeNeighborIndex
        swipeActive = false
        swipeAnimating = true
        swipePendingCommit = commit
        swipePendingIndex = commit ? neighborIndex : host.currentIndex

        // Settle the tab-bar pill onto its target in sync with the content slide
        // (same duration + curve), so the bar finishes exactly when the page does.
        host.tabBar.swipePillSettle(toIndex: commit ? neighborIndex : host.currentIndex,
                                    duration: CompactWindowController.tabSlideDuration,
                                    timing: CompactWindowController.tabSlideTiming())

        // Settle both layers from the release offset to the target: commit →
        // dx = -neighborStart (neighbor reaches 0, current slides fully off);
        // cancel → dx = 0 (current back, neighbor back off-screen).
        let targetDx: CGFloat = commit ? -neighborStart : 0
        startSwipeSettle(from: dx, to: targetDx, neighborStart: neighborStart) { [weak self] in
            guard let self else { return }
            if commit {
                self.setSwipeTranslation(self.host.tabs[self.host.currentIndex].tree, 0)
                self.endSwipe()
                // Real switch (instant) — same path as keyboard nav, so first
                // responder, title, and tab-bar selection are all correct.
                self.commitToTab(neighborIndex)
            } else {
                self.detachNeighborPreview()
                self.setSwipeTranslation(self.host.tabs[self.host.currentIndex].tree, 0)
                self.endSwipe()
            }
        }
    }

    /// Point the gesture at the neighbor on the side the finger is heading, attaching it live
    /// and parked just off that edge. Returns false if there is no distinct tab to aim at.
    ///
    /// Used both to lock the direction at gesture start and to re-aim when the finger reverses
    /// through zero. With exactly two tabs the previous and next neighbor are the SAME tree, so
    /// a reversal re-parks the tab already attached instead of detaching and re-adding it —
    /// which matters, because a detach costs its surfaces their drawables.
    private func aimSwipe(goPrev: Bool, width: CGFloat) -> Bool {
        let count = host.tabs.count
        let neighborIndex = goPrev ? (host.currentIndex - 1 + count) % count
                                   : (host.currentIndex + 1) % count
        guard neighborIndex != host.currentIndex else { return false }
        swipeFromRight = !goPrev            // next tab enters from the right
        swipeNeighborIndex = neighborIndex
        let offset = swipeFromRight ? width : -width

        let neighborTree = host.tabs[neighborIndex].tree
        if neighborTree === swipeNeighborTree {
            SwipeLog.log("swipe.PREVIEW_REAIM", "neighbor=\(neighborIndex) offset=\(Int(offset))")
            neighborTree.swipeTranslationX = offset
            return true
        }
        if let old = swipeNeighborTree {
            SwipeLog.log("swipe.PREVIEW_SWAP", "neighbor=\(neighborIndex) replaces the other side")
            swipeNeighborTree = nil
            host.detachSwipePreview(old)
        }
        SwipeLog.log("swipe.PREVIEW_ATTACH", "neighbor=\(neighborIndex)")
        host.attachSwipePreview(neighborTree, offset: offset)
        swipeNeighborTree = neighborTree
        swipeUpdatesSinceAttach = 0
        return true
    }

    /// Settle the swipe to its target with the SHARED tab-slide motion (same
    /// duration + curve as the keyboard/click cross-slide), so both decelerate
    /// identically. Explicit CABasicAnimations on the current tree layer and the
    /// neighbor preview; `done` runs on the transaction completion (guarded by
    /// `swipeAnimating` so an abort that already cleaned up wins).
    private func startSwipeSettle(from dx: CGFloat, to targetDx: CGFloat,
                                  neighborStart: CGFloat, done: @escaping () -> Void) {
        let current = host.tabs[host.currentIndex].tree
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.swipeAnimating else { return }
            done()
        }
        slideSwipeTree(current, from: dx, to: targetDx)
        slideSwipeTree(swipeNeighborTree, from: neighborStart + dx, to: neighborStart + targetDx)
        CATransaction.commit()
    }

    /// Animate a tree's translation.x from→to with the shared tab-slide motion.
    /// Explicit (plays on the presentation layer regardless of the model); the model is left
    /// at the final value, via `swipeTranslationX` so a layout pass mid-settle cannot drop it.
    private func slideSwipeTree(_ tree: PaneTreeView?, from: CGFloat, to: CGFloat) {
        guard let tree, let layer = tree.layer else { return }
        // Pin the destination FIRST, then add the settle on top: CA applies non-additive
        // animations on a key path in the order they were added, so the settle drives the
        // slide while it runs and the pin takes over the moment it is removed. Reversing
        // these two lines would freeze the tree at its destination with no animation.
        tree.swipeTranslationX = to
        let a = CABasicAnimation(keyPath: "transform.translation.x")
        a.fromValue = from
        a.toValue = to
        a.duration = CompactWindowController.tabSlideDuration
        a.timingFunction = CompactWindowController.tabSlideTiming()
        layer.add(a, forKey: "swipeSettle")
    }

    private func endSwipe() {
        swipeNeighborIndex = -1
        swipeActive = false
        swipeAnimating = false
        host.tabBar.swipePillEnd()   // hand the pill back to the normal selectTab path
    }

    /// Snap an in-flight settle to its final state immediately (used when the next
    /// swipe starts before the previous one's arrival animation finishes). Commits
    /// the pending switch via the normal `selectTab` path — which itself calls
    /// `abortSwipe()` to clear the settle's layers/translation and then advances
    /// `currentIndex` — so the new gesture begins cleanly from the committed tab.
    /// A pending cancel (didn't cross the threshold) just tears the settle down.
    private func finalizeSwipeSettleNow() {
        guard swipeAnimating else { return }
        if swipePendingCommit, swipePendingIndex >= 0, swipePendingIndex < host.tabs.count,
           swipePendingIndex != host.currentIndex {
            commitToTab(swipePendingIndex)
        } else {
            abortSwipe()
        }
    }

    /// Tear down an in-flight swipe before a non-swipe path (keyboard/click switch)
    /// takes over, so nothing is left offset.
    private func abortSwipe() {
        // endSwipe() clears swipeAnimating first, so any in-flight settle's
        // completion block early-returns (its `done` won't fire after this).
        endSwipe()
        detachNeighborPreview()
        if host.currentIndex >= 0, host.currentIndex < host.tabs.count {
            let tree = host.tabs[host.currentIndex].tree
            tree.layer?.removeAnimation(forKey: "swipeSettle")
            setSwipeTranslation(tree, 0)
        }
    }

    /// Take the preview back out of the container — the gesture did not commit to it.
    ///
    /// Never call this for a tree that just BECAME current: `selectTab` clears its preview
    /// flag, so this no-ops on it, but the intent matters more than the guard. Detaching the
    /// committed tab is precisely the thing this whole design exists to stop doing.
    private func detachNeighborPreview() {
        guard let tree = swipeNeighborTree else { return }
        swipeNeighborTree = nil
        SwipeLog.log("swipe.PREVIEW_DETACH", "")
        host.detachSwipePreview(tree)
    }

    /// Make the swipe's preview the real current tab.
    ///
    /// There is nothing to reveal here, which is the point. The tab has been attached and
    /// painting since the gesture began, so by the time this runs its surfaces already hold
    /// presented frames in their final on-screen position; `selectTab` only has to move the
    /// bookkeeping — current index, first responder, window title, tab bar — and drop the
    /// preview flag. Crucially `selectTab` leaves an already-attached tree attached: taking
    /// it out and putting it back would cost it its drawable and reintroduce the blank frame
    /// this design removes.
    private func commitToTab(_ index: Int) {
        SwipeLog.log("commit.BEGIN", "index=\(index) preview=\(swipeNeighborTree != nil)")
        // Hand the preview off to `selectTab` rather than detaching it. If we are committing
        // to some OTHER tab than the one previewed — `selectTab` ignores an out-of-range
        // index, and `reorderTab` can renumber tabs during the 0.42s settle — the preview is
        // not the incoming tab and has to come out, or it would stay pinned over the window.
        let preview = swipeNeighborTree
        swipeNeighborTree = nil
        if let preview, host.tabs.indices.contains(index), host.tabs[index].tree !== preview {
            let previewIndex = host.tabs.firstIndex { $0.tree === preview } ?? -1
            SwipeLog.log("commit.PREVIEW_MISMATCH",
                         "committing index=\(index) but the preview is tab \(previewIndex)")
            host.detachSwipePreview(preview)
        }
        host.selectTab(index, transition: .none)
        SwipeLog.log("commit.DONE", "index=\(host.currentIndex)")
    }

    /// Offset a tree horizontally for the gesture. Goes through `swipeTranslationX` rather than
    /// the backing layer, so the tree re-asserts it after any layout pass — writing the layer
    /// directly is exactly what `animateTabSwitch` warns about above.
    private func setSwipeTranslation(_ tree: PaneTreeView?, _ x: CGFloat) {
        tree?.swipeTranslationX = x
    }
}

/// The tab cross-slide's horizontal translation: a spring for the `slide` style (organic
/// "elastic" settle), or a plain translation (paced by the wrapping group) for crossfade.
private func tabSlideTranslation(style: TabTransitionStyle, from: CGFloat, to: CGFloat) -> CABasicAnimation {
    if style == .slide {
        return CompactWindowController.tabSlideSpring("transform.translation.x", from: from, to: to)
    }
    let a = CABasicAnimation(keyPath: "transform.translation.x")
    a.fromValue = from
    a.toValue = to
    return a
}

/// Remove any in-flight tab cross-slide animations from a layer (used before reusing it for a
/// new switch, or when showing a tree via the instant path).
func clearSwitchAnimations(_ layer: CALayer?) {
    layer?.removeAnimation(forKey: "switchIn")
    layer?.removeAnimation(forKey: "switchOut")
}
