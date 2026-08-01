import Foundation

/// "Even splits" — panes sharing a row (or column) keep the same size as that row gains and
/// loses members. Adding one (⌘D/⌘⇧D) re-spaces the row instead of merely halving the active
/// pane (½ · ¼ · ¼ on the third split); removing one (⌘W, or a shell exit) re-spaces it
/// instead of handing all the freed space to the closed pane's neighbor (⅓ · ⅔).
/// See `PaneNode.equalizeRatios`.
/// Stored as a Bool in UserDefaults("damson.evenSplits"). **On by default.**
/// Read at each split/close, so the toggle takes effect immediately (no hot reload needed).
enum EvenSplits {
    static var enabled: Bool {
        // bool(forKey:) returns false when unset, which can't express default-on → check existence via object.
        (UserDefaults.standard.object(forKey: "damson.evenSplits") as? Bool) ?? true
    }
}
