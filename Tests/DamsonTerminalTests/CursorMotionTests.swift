import XCTest
@testable import DamsonTerminal

/// The cursor's drawn position, eased toward the cell the grid says it is in.
///
/// The hard part is not the easing — it is knowing when NOT to ease. The cursor's row is a
/// unified row (scrollback + screen row), so a line of output moves it down by one even
/// though it stays put on screen; sliding there would drag the cursor down the window on
/// every newline. Everything that is not "the cursor moved within a screen that stayed the
/// same" has to teleport.
final class CursorMotionTests: XCTestCase {
    private let screen = CursorMotion.Screen(altScreen: false, cols: 80, rows: 24,
                                             scrollbackCount: 0, evicted: 0)

    /// Long enough for a 0.035s time constant to settle (≈5 τ).
    private func settle(_ m: inout CursorMotion, seconds: Double = 0.3, step: Double = 1.0 / 120) {
        var t = 0.0
        while t < seconds, !m.step(dt: step) { t += step }
    }

    // MARK: - Teleports

    /// Nothing has been drawn yet, so there is nowhere to come from: the first position is
    /// simply where the cursor is. Easing from (0,0) would fly the cursor in on every launch.
    func testTheFirstPositionIsNotAnimated() {
        var m = CursorMotion()
        m.retarget(row: 12, col: 40, screen: screen, animated: true)
        XCTAssertEqual(m.drawn.row, 12)
        XCTAssertEqual(m.drawn.col, 40)
        XCTAssertFalse(m.animating)
    }

    /// A line of output: the unified row grows with the scrollback, and on screen the cursor
    /// has not moved at all. Sliding would walk it down the window one line per newline.
    func testOutputThatGrowsTheScrollbackTeleports() {
        var m = CursorMotion()
        m.retarget(row: 23, col: 0, screen: screen, animated: true)
        var scrolled = screen
        scrolled.scrollbackCount = 1
        m.retarget(row: 24, col: 0, screen: scrolled, animated: true)
        XCTAssertFalse(m.animating, "a scrolled screen must not slide")
        XCTAssertEqual(m.drawn.row, 24)
    }

    func testEnteringOrLeavingTheAltScreenTeleports() {
        var m = CursorMotion()
        m.retarget(row: 5, col: 5, screen: screen, animated: true)
        var alt = screen
        alt.altScreen = true
        m.retarget(row: 0, col: 0, screen: alt, animated: true)
        XCTAssertFalse(m.animating)
        XCTAssertEqual(m.drawn.col, 0)
    }

    func testAResizeTeleports() {
        var m = CursorMotion()
        m.retarget(row: 5, col: 70, screen: screen, animated: true)
        var wider = screen
        wider.cols = 120
        m.retarget(row: 5, col: 70, screen: wider, animated: true)
        XCTAssertFalse(m.animating)
    }

    func testEvictedScrollbackTeleports() {
        var m = CursorMotion()
        m.retarget(row: 100, col: 3, screen: screen, animated: true)
        var evicted = screen
        evicted.evicted = 10
        m.retarget(row: 100, col: 3, screen: evicted, animated: true)
        XCTAssertFalse(m.animating)
    }

    /// The setting is off, or macOS Reduce Motion is on.
    func testAnimationOffTeleports() {
        var m = CursorMotion()
        m.retarget(row: 1, col: 1, screen: screen, animated: true)
        m.retarget(row: 1, col: 30, screen: screen, animated: false)
        XCTAssertFalse(m.animating)
        XCTAssertEqual(m.drawn.col, 30)
    }

    /// Re-rendering without the cursor having moved (a blink tick, a selection change) must
    /// not start an animation — that would keep the display link alive forever.
    func testRetargetingTheSamePositionDoesNotAnimate() {
        var m = CursorMotion()
        m.retarget(row: 3, col: 9, screen: screen, animated: true)
        m.retarget(row: 3, col: 9, screen: screen, animated: true)
        XCTAssertFalse(m.animating)
    }

    // MARK: - Easing

    func testAMoveWithinTheScreenAnimates() {
        var m = CursorMotion()
        m.retarget(row: 4, col: 0, screen: screen, animated: true)
        m.retarget(row: 4, col: 20, screen: screen, animated: true)
        XCTAssertTrue(m.animating)
        XCTAssertEqual(m.drawn.col, 0, "the draw position starts where the cursor was")

        XCTAssertFalse(m.step(dt: 1.0 / 120), "one frame does not finish the move")
        XCTAssertGreaterThan(m.drawn.col, 0)
        XCTAssertLessThan(m.drawn.col, 20)
    }

    func testItConvergesAndStops() {
        var m = CursorMotion()
        m.retarget(row: 0, col: 0, screen: screen, animated: true)
        m.retarget(row: 10, col: 60, screen: screen, animated: true)
        settle(&m)
        XCTAssertFalse(m.animating, "the display link must be allowed to stop")
        XCTAssertEqual(m.drawn.row, 10, accuracy: 0.001)
        XCTAssertEqual(m.drawn.col, 60, accuracy: 0.001)
    }

    /// A cursor that took visibly longer than a keystroke would feel like lag rather than
    /// polish, and one that cannot be seen moving is not an animation.
    func testItSettlesInUnderAFifthOfASecondAndIsVisibleForSeveralFrames() {
        var m = CursorMotion()
        m.retarget(row: 0, col: 0, screen: screen, animated: true)
        m.retarget(row: 0, col: 40, screen: screen, animated: true)

        var frames = 0
        var elapsed = 0.0
        let dt = 1.0 / 120
        while !m.step(dt: dt), elapsed < 1.0 { frames += 1; elapsed += dt }
        XCTAssertLessThan(elapsed, 0.2, "slower than this reads as lag")
        XCTAssertGreaterThan(frames, 5, "faster than this is not visible as motion")
    }

    /// Frame-rate independence: the same elapsed time must land in the same place whether it
    /// arrived as 120Hz or 60Hz frames. Without it the cursor is slower on a ProMotion display.
    func testTheSamePositionIsReachedAtAnyFrameRate() {
        var fast = CursorMotion(), slow = CursorMotion()
        fast.retarget(row: 0, col: 0, screen: screen, animated: true)
        slow.retarget(row: 0, col: 0, screen: screen, animated: true)
        fast.retarget(row: 0, col: 50, screen: screen, animated: true)
        slow.retarget(row: 0, col: 50, screen: screen, animated: true)

        for _ in 0..<12 { _ = fast.step(dt: 1.0 / 120) }   // 0.1s
        for _ in 0..<6 { _ = slow.step(dt: 1.0 / 60) }     // 0.1s
        XCTAssertEqual(fast.drawn.col, slow.drawn.col, accuracy: 0.5)
    }

    func testItNeverOvershootsAndOnlyMovesForward() {
        var m = CursorMotion()
        m.retarget(row: 0, col: 0, screen: screen, animated: true)
        m.retarget(row: 0, col: 30, screen: screen, animated: true)
        var last = m.drawn.col
        for _ in 0..<60 {
            _ = m.step(dt: 1.0 / 120)
            XCTAssertGreaterThanOrEqual(m.drawn.col, last)
            XCTAssertLessThanOrEqual(m.drawn.col, 30)
            last = m.drawn.col
        }
    }

    /// Typing: each keystroke retargets mid-flight. The cursor must continue from where it
    /// is rather than restarting at the previous cell, or fast typing looks like stutter.
    func testRetargetingMidFlightContinuesFromWhereItIs() {
        var m = CursorMotion()
        m.retarget(row: 0, col: 0, screen: screen, animated: true)
        m.retarget(row: 0, col: 10, screen: screen, animated: true)
        _ = m.step(dt: 1.0 / 120)
        let mid = m.drawn.col
        XCTAssertGreaterThan(mid, 0)

        m.retarget(row: 0, col: 11, screen: screen, animated: true)
        XCTAssertEqual(m.drawn.col, mid, "the jump-back would be visible as stutter")
        XCTAssertTrue(m.animating)
    }

    // MARK: - Trail

    /// A cursor sitting still has no smear — and nothing to keep the display link alive for.
    func testAnIdleCursorHasNoTrail() {
        var m = CursorMotion()
        m.retarget(row: 2, col: 2, screen: screen, animated: true)
        XCTAssertTrue(m.trail(count: 5).isEmpty)
    }

    /// Each ghost is further back than the one in front of it, and none of them run past the
    /// ends of the move — a trail that overshoots reads as a second cursor.
    func testGhostsLagBehindTheHeadInOrderAndStayOnThePath() {
        var m = CursorMotion()
        m.retarget(row: 0, col: 0, screen: screen, animated: true)
        m.retarget(row: 0, col: 40, screen: screen, animated: true)
        for _ in 0..<5 { _ = m.step(dt: 1.0 / 120) }

        let ghosts = m.trail(count: 5)
        XCTAssertEqual(ghosts.count, 5)
        var previous = m.drawn.col
        for g in ghosts {
            XCTAssertLessThanOrEqual(g.col, previous, "a ghost passed the one ahead of it")
            XCTAssertGreaterThanOrEqual(g.col, 0)
            XCTAssertLessThanOrEqual(g.col, 40)
            previous = g.col
        }
    }

    /// As the cursor lands, the tail catches up: a smear left hanging behind the settled
    /// cursor would look like a stuck second cursor until the next keystroke.
    func testTheTailCollapsesIntoTheHeadOnArrival() {
        var m = CursorMotion()
        m.retarget(row: 0, col: 0, screen: screen, animated: true)
        m.retarget(row: 0, col: 40, screen: screen, animated: true)
        while !m.step(dt: 1.0 / 120) {
            let ghosts = m.trail(count: 5)
            if let last = ghosts.last, m.drawn.col > 39 {
                XCTAssertGreaterThan(last.col, 30, "the tail is still at the far end on arrival")
            }
        }
        XCTAssertTrue(m.trail(count: 5).isEmpty, "settled: no trail left behind")
    }

    /// Stepping an idle motion is a no-op that reports "settled", so the caller stops the link.
    func testSteppingWhenIdleIsSettled() {
        var m = CursorMotion()
        m.retarget(row: 2, col: 2, screen: screen, animated: true)
        XCTAssertTrue(m.step(dt: 1.0 / 120))
        XCTAssertEqual(m.drawn.col, 2)
    }

    /// The macOS 13 path: no display link, so the backend finishes the move in one call.
    func testAHugeStepLandsExactlyOnTarget() {
        var m = CursorMotion()
        m.retarget(row: 0, col: 0, screen: screen, animated: true)
        m.retarget(row: 20, col: 70, screen: screen, animated: true)
        XCTAssertTrue(m.step(dt: 10))
        XCTAssertEqual(m.drawn.row, 20)
        XCTAssertEqual(m.drawn.col, 70)
    }
}
