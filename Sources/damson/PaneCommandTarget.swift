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
}
