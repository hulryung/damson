import SwiftUI
import DamsonTerminal
import DamsonOrchestrator

/// SwiftUI colors derived from a terminal theme, so the app chrome (backgrounds, tiles)
/// tracks the selected theme alongside the terminal surfaces.
extension DamsonTheme {
    var swiftBackground: Color { Color(nsColor: background) }
    var swiftForeground: Color { Color(nsColor: foreground) }
    /// A slightly raised surface color for headers/cards, blended toward the foreground.
    var swiftElevated: Color {
        Color(nsColor: background.blended(withFraction: 0.06, of: foreground) ?? background)
    }
    var isDark: Bool {
        var white: CGFloat = 0
        (background.usingColorSpace(.deviceRGB) ?? background).getWhite(&white, alpha: nil)
        return white < 0.5
    }
}

/// UI presentation for an agent runtime state — color + short label, used by the sidebar
/// rows and tile headers. The glyph itself lives on `AgentRuntimeState.glyph`.
extension AgentRuntimeState {
    var color: Color {
        switch self {
        case .starting: return .secondary
        case .idle: return .green
        case .working: return .blue
        case .awaitingApproval: return .orange
        case .awaitingInput: return .yellow
        case .finished: return .gray
        case .errored: return .red
        }
    }

    var label: String {
        switch self {
        case .starting: return "Starting"
        case .idle: return "Idle"
        case .working: return "Working"
        case .awaitingApproval: return "Needs approval"
        case .awaitingInput: return "Needs input"
        case .finished: return "Done"
        case .errored: return "Error"
        }
    }

    /// Machine-friendly token for the control CLI (list-agents `state`).
    var cliToken: String {
        switch self {
        case .starting: return "starting"
        case .idle: return "idle"
        case .working: return "working"
        case .awaitingApproval: return "awaiting-approval"
        case .awaitingInput: return "awaiting-input"
        case .finished(let c): return "finished(\(c))"
        case .errored(let m): return "errored(\(m))"
        }
    }
}
