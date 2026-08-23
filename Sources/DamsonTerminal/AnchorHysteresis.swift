import Foundation

/// Debounces the "this grid is an anchored TUI" decision that drives the viewport policy.
///
/// The raw predicate (`isAltScreenActive || hasUsedSyncOutput || hasContentBelowCursor`) is
/// an INSTANT: its last term asks "is any row below the cursor non-blank *right now*". A TUI
/// that repaints by walking the cursor through its frame makes that false for the moments the
/// cursor is below everything drawn so far — and the host renders per PTY drain, so those
/// moments get sampled.
///
/// Measured on a captured Antigravity session (its model picker, arrowing up and down): the
/// raw predicate flipped 41 times across 138 renders — roughly every third frame.
///
/// Each drop calls `clearFollowAnchor()`, which lowers the scroll ceiling from the grid-top
/// anchor to the natural content bottom and re-clamps the current position down with it. The
/// content slides DOWN by `inset + the window's fractional extra height`, leaving a sliver of
/// blank above the grid. Small — a few pixels — but it fires on every keypress, so the screen
/// visibly jitters while you arrow through a menu. (macOS Terminal shows none of this: it has
/// no scrollback-anchored viewport to re-clamp.)
///
/// Anchoring is a property of the session, not of the instant, so a false reading only counts
/// once it persists. A genuine return to the shell keeps reading false and releases within a
/// few renders; a repaint's transient never gets near the threshold.
public struct AnchorHysteresis {
    /// Consecutive false readings needed to actually release the anchor. 16 measured clean
    /// (0 spurious flips) at realistic drain sizes on the capture above, where 8 still let 2
    /// through; going higher buys almost nothing and only makes a real release lag.
    public static let releaseAfter = 16

    private var falseStreak = 0

    public init() {}

    /// Feed one render's raw reading, get the debounced answer.
    public mutating func update(raw: Bool) -> Bool {
        if raw { falseStreak = 0 } else { falseStreak += 1 }
        return raw || falseStreak < Self.releaseAfter
    }

    /// Decide the next reading on its own merits — for a genuine mode change (an alt-screen
    /// transition), where coasting on the old answer would be wrong rather than merely stale.
    public mutating func reset() { falseStreak = 0 }
}
