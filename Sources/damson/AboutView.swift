import AppKit
import SwiftUI

/// Build the custom branded About window hosting `DamsonAboutView`. Fixed-size, transparent
/// titlebar, movable by background.
func makeAboutWindow() -> NSWindow {
    let host = NSHostingController(rootView: DamsonAboutView())
    let win = NSWindow(contentViewController: host)
    win.title = "About Damson"
    win.styleMask = [.titled, .closable, .fullSizeContentView]
    win.titlebarAppearsTransparent = true
    win.isMovableByWindowBackground = true
    win.setContentSize(NSSize(width: 360, height: 340))
    win.isReleasedWhenClosed = false
    win.center()
    return win
}

/// Custom About window — Damson branding, version, and links. Shown from the app menu's
/// "About Damson" item (in place of the standard AppKit about panel).
struct DamsonAboutView: View {
    private var appIcon: NSImage { NSApp.applicationIconImage ?? NSImage() }

    private func info(_ key: String) -> String {
        Bundle.main.infoDictionary?[key] as? String ?? "—"
    }
    private var version: String { info("CFBundleShortVersionString") }
    private var build: String { info("CFBundleVersion") }
    private var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            VStack(spacing: 5) {
                Text("Damson")
                    .font(.system(size: 28, weight: .semibold))
                Text("The terminal built only for macOS.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text("Version \(version) (\(build))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack(spacing: 18) {
                Link("Website", destination: URL(string: "https://damson.app")!)
                Link("GitHub", destination: URL(string: "https://github.com/hulryung/damson")!)
                Link("Releases", destination: URL(string: "https://github.com/hulryung/damson/releases/latest")!)
            }
            .font(.system(size: 12))

            Spacer(minLength: 0)

            if !copyright.isEmpty {
                Text(copyright)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 30)
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
        .frame(width: 360, height: 340)
    }
}
