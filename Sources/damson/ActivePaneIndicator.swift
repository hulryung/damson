import AppKit
import DamsonTerminal

/// How to indicate the active (focused) pane among split panes. The mode and the rest of
/// the pane-chrome settings, plus how they resolve to colors, live in DamsonTerminal's
/// `PaneIndicatorStyle` so they can be tested; this file only adds the Settings labels.
typealias ActivePaneIndicator = PaneIndicatorMode

extension PaneIndicatorMode {
    var displayName: String {
        switch self {
        case .dimInactive: return "Dim inactive (dim the inactive pane)"
        case .accentBorder: return "Accent border (highlighted border)"
        case .subtleBorder: return "Subtle border (faint border)"
        case .dimAndBorder: return "Dim + accent border (both)"
        case .none: return "None (no indicator)"
        }
    }
}

extension PaneDimTint {
    var displayName: String {
        switch self {
        case .auto: return "Automatic (black on dark, background on light)"
        case .black: return "Black"
        case .background: return "Theme background"
        }
    }
}
