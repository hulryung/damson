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
/// Ownership: `host` is `unowned` because the controller owns the coordinator through a
/// single strong `lazy var` and nothing else stores it, so the two die together; a completion
/// block that outlives the controller finds `self` (the coordinator) already nil and returns
/// before it can touch `host`. Corollary rule for the animation bodies below: an escaping
/// closure must never capture a `host` local — reach the controller only as `self.host`
/// under an existing `if let self`, or a 0.42s CA animation would keep the window controller
/// (and its PTYs) alive past window close.
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
    private var swipeNeighborLayer: CALayer?   // neighbor shown as a snapshot (no hit-test)
    private var swipeNeighborIndex = -1
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

    /// Live finger-tracking. The current tab stays a live view (it remains the sole
    /// scroll/event target — its layer transform is visual-only and doesn't move
    /// its hit-test frame), while the neighbor is shown as a **snapshot layer**
    /// (a CALayer, so it never intercepts events or steals first responder the way
    /// a live sibling view would). Both follow the accumulated translation.
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
            let goPrev = dx > 0                 // swipe fingers right → previous tab
            let neighborIndex = goPrev ? (host.currentIndex - 1 + host.tabs.count) % host.tabs.count
                                       : (host.currentIndex + 1) % host.tabs.count
            guard neighborIndex != host.currentIndex else { return }
            swipeActive = true
            swipeFromRight = !goPrev            // next tab enters from the right
            swipeNeighborIndex = neighborIndex

            // Snapshot the neighbor (detached). Size it to the content area first so
            // its Metal surfaces lay out and render at the right resolution.
            let neighborTree = host.tabs[neighborIndex].tree
            if neighborTree.superview == nil {
                neighborTree.frame = host.contentContainer.bounds
                neighborTree.layoutSubtreeIfNeeded()
            }
            // Force each leaf to render its grid so the snapshot has real content: an
            // offscreen capture reads the backend's `lastGrid`, which is nil for a tab
            // that has never rendered (freshly restored / never shown) — in that case
            // the snapshot falls back to the bare view background (a dark, theme-less
            // blank). repaintAllLeaves populates lastGrid so the capture is real.
            neighborTree.repaintAllLeaves()
            if let img = Motion.snapshot(of: neighborTree) {
                swipeNeighborLayer = Motion.overlay(image: img, frame: host.contentContainer.bounds,
                                                    in: host.contentContainer)
            }
        }

        let neighborStart = swipeFromRight ? width : -width
        setSwipeTranslation(host.tabs[host.currentIndex].tree.layer, dx)
        setSwipeTranslation(swipeNeighborLayer, neighborStart + dx)

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
                self.setSwipeTranslation(self.host.tabs[self.host.currentIndex].tree.layer, 0)
                self.endSwipe()
                // Real switch (instant) — same path as keyboard nav, so first
                // responder, title, and tab-bar selection are all correct. The live
                // neighbor lands at center under the snapshot; then drop the snapshot.
                self.host.selectTab(neighborIndex, transition: .none)
                self.swipeNeighborLayer?.removeFromSuperlayer()
                self.swipeNeighborLayer = nil
            } else {
                self.swipeNeighborLayer?.removeFromSuperlayer()
                self.swipeNeighborLayer = nil
                self.setSwipeTranslation(self.host.tabs[self.host.currentIndex].tree.layer, 0)
                self.endSwipe()
            }
        }
    }

    /// Settle the swipe to its target with the SHARED tab-slide motion (same
    /// duration + curve as the keyboard/click cross-slide), so both decelerate
    /// identically. Explicit CABasicAnimations on the current tree layer and the
    /// neighbor snapshot; `done` runs on the transaction completion (guarded by
    /// `swipeAnimating` so an abort that already cleaned up wins).
    private func startSwipeSettle(from dx: CGFloat, to targetDx: CGFloat,
                                  neighborStart: CGFloat, done: @escaping () -> Void) {
        let currentLayer = host.tabs[host.currentIndex].tree.layer
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.swipeAnimating else { return }
            done()
        }
        slideSwipeLayer(currentLayer, from: dx, to: targetDx)
        slideSwipeLayer(swipeNeighborLayer, from: neighborStart + dx, to: neighborStart + targetDx)
        CATransaction.commit()
    }

    /// Animate a layer's translation.x from→to with the shared tab-slide motion.
    /// Explicit (plays on the presentation layer regardless of the model); the
    /// model is left at the final value.
    private func slideSwipeLayer(_ layer: CALayer?, from: CGFloat, to: CGFloat) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeTranslation(to, 0, 0)
        CATransaction.commit()
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
            // `selectTab` attaches the committed tab as a LIVE tree, but its Metal layer
            // presents its first on-screen frame a beat late — so a chained swipe that
            // immediately slides that tree would flash a blank (black) screen. The
            // neighbor snapshot we're holding is a valid image of exactly this tab (it
            // was just on screen), so reuse it as a cover parented to the tree's layer:
            // it rides the next swipe's slide (child of the transformed layer) and hides
            // the black frame until the live content paints, then removes itself.
            let cover = swipeNeighborLayer
            swipeNeighborLayer = nil   // keep it from being torn down by selectTab → abortSwipe
            host.selectTab(swipePendingIndex, transition: .none)
            if let cover, let treeLayer = host.tabs[host.currentIndex].tree.layer {
                cover.removeFromSuperlayer()
                cover.removeAllAnimations()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                cover.transform = CATransform3DIdentity
                cover.frame = treeLayer.bounds
                treeLayer.addSublayer(cover)
                CATransaction.commit()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak cover] in
                    cover?.removeFromSuperlayer()
                }
            }
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
        swipeNeighborLayer?.removeAnimation(forKey: "swipeSettle")
        swipeNeighborLayer?.removeFromSuperlayer()
        swipeNeighborLayer = nil
        if host.currentIndex >= 0, host.currentIndex < host.tabs.count {
            let layer = host.tabs[host.currentIndex].tree.layer
            layer?.removeAnimation(forKey: "swipeSettle")
            setSwipeTranslation(layer, 0)
        }
    }

    private func setSwipeTranslation(_ layer: CALayer?, _ x: CGFloat) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeTranslation(x, 0, 0)
        CATransaction.commit()
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
