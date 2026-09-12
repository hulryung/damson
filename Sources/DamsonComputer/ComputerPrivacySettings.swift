import AppKit

/// Shared destinations for the Damson panel and the helper's menu. These only
/// navigate to System Settings; macOS still requires the user to grant access.
public enum ComputerPrivacySettings: String {
    case accessibility = "Privacy_Accessibility"
    case screenRecording = "Privacy_ScreenCapture"

    @MainActor
    @discardableResult
    public func open() -> Bool {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)"),
           NSWorkspace.shared.open(url) { return true }
        // Keep settings reachable if a future macOS version changes its deep links.
        guard let settings = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else {
            return false
        }
        return NSWorkspace.shared.open(settings)
    }
}
