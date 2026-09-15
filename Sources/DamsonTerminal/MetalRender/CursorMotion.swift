import Foundation

/// Where the cursor is *drawn*, as opposed to the cell the grid says it is in.
///
/// The grid reports whole cells, so a cursor jumps. This holds a fractional position that
/// eases toward the cell, in the same shape as `ScrollModel`: an exponential approach
/// stepped by the render loop's display link, with no view and no timer of its own, so the
/// arithmetic is unit-testable.
///
/// The easing is the easy half. The row is a **unified** row (scrollback + screen row), so a
/// single line of output moves the cursor down by one while it stays exactly where it is on
/// screen — easing there would walk the cursor down the window on every newline. So anything
/// that is not "the cursor moved inside a screen that otherwise stayed the same" teleports:
/// scrolled output, an alt-screen switch, a resize, evicted scrollback.
struct CursorMotion {
    struct Anchor: Equatable {
        var row: Double
        var col: Double
    }

    /// What the cursor's position is measured against. Any change here means the coordinate
    /// system moved under the cursor, not the cursor within it.
    struct Screen: Equatable {
        var altScreen: Bool
        var cols: Int
        var rows: Int
        var scrollbackCount: Int
        /// `Grid.linesEvictedFromTop` — unbounded, hence the width.
        var evicted: UInt64
    }

    /// Where to draw right now. Equals the target whenever idle.
    private(set) var drawn = Anchor(row: 0, col: 0)
    private var target = Anchor(row: 0, col: 0)
    /// Where the current move began, and how far through it we are. Progress rather than a
    /// time constant: an exponential approach takes longer the further it goes — measured,
    /// 0.26s across 40 columns — so a jump to the end of a long line would lag behind the
    /// keystroke that caused it while a one-cell move finished instantly. A fixed duration
    /// gives every move the same, predictable weight.
    private var origin = Anchor(row: 0, col: 0)
    private var progress: Double = 1
    private var screen: Screen?
    private(set) var animating = false

    /// Seconds a move takes, whatever its length. Long enough to read as motion at 60Hz
    /// (about 7 frames), short enough that it is over before the next keystroke at a fast
    /// typing speed.
    static let duration: Double = 0.11

    /// Point the cursor at a cell. Teleports — rather than easing — for the first position,
    /// for a screen that changed under it, and when animation is off (the setting, or macOS
    /// Reduce Motion). An unchanged target leaves an in-flight ease alone rather than
    /// restarting it, so a blink tick or a selection change cannot keep the link alive.
    mutating func retarget(row: Int, col: Int, screen: Screen, animated: Bool) {
        let next = Anchor(row: Double(row), col: Double(col))
        let sameScreen = (self.screen == screen)
        self.screen = screen

        guard animated, sameScreen else {
            settle(at: next)
            return
        }
        guard next != target else { return }   // same cell: leave an in-flight move alone
        guard next != drawn else {
            settle(at: next)                   // already there (a move that came straight back)
            return
        }
        // Start from wherever the cursor is being drawn right now, not from the cell it was
        // last aimed at: typing retargets mid-flight, and restarting at the old cell is
        // visible as a stutter.
        origin = drawn
        target = next
        progress = 0
        animating = true
    }

    private mutating func settle(at position: Anchor) {
        drawn = position
        target = position
        origin = position
        progress = 1
        animating = false
    }

    /// Where the cursor has just been, nearest first — the smear drawn behind it.
    ///
    /// Sampled from this move's own progress rather than a buffer of past frames: a history
    /// buffer drifts out of step with the head whenever frames are dropped, and it has to be
    /// cleared on every teleport or the trail stretches across the screen. Sampling the path
    /// cannot do either, and the tail collapses into the head on arrival for free.
    func trail(count: Int, lag: Double = 0.14) -> [Anchor] {
        guard animating, count > 0, lag > 0 else { return [] }
        // The lag shrinks with the distance left to cover. Under a constant lag the easing's
        // own deceleration strands the tail: measured, the head had all but arrived (column
        // 39 of 40) while the oldest ghost was still at column 24, and the whole smear then
        // vanished at once when the move settled. Folding in the remaining progress pulls
        // the tail into the head as it lands, so the trail ends by disappearing INTO the
        // cursor rather than being switched off behind it.
        let reach = lag * (1 - progress)
        return (1...count).map { i in
            let p = max(0, progress - Double(i) * reach)
            let e = 1 - pow(1 - p, 3)
            return Anchor(row: origin.row + (target.row - origin.row) * e,
                          col: origin.col + (target.col - origin.col) * e)
        }
    }

    /// Advance an in-flight move by `dt` seconds, frame-rate independently. Returns true once
    /// settled, which is the caller's signal to stop the display link. A no-op returns true.
    @discardableResult
    mutating func step(dt: Double) -> Bool {
        guard animating else { return true }
        progress = min(1, progress + max(0, dt) / Self.duration)
        if progress >= 1 {
            settle(at: target)
            return true
        }
        // easeOut cubic: quick off the mark, gentle on arrival, and monotonic — the cursor
        // never overshoots the cell it is heading for.
        let e = 1 - pow(1 - progress, 3)
        drawn.row = origin.row + (target.row - origin.row) * e
        drawn.col = origin.col + (target.col - origin.col) * e
        return false
    }
}
