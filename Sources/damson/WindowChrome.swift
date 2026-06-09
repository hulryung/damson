import AppKit

/// Applies window transparency/blur. When background opacity < 1, the window is made
/// non-opaque (clear) so the terminal's transparent background shows through behind the
/// window; when blur is on, a behind-window `NSVisualEffectView` is placed at the very
/// back of contentView to produce frosted glass.
///
/// This is a per-window setting separate from the renderer (background alpha), so the
/// window controller calls it directly.
enum WindowChrome {
    private static let backdropID = NSUserInterfaceItemIdentifier("damson.blurBackdrop")

    /// Reads the current settings from UserDefaults and applies them.
    static func applyFromDefaults(to window: NSWindow) {
        let d = UserDefaults.standard
        let opacity = (d.object(forKey: "damson.backgroundOpacity") as? Double) ?? 1.0
        let blur = d.bool(forKey: "damson.backgroundBlur")
        apply(to: window, opacity: CGFloat(opacity), blur: blur)
    }

    static func apply(to window: NSWindow, opacity: CGFloat, blur: Bool) {
        let translucent = opacity < 1.0
        window.isOpaque = !translucent
        window.backgroundColor = translucent ? .clear : .windowBackgroundColor

        guard let content = window.contentView else { return }
        let existing = content.subviews.first { $0.identifier == backdropID } as? NSVisualEffectView

        if translucent && blur {
            let v = existing ?? makeBackdrop(in: content)
            v.isHidden = false
        } else {
            existing?.removeFromSuperview()
        }
    }

    private static func makeBackdrop(in content: NSView) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.identifier = backdropID
        v.blendingMode = .behindWindow
        v.state = .active
        v.material = .underWindowBackground
        v.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(v, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            v.topAnchor.constraint(equalTo: content.topAnchor),
            v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        return v
    }
}
