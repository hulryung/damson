import Foundation

/// Stepping along the visible tab row.
///
/// Tabs folded into a collapsed group still occupy an index but have no button in
/// the bar, so a step that lands on one would look like nothing happened. These
/// helpers walk the row as the user sees it: folded tabs are skipped and the ends
/// wrap, matching ⌘→ / ⌘←.
public enum TabRow {
    /// The tab one step away from `selected`, skipping tabs folded into collapsed
    /// groups and wrapping at both ends.
    ///
    /// - Parameters:
    ///   - selected: The current tab index. It may itself be folded (a group can be
    ///     collapsed around the active tab), in which case the step continues from
    ///     where it sits in the row rather than giving up.
    ///   - count: Total number of tabs, folded ones included.
    ///   - hidden: Indices with no button in the bar.
    ///   - next: `true` steps toward the end of the row, `false` toward the start.
    /// - Returns: The index to select, or `nil` when there is nowhere else to go
    ///   (fewer than two visible tabs).
    public static func neighbor(of selected: Int, count: Int,
                                hidden: Set<Int>, next: Bool) -> Int? {
        let visible = (0..<max(0, count)).filter { !hidden.contains($0) }
        guard !visible.isEmpty else { return nil }
        if let pos = visible.firstIndex(of: selected) {
            guard visible.count > 1 else { return nil }   // the only tab in the row
            return visible[(pos + (next ? 1 : visible.count - 1)) % visible.count]
        }
        // The selection is folded away: step to the nearest visible tab on that side.
        return next ? (visible.first { $0 > selected } ?? visible[0])
                    : (visible.last { $0 < selected } ?? visible[visible.count - 1])
    }
}
