import AppKit

/// Motion helper shared across tab/pane creation, switching, closing, and splitting.
/// Stateless static members only — no instances.
///
/// Location note: the design spec said `Sources/damson/Motion.swift`, but the damson
/// executable target can't be unit-tested (Package.swift's test target depends only on the
/// DamsonTerminal/DamsonControl libraries). Since the spec's Testing section requires the
/// `enabled` truth table and `snapshot(of:)` to be covered automatically, this lives in the
/// testable DamsonTerminal library instead. The call-site code is unchanged
/// (callers already `import DamsonTerminal`).
public enum Motion {

    /// Duration of all lifecycle animations. 0.16s — deliberately fast, similar to the existing
    /// scroll snap / bell flash (0.18s).
    public static let duration: TimeInterval = 0.16

    /// Timing curve for all animations. easeOut — the same curve as scroll snap / bell flash.
    public static var timing: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }

    /// Master gate. Read LIVE at every animation entry point (never cached).
    /// True only when the user toggle is on AND macOS Reduce Motion is off.
    /// Reduce Motion always takes precedence (blocking animation) regardless of the toggle.
    /// Defaults to true (animation ON) when the key is absent.
    public static var enabled: Bool {
        let toggle = (UserDefaults.standard.object(forKey: "damson.animations") as? Bool) ?? true
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        return isEnabled(toggledOn: toggle, reduceMotionEnabled: reduceMotion)
    }

    /// Pure gate function — takes only explicit parameters and does no global I/O, so it's easy to unit-test.
    /// `enabled` reads UserDefaults/NSWorkspace and delegates to this function.
    /// Test-only seam: do not call directly from production code (use `enabled` instead).
    static func isEnabled(toggledOn: Bool, reduceMotionEnabled: Bool) -> Bool {
        toggledOn && !reduceMotionEnabled
    }

    /// Snapshots the view's current rendering to a bitmap. Used for content that is disappearing
    /// or being torn down (closing tabs/panes, the outgoing tab during a transition).
    /// Returns nil for a zero-sized view or on caching failure — callers must fall back to the
    /// instant path when nil.
    ///
    /// `cacheDisplay` captures only the regular layer tree, not `CAMetalLayer` framebuffers
    /// (terminal text/colors would come out blank), so we composite the current Metal frame of each
    /// descendant `DamsonSurfaceView` at its position over the base capture.
    public static func snapshot(of view: NSView) -> NSImage? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)

        let surfaces = terminalSurfaces(in: view)
        guard !surfaces.isEmpty else { return image }
        image.lockFocus()
        defer { image.unlockFocus() }
        for surface in surfaces {
            guard let metalImage = surface.captureMetalImage() else { continue }
            // Convert the surface's position to view coordinates. The lockFocus context has a
            // bottom-left origin, so if the view is flipped (top-left) we flip y to match.
            var rect = surface.convert(surface.bounds, to: view)
            if view.isFlipped { rect.origin.y = bounds.height - rect.maxY }
            metalImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        return image
    }

    /// All `DamsonSurfaceView`s under `view` (including itself). Does not descend inside a surface.
    private static func terminalSurfaces(in view: NSView) -> [DamsonSurfaceView] {
        if let surface = view as? DamsonSurfaceView { return [surface] }
        return view.subviews.flatMap { terminalSurfaces(in: $0) }
    }

    /// Adds a self-contained image-based CALayer at `frame` (host coordinate space) on top of
    /// `host.layer` and returns that layer. The caller animates it and then removes it.
    /// `host` must be layer-backed (all pane containers already are).
    public static func overlay(image: NSImage, frame: NSRect, in host: NSView) -> CALayer {
        host.wantsLayer = true
        let layer = CALayer()
        layer.frame = frame
        layer.contents = image
        layer.contentsGravity = .resize
        // Keep it crisp on Retina.
        layer.contentsScale = host.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
        layer.zPosition = 100
        host.layer?.addSublayer(layer)
        return layer
    }

    /// Runs a single 0.16s / easeOut NSAnimationContext group.
    /// It turns on `allowsImplicitAnimation = true`, so assigning layer properties directly inside
    /// `body` (including on backing layers) animates implicitly — tab creation/pane closing rely on
    /// this contract (without it they snap). Works the same for `.animator()` changes.
    /// `done` is called on completion (for overlay removal / state restoration).
    public static func run(duration: TimeInterval = Motion.duration,
                           _ body: () -> Void, done: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = timing
            ctx.allowsImplicitAnimation = true
            body()
        }, completionHandler: done)
    }
}
