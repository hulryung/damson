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

/// The full MIT license text (kept in sync with the repo's /LICENSE file).
let damsonLicenseText = """
MIT License

Copyright (c) 2026 damson contributors

Permission is hereby granted, free of charge, to any person obtaining a copy \
of this software and associated documentation files (the "Software"), to deal \
in the Software without restriction, including without limitation the rights \
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
copies of the Software, and to permit persons to whom the Software is \
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all \
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
SOFTWARE.
"""

/// Custom About window — Damson branding, version, and links. Shown from the app menu's
/// "About Damson" item (in place of the standard AppKit about panel).
struct DamsonAboutView: View {
    @State private var showingLicense = false

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

            VStack(spacing: 6) {
                Button("License") { showingLicense = true }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                if !copyright.isEmpty {
                    Text(copyright)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(.top, 30)
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
        .frame(width: 360, height: 360)
        .sheet(isPresented: $showingLicense) {
            LicenseSheet(text: damsonLicenseText) { showingLicense = false }
        }
    }
}

/// Scrollable, selectable full-license text presented as a sheet from the About window.
private struct LicenseSheet: View {
    let text: String
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Damson License")
                .font(.system(size: 13, weight: .semibold))
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            HStack {
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460, height: 380)
    }
}
