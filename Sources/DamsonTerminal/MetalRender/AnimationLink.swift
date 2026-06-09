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

    init(view: NSView) { self.view = view }

    var isRunning: Bool { link != nil }

    /// Start (or keep running) the link. `tick(dt)` is invoked once per frame on the
    /// main thread and returns `true` when the animation is done. Returns `false`
    /// when no display link is available (macOS < 14) so the caller can jump instead.
    @discardableResult
    func start(_ tick: @escaping (_ dt: CFTimeInterval) -> Bool) -> Bool {
        guard #available(macOS 14.0, *), let view else { return false }
        onTick = tick
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
        }
        return true
    }

    func stop() {
        if #available(macOS 14.0, *) { (link as? CADisplayLink)?.invalidate() }
        link = nil
        onTick = nil
        lastTimestamp = 0
    }

    @available(macOS 14.0, *)
    @objc private func displayLinkFired(_ link: CADisplayLink) {
        guard let view, let window = view.window,
              window.occlusionState.contains(.visible) else {
            stop()
            return
        }
        let now = link.timestamp
        let dt = lastTimestamp == 0 ? (1.0 / 60.0) : max(0, now - lastTimestamp)
        lastTimestamp = now
        if onTick?(dt) ?? true { stop() }
    }
}
