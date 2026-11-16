import AppKit

/// How the active pane is told apart from the others in a split window.
/// Stored as a raw string in UserDefaults (`damson.activePaneIndicator`).
public enum PaneIndicatorMode: String, CaseIterable, Sendable {
    /// Dim the inactive panes with a scrim. No border.
    case dimInactive
    /// An accent-colored border on the active pane. **Default.**
    case accentBorder
    /// A faint border on the active pane, shifted slightly from the background.
    case subtleBorder
    /// Both: dim the inactive panes and outline the active one.
    case dimAndBorder
    /// No indicator.
    case none

    var dimsInactive: Bool { self == .dimInactive || self == .dimAndBorder }
    /// The active pane gets an outline (accent or subtle).
    public var hasBorder: Bool { border != nil }

    enum Border { case accent, subtle }
    var border: Border? {
        switch self {
        case .accentBorder, .dimAndBorder: return .accent
        case .subtleBorder: return .subtle
        case .dimInactive, .none: return nil
        }
    }
}

/// What the dim scrim darkens toward.
public enum PaneDimTint: String, CaseIterable, Sendable {
    /// Black on a dark background, the background color on a light one.
    case auto
    /// Always black (the look before this setting existed).
    case black
    /// The theme background: inactive panes fade toward it rather than toward black,
    /// which reads as "receded" instead of "muddy" on light themes.
    case background
}

/// Every pane-chrome setting, read once from UserDefaults. A missing or out-of-range
/// value falls back to the default, so a defaults domain written by an older build
/// (or edited by hand) can never produce an invisible or oversized indicator.
public struct PaneIndicatorSettings: Equatable {
    public var mode: PaneIndicatorMode = .accentBorder
    /// Scrim opacity on a dimmed pane.
    public var dimStrength: Double = 0.4
    public var dimTint: PaneDimTint = .auto
    /// nil = derive from the system accent color.
    public var accentColor: NSColor?
    /// Active-pane border width, for both border modes.
    public var borderWidth: CGFloat = 1
    /// Dim every pane of a window that isn't the key window.
    public var dimInactiveWindows = false
    /// nil = the system separator color.
    public var dividerColor: NSColor?
    public var dividerWidth: CGFloat = 1

    public static let dimStrengthRange: ClosedRange<Double> = 0.1...0.7
    /// The border and divider are drawn over the pane's edge, so past the default 4 pt
    /// padding they would start covering text.
    public static let lineWidthRange: ClosedRange<CGFloat> = 1...4

    public enum Keys {
        public static let mode = "damson.activePaneIndicator"
        public static let dimStrength = "damson.paneDimStrength"
        public static let dimTint = "damson.paneDimTint"
        /// "#RRGGBB", or empty for the system accent.
        public static let accentColor = "damson.paneAccentColor"
        public static let borderWidth = "damson.paneBorderWidth"
        public static let dimInactiveWindows = "damson.dimInactiveWindows"
        /// "#RRGGBB", or empty for the system separator color.
        public static let dividerColor = "damson.paneDividerColor"
        public static let dividerWidth = "damson.paneDividerWidth"
    }

    public init() {}

    public init(defaults: UserDefaults) {
        if let raw = defaults.string(forKey: Keys.mode), let m = PaneIndicatorMode(rawValue: raw) {
            mode = m
        }
        if let v = defaults.object(forKey: Keys.dimStrength) as? Double, Self.dimStrengthRange.contains(v) {
            dimStrength = v
        }
        if let raw = defaults.string(forKey: Keys.dimTint), let t = PaneDimTint(rawValue: raw) {
            dimTint = t
        }
        accentColor = defaults.string(forKey: Keys.accentColor).flatMap { NSColor(hexString: $0) }
        if let v = defaults.object(forKey: Keys.borderWidth) as? Double,
           Self.lineWidthRange.contains(CGFloat(v)) {
            borderWidth = CGFloat(v)
        }
        dimInactiveWindows = defaults.bool(forKey: Keys.dimInactiveWindows)
        dividerColor = defaults.string(forKey: Keys.dividerColor).flatMap { NSColor(hexString: $0) }
        if let v = defaults.object(forKey: Keys.dividerWidth) as? Double,
           Self.lineWidthRange.contains(CGFloat(v)) {
            dividerWidth = CGFloat(v)
        }
    }

    public static var current: PaneIndicatorSettings { PaneIndicatorSettings(defaults: .standard) }
}

/// The resolved look of one pane's overlays. Opacities are the layers' resting values;
/// the host animates toward them.
public struct PaneIndicatorAppearance: Equatable {
    /// Whether the scrim layer takes part at all (hidden otherwise, so it costs nothing).
    public var dimEnabled: Bool
    public var dimColor: NSColor
    public var dimOpacity: Float
    /// nil when the mode has no border. Set on inactive panes too (at opacity 0) so the
    /// border can fade out when focus leaves.
    public var borderColor: NSColor?
    public var borderWidth: CGFloat
    public var borderOpacity: Float
}

public enum PaneIndicatorStyle {
    /// - Parameters:
    ///   - multiPane: the window is split. A lone pane needs no focus hint, so it never gets
    ///     a border or a focus dim — only the inactive-window dim, which is about the window.
    ///   - windowIsKey: the pane's window is the key window.
    ///   - background: the pane's theme background.
    ///   - systemAccent: `NSColor.controlAccentColor`, passed in so this stays testable.
    public static func resolve(_ s: PaneIndicatorSettings, isActive: Bool, multiPane: Bool,
                               windowIsKey: Bool, background: NSColor,
                               systemAccent: NSColor) -> PaneIndicatorAppearance {
        let windowDim = s.dimInactiveWindows && !windowIsKey
        let focusDim = s.mode.dimsInactive && !isActive && multiPane
        let strength = Float(s.dimStrength)

        var borderColor: NSColor?
        switch s.mode.border {
        case .accent: borderColor = s.accentColor ?? mutedAccent(systemAccent)
        case .subtle: borderColor = subtleBorder(background)
        case nil: borderColor = nil
        }

        return PaneIndicatorAppearance(
            dimEnabled: s.mode.dimsInactive || s.dimInactiveWindows,
            dimColor: dimColor(s.dimTint, background: background),
            dimOpacity: (windowDim || focusDim) ? strength : 0,
            borderColor: borderColor,
            borderWidth: borderColor == nil ? 0 : s.borderWidth,
            borderOpacity: (borderColor != nil && isActive && multiPane) ? 1 : 0)
    }

    public static func dividerColor(_ s: PaneIndicatorSettings) -> NSColor {
        s.dividerColor ?? .separatorColor
    }

    static func dimColor(_ tint: PaneDimTint, background: NSColor) -> NSColor {
        let bg = background.usingColorSpace(.sRGB) ?? .black
        switch tint {
        case .black: return .black
        case .background: return bg.withAlphaComponent(1)
        case .auto: return luminance(bg) < 0.5 ? .black : bg.withAlphaComponent(1)
        }
    }

    /// The raw system accent is too vivid as a 1px outline, so blend it toward black and
    /// drop the alpha a little: still clearly the accent hue, just calmer.
    static func mutedAccent(_ accent: NSColor) -> NSColor {
        let a = accent.usingColorSpace(.sRGB) ?? accent
        return (a.blended(withFraction: 0.4, of: .black) ?? a).withAlphaComponent(0.8)
    }

    /// The background nudged 25% toward white (dark theme) or black (light theme).
    static func subtleBorder(_ background: NSColor) -> NSColor {
        let bg = background.usingColorSpace(.sRGB) ?? .black
        let target: CGFloat = luminance(bg) < 0.5 ? 1 : 0
        func mix(_ c: CGFloat) -> CGFloat { c + (target - c) * 0.25 }
        return NSColor(srgbRed: mix(bg.redComponent), green: mix(bg.greenComponent),
                       blue: mix(bg.blueComponent), alpha: 1)
    }

    static func luminance(_ c: NSColor) -> CGFloat {
        0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    }
}
