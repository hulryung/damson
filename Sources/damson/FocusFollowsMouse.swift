import Foundation

/// "Focus follows mouse" for split panes — the pane the cursor hovers over becomes active without a click.
/// Stored as a Bool in UserDefaults("damson.focusFollowsMouse"). **On by default.**
/// PaneLeafWrapper's mouseEntered reads this directly on each hover (no hot reload needed).
enum FocusFollowsMouse {
    static var enabled: Bool {
        // bool(forKey:) returns false when unset, which can't express default-on → check existence via object.
        (UserDefaults.standard.object(forKey: "damson.focusFollowsMouse") as? Bool) ?? true
    }
}
