import AppKit
import Foundation

/// A trampoline that relaunches itself inside a `.app` bundle when run as a raw binary.
///
/// To cleanly fix the Korean IME first-jamo race, LaunchServices must have our process
/// registered as a "GUI app," and in practice only launching via a `.app` bundle guarantees that.
/// For the full background, see the Rust halite doc `~/dev/halite/docs/KOREAN-IME.md`.
///
/// Skipped if the debugging flag `DAMSON_NO_TRAMPOLINE=1` is set.
enum AppBundleTrampoline {
    /// damson's bundle id / name / path — fixed so LaunchServices reliably picks up the
    /// GUI-app registration under this identifier.
    private static let bundleID = "app.damson.terminal"
    private static let bundleName = "damson"
    private static let appDirName = "Damson.app"

    static func relaunchInAppBundleIfNeeded() {
        if ProcessInfo.processInfo.environment["DAMSON_NO_TRAMPOLINE"] != nil {
            return
        }
        guard let executablePath = Bundle.main.executablePath else { return }
        if isInsideAppBundle(executablePath: executablePath) {
            return
        }

        let bundleURL = cachedBundleURL()
        let executableURL = URL(fileURLWithPath: executablePath)
        do {
            try materializeBundle(at: bundleURL, withExecutableFrom: executableURL)
        } catch {
            NSLog("damson trampoline: failed to materialize bundle: %@", error.localizedDescription)
            return // degraded mode
        }

        do {
            try relaunch(bundleURL: bundleURL)
            exit(0)
        } catch {
            NSLog("damson trampoline: failed to relaunch: %@", error.localizedDescription)
            return
        }
    }

    // MARK: - Internals

    private static func isInsideAppBundle(executablePath: String) -> Bool {
        executablePath.contains(".app/Contents/MacOS/")
    }

    private static func cachedBundleURL() -> URL {
        let fm = FileManager.default
        let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
        return cachesDir.appendingPathComponent("damson/\(appDirName)")
    }

    private static func materializeBundle(at bundleURL: URL, withExecutableFrom srcURL: URL) throws {
        let fm = FileManager.default
        let contentsDir = bundleURL.appendingPathComponent("Contents")
        let macosDir = contentsDir.appendingPathComponent("MacOS")
        let plistURL = contentsDir.appendingPathComponent("Info.plist")
        let dstBinaryURL = macosDir.appendingPathComponent(bundleName)

        try fm.createDirectory(at: macosDir, withIntermediateDirectories: true)
        try infoPlist().write(to: plistURL, atomically: true, encoding: .utf8)

        // Overwrite every time — so a freshly built binary takes effect immediately.
        // Same policy as the Rust halite trampoline.
        if fm.fileExists(atPath: dstBinaryURL.path) {
            try fm.removeItem(at: dstBinaryURL)
        }
        try fm.copyItem(at: srcURL, to: dstBinaryURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dstBinaryURL.path)

        // The binary loads sibling Frameworks via the RPATH `@loader_path` — after the
        // Sparkle integration, Sparkle.framework must be a sibling for dyld to load it.
        // Copy the original binary's sibling .frameworks into the cached bundle's MacOS/ as well.
        let srcDir = srcURL.deletingLastPathComponent()
        if let entries = try? fm.contentsOfDirectory(at: srcDir, includingPropertiesForKeys: nil) {
            for entry in entries where entry.pathExtension == "framework" {
                let dst = macosDir.appendingPathComponent(entry.lastPathComponent)
                if fm.fileExists(atPath: dst.path) {
                    try? fm.removeItem(at: dst)
                }
                try? fm.copyItem(at: entry, to: dst)
            }
        }

        // Icon — SwiftPM exposes it as Bundle.module's Damson.icns. Copy it to
        // Contents/Resources/Damson.icns to pair with Info.plist's CFBundleIconFile=Damson.
        // If it's missing, ignore (generic icon in the dock).
        if let iconURL = Bundle.module.url(forResource: "Damson", withExtension: "icns") {
            let resourcesDir = contentsDir.appendingPathComponent("Resources")
            try? fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
            let dstIcon = resourcesDir.appendingPathComponent("Damson.icns")
            if fm.fileExists(atPath: dstIcon.path) {
                try? fm.removeItem(at: dstIcon)
            }
            try? fm.copyItem(at: iconURL, to: dstIcon)
        }
    }

    private static func infoPlist() -> String {
        // Modeled on the Rust halite plist — minimal fields only.
        // So that unnecessary keys don't make LaunchServices registration finicky.
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key>
            <string>\(bundleName)</string>
            <key>CFBundleIdentifier</key>
            <string>\(bundleID)</string>
            <key>CFBundleName</key>
            <string>\(bundleName)</string>
            <key>CFBundleVersion</key>
            <string>0.0.1</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>CFBundleIconFile</key>
            <string>Damson</string>
            <key>NSHighResolutionCapable</key>
            <true/>
        </dict>
        </plist>
        """
    }

    private static func relaunch(bundleURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -F : fresh launch (no saved-state restore). Rust halite also uses -F.
        // -n (new instance) is intentionally avoided since it can bypass the LaunchServices registration cache.
        process.arguments = ["-F", bundleURL.path]
        try process.run()
        // open(1) dispatches to LaunchServices and exits right away. No wait needed.
    }
}
