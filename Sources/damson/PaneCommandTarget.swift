import AppKit
import DamsonControl
import DamsonTerminal

/// The pane-level command surface both window-controller kinds — `CompactWindowController`
/// and `DamsonWindowController` — already expose identically. Grouping it into one protocol
/// lets the damson-cli control handlers dispatch to whichever controller owns the active
/// window through a single `withActiveTarget` code path, instead of each handler repeating
/// the "try compact, else try single, else error" branch (see AppDelegate control* methods).
///
/// Tab-level commands (close/switch/list tabs) are intentionally NOT here: compact windows
/// own their tabs internally while single-session windows use native window tabs, so those
/// handlers have genuinely different logic per controller kind.
protocol PaneCommandTarget: AnyObject {
    func splitActive(direction: SplitDirection)
    func applyLayout(_ template: PaneLayoutTemplate)
    func focusActivePane(_ dir: PaneFocusDirection)
    func closeActivePane()
    func resizeActivePane(_ dir: PaneFocusDirection, cells: Int) -> Bool
    func resizeWindowToGrid(cols: Int, rows: Int) -> Bool
    func paneList() -> [PaneInfo]
    var activeSurfaceView: DamsonSurfaceView? { get }
    var activeSession: DamsonSession? { get }

    // Id-addressed variants (`--pane <id>`): the named pane substitutes for "the active
    // pane" in the operation, wherever in this controller it lives — the current tab or
    // another one. Each returns "did this controller own that pane"; the AppDelegate asks
    // every controller in turn and reports a typed error when none did. Both controller
    // kinds implement these identically through their PaneTreeView(s), which is what earns
    // them a place on this seam.
    /// The surface hosting `session`, when this controller owns it (id-addressed `zoom`).
    func surfaceView(for session: DamsonSession) -> DamsonSurfaceView?
    /// Move focus from `session`'s pane toward `dir` (no neighbor = silent no-op, like the
    /// active-pane path). false when this controller doesn't own the pane.
    func focusPane(from session: DamsonSession, _ dir: PaneFocusDirection) -> Bool
    /// Close `session`'s pane. false when this controller doesn't own the pane.
    func closePane(for session: DamsonSession) -> Bool
    /// Nudge the divider governing `session`'s pane. nil when this controller doesn't own
    /// the pane; false when it does but the pane has no split on that axis.
    func resizePane(for session: DamsonSession, _ dir: PaneFocusDirection, cells: Int) -> Bool?
}
