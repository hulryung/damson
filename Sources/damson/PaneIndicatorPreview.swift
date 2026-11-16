import AppKit
import DamsonTerminal
import SwiftUI

/// Two-pane mock for Settings: the left pane is active, the right one inactive. It draws
/// with the same `PaneIndicatorStyle.resolve` the real panes use, so what it shows is what
/// a split window will look like — not an approximation that can drift from it.
struct PaneIndicatorPreview: View {
    let settings: PaneIndicatorSettings
    let theme: DamsonTheme
    let windowIsKey: Bool

    var body: some View {
        HStack(spacing: 0) {
            pane(active: true, lines: [0.7, 0.45, 0.85, 0.3])
            pane(active: false, lines: [0.55, 0.8, 0.4, 0.6])
        }
        // The divider overlays the boundary, as in the app.
        .overlay(
            Rectangle()
                .fill(Color(nsColor: PaneIndicatorStyle.dividerColor(settings)))
                .frame(width: settings.dividerWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of an active and an inactive pane")
    }

    private func pane(active: Bool, lines: [CGFloat]) -> some View {
        let look = PaneIndicatorStyle.resolve(settings, isActive: active, multiPane: true,
                                              windowIsKey: windowIsKey,
                                              background: theme.background,
                                              systemAccent: .controlAccentColor)
        return ZStack(alignment: .topLeading) {
            Color(nsColor: theme.background)
            GeometryReader { geo in
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, w in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(nsColor: i == 0 ? theme.ansi[2] : theme.foreground))
                            .opacity(i == 0 ? 0.9 : 0.6)
                            .frame(width: (geo.size.width - 24) * w, height: 6)
                    }
                }
                .padding(12)
            }
            if look.dimEnabled {
                Color(nsColor: look.dimColor).opacity(Double(look.dimOpacity))
            }
            if let border = look.borderColor {
                Rectangle()
                    .strokeBorder(Color(nsColor: border), lineWidth: look.borderWidth)
                    .opacity(Double(look.borderOpacity))
            }
        }
    }
}
