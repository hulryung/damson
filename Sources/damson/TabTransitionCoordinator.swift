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
