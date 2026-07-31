import AppKit
import QuartzCore

/// Transient display link driving programmatic scroll eases (snap-to-cursor).
///
/// macOS 14+ only, via `NSView.displayLink(target:selector:)`. On macOS 13
/// `start` returns `false` and the backend falls back to an instant jump — this
/// deliberately avoids the CVDisplayLink-hop-to-main path (see
/// docs/METAL-RENDERER-PLAN, increment B). The link is created on ease begin and
/// invalidated the instant the ease settles or the surface stops being visible
/// (occluded / miniaturized / off-window), so a settling animation never spins the
/// GPU on something nobody can see.
final class AnimationLink {
    private weak var view: NSView?
    private var link: AnyObject?            // CADisplayLink (macOS 14+)
    private var onTick: ((CFTimeInterval) -> Bool)?
    private var lastTimestamp: CFTimeInterval = 0
    /// Wall clock of the last callback (and of creation, so a link that never fires at all is
    /// still measurable). Zero when there is no link. See `hasStalled`.
    private var lastFiredAt: CFTimeInterval = 0

    /// A link that has not called back for this long, while still claiming to run, is treated
    /// as dead. Two orders of magnitude above a real frame interval (8.3ms at 120Hz), so a
    /// main thread briefly blocked by a big render cannot trip it, yet short enough that the
    /// very first scroll event after a display change rebuilds and works on that same gesture.
    private static let stallTimeout: CFTimeInterval = 0.25

    init(view: NSView) { self.view = view }

    /// Whether a live link is delivering frames.
    ///
    /// NOT simply "a link object exists": `NSView.displayLink(target:selector:)` documents that
    /// the callback "will not be invoked" while the view is hidden or on no display, and it
    /// goes silent WITHOUT invalidating itself. Reconfiguring the displays — plugging in an
    /// external monitor — puts a window through exactly that state. The link then never fires
    /// again, so `stop()` never runs and the object stays non-nil forever; a caller gating on
    /// "is it running" would skip restarting it for the life of that view. That is how one pane
    /// would stop scrolling for good after connecting a monitor, while a newly opened pane
    /// (with a fresh link) was fine.
    var isRunning: Bool { link != nil && !hasStalled }

    /// True when a link exists but has gone quiet past `stallTimeout`.
    private var hasStalled: Bool {
        guard link != nil else { return false }
        return CACurrentMediaTime() - lastFiredAt > Self.stallTimeout
    }

    /// Start (or keep running) the link. `tick(dt)` is invoked once per frame on the
    /// main thread and returns `true` when the animation is done. Returns `false`
    /// when no display link is available (macOS < 14) so the caller can jump instead.
    @discardableResult
    func start(_ tick: @escaping (_ dt: CFTimeInterval) -> Bool) -> Bool {
        guard #available(macOS 14.0, *), let view else { return false }
        onTick = tick
        // Rebuild rather than adopt a link that has gone silent. This is also what refreshes
        // `preferredFrameRateRange` below for the display the view is on NOW — the old link
        // carried the refresh rate of whatever screen it was created against.
        if hasStalled { stop(); onTick = tick }
        if link == nil {
            let l = view.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
            // Prevent the link from running at the default 60 on ProMotion (120Hz) —
            // declare the screen's maximum refresh rate as the preferred frame rate.
            // (Unset, it may be capped to 60 depending on the display.)
            let maxFPS = Float(view.window?.screen?.maximumFramesPerSecond ?? 60)
            if maxFPS > 60 {
                l.preferredFrameRateRange = CAFrameRateRange(
                    minimum: 60, maximum: maxFPS, preferred: maxFPS)
            }
            l.add(to: .main, forMode: .common)
            link = l
            lastTimestamp = 0
            lastFiredAt = CACurrentMediaTime()
        }
        return true
    }

    func stop() {
        if #available(macOS 14.0, *) { (link as? CADisplayLink)?.invalidate() }
        link = nil
        onTick = nil
        lastTimestamp = 0
        lastFiredAt = 0
    }

    @available(macOS 14.0, *)
    @objc private func displayLinkFired(_ link: CADisplayLink) {
        guard let view, let window = view.window,
              window.occlusionState.contains(.visible) else {
            stop()
            return
        }
        lastFiredAt = CACurrentMediaTime()
        let now = link.timestamp
        let dt = lastTimestamp == 0 ? (1.0 / 60.0) : max(0, now - lastTimestamp)
        lastTimestamp = now
        if onTick?(dt) ?? true { stop() }
    }
}
