import AppKit

/// How to indicate the active (focused) pane among split panes.
/// Stored as a raw string in UserDefaults("damson.activePaneIndicator").
/// Read by PaneLeafWrapper when it draws.
enum ActivePaneIndicator: String, CaseIterable {
    /// Distinguish the active pane by darkening only the inactive panes with a scrim. No border.
    /// With a single pane there are no inactive panes, so nothing is drawn. **Default.**
    case dimInactive

    /// An accent-colored (system accent) border on the active pane.
    case accentBorder

    /// A subtle border on the active pane, shifted slightly from the background color.
    case subtleBorder

    /// No indicator.
    case none

    var displayName: String {
        switch self {
        case .dimInactive: return "Dim inactive (비활성 흐리게)"
        case .accentBorder: return "Accent border (강조 테두리)"
        case .subtleBorder: return "Subtle border (은은한 테두리)"
        case .none: return "None (표시 없음)"
        }
    }

    static var current: ActivePaneIndicator {
        if let raw = UserDefaults.standard.string(forKey: "damson.activePaneIndicator"),
           let v = ActivePaneIndicator(rawValue: raw) {
            return v
        }
        return .dimInactive
    }
}
