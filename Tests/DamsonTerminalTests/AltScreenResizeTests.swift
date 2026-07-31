import XCTest
@testable import DamsonTerminal

/// Resizing while a full-screen app owns the screen must not damage the primary buffer
/// underneath it, and must not eat the scrollback it will be restored on top of.
///
/// Both defects here were reachable by resizing a window with `git log` open — git's default
/// pager is `less -FRX`, which parks a `:` prompt on the bottom row.
final class AltScreenResizeTests: XCTestCase {

    private func put(_ g: Grid, _ s: String) { for ch in s { g.putChar(ch) } }

    /// Physical rows rejoined into logical lines, so a re-wrap at a different width reads as
    /// the same content.
    private func logicalLines(_ g: Grid) -> [String] {
        var phys: [(cells: [Cell], wrapped: Bool)] = g.scrollback.map { ($0.cells, $0.wrapped) }
        for r in 0..<g.rows { phys.append((g.row(r), g.rowWrapped(r))) }
        var out: [String] = []
        var cur = ""
        for (cells, wrapped) in phys {
            for c in cells where !c.isContinuation && !c.isWideSpacer { cur.append(c.char) }
            if !wrapped { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = "" }
        }
        if !cur.isEmpty { out.append(cur.trimmingCharacters(in: .whitespaces)) }
        return out.filter { !$0.isEmpty }
    }

    /// 36 chars — soft-wraps at 20 cols, needs 4 rows at 10.
    private let long = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

    /// Finished output, then a prompt on the line below — the cursor is NOT inside the
    /// wrapped line, so that line is ordinary finished output and must rewrap losslessly.
    private func shellGrid() -> Grid {
        let g = Grid(cols: 20, rows: 6, pen: CellAttrs(fg: .default))
        put(g, long)
        g.lineFeed()
        g.carriageReturn()
        put(g, "$ ")
        return g
    }

    // MARK: a width change made while the alt screen is up

    func testNarrowingInsideAltScreenKeepsPrimaryContent() {
        let g = shellGrid()
        g.enterAltScreen()
        g.resize(cols: 10, rows: 6)
        g.leaveAltScreen()
        XCTAssertTrue(logicalLines(g).contains(long),
                      "narrowing while a TUI was up clipped every primary row at the new "
                      + "width; got \(logicalLines(g))")
    }

    func testWideningInsideAltScreenKeepsPrimaryContent() {
        let g = shellGrid()
        g.enterAltScreen()
        g.resize(cols: 40, rows: 6)
        g.leaveAltScreen()
        // The failure mode here was subtler than loss: the row stayed split at the OLD width
        // and the pad to the new one was written into the cells, so the logical line carried
        // 20 spaces in its middle for good — no later reflow could rejoin it.
        XCTAssertTrue(logicalLines(g).contains(long),
                      "widening while a TUI was up left the line split at the old width; "
                      + "got \(logicalLines(g))")
    }

    /// The point of the fix is that the alt round trip is indistinguishable from resizing
    /// at the shell — same content, same wrapping.
    func testAltRoundTripMatchesResizingAtTheShell() {
        for width in [8, 10, 13, 25, 40] {
            let direct = shellGrid()
            direct.resize(cols: width, rows: 6)

            let viaAlt = shellGrid()
            viaAlt.enterAltScreen()
            viaAlt.resize(cols: width, rows: 6)
            viaAlt.leaveAltScreen()

            XCTAssertEqual(logicalLines(viaAlt), logicalLines(direct),
                           "alt round trip diverged from a direct resize at \(width) cols")
        }
    }

    /// Content surviving is not enough: the restored buffer has to actually BE the new size.
    /// Leaving the snapshot untouched during alt (which is what stops the clipping) leaves it
    /// at the old geometry, so something has to bring it forward — rows the width of the old
    /// grid read fine through `row()` while being wrong for every consumer that trusts `cols`.
    func testPrimaryMatchesTheNewGeometryAfterLeavingAlt() {
        let g = shellGrid()                 // 20 x 6
        g.enterAltScreen()
        g.resize(cols: 10, rows: 8)
        g.leaveAltScreen()
        XCTAssertEqual(g.cols, 10)
        XCTAssertEqual(g.rows, 8)
        for r in 0..<g.rows {
            XCTAssertEqual(g.row(r).count, g.cols, "row \(r) is not the grid's width")
        }
        XCTAssertLessThanOrEqual(g.cursorRow, g.rows - 1)
        XCTAssertLessThanOrEqual(g.cursorCol, g.cols - 1)
    }

    func testAltScreenItselfIsStillTrimPadded() {
        // The alt buffer is the app's own; it redraws after SIGWINCH, so it must NOT be
        // reflowed — only the primary underneath is.
        let g = shellGrid()
        g.enterAltScreen()
        put(g, long)                       // app content, wraps at 20
        g.resize(cols: 10, rows: 6)
        XCTAssertEqual(g.cols, 10)
        XCTAssertEqual(String(g.row(0).map { $0.char }), "ABCDEFGHIJ",
                       "alt rows are clipped to width, not rewrapped")
    }

    // MARK: the grow-pull, and who it is meant for

    /// A pager fills the screen and keeps its cursor on the bottom row, exactly like a shell
    /// prompt does. Only the foreground-job fact separates them.
    private func pagerGrid() -> Grid {
        let g = Grid(cols: 20, rows: 4, pen: CellAttrs(fg: .default))
        for i in 1...8 {
            put(g, "L\(i)")
            g.lineFeed()
            g.carriageReturn()
        }
        put(g, ":")
        return g
    }

    func testGrowDoesNotEatScrollbackUnderAForegroundApp() {
        let g = pagerGrid()
        XCTAssertEqual(g.cursorRow, g.rows - 1, "the pager's cursor is on the bottom row")
        let before = g.scrollback.map { String($0.cells.map { $0.char }).trimmingCharacters(in: .whitespaces) }

        // preservePromptBlock: false == a foreground job owns the screen (DamsonSession
        // derives it from tcgetpgrp). It will repaint its whole window after SIGWINCH, so
        // anything pulled up into the viewport is overwritten and gone from history.
        g.resize(cols: 20, rows: 6, preservePromptBlock: false)

        let after = g.scrollback.map { String($0.cells.map { $0.char }).trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(after, before,
                       "a foreground app's grow must not consume scrollback — those lines are "
                       + "about to be painted over and would be lost")
    }

    func testGrowStillBottomAnchorsAtTheShellPrompt() {
        // The behaviour the pull exists for is unchanged: at a real prompt, growing pulls
        // history back down instead of opening a blank gap.
        let g = pagerGrid()          // same shape, but now it IS the shell
        let sbBefore = g.scrollback.count
        g.resize(cols: 20, rows: 6, preservePromptBlock: true)
        XCTAssertEqual(g.scrollback.count, sbBefore - 2, "grow should pull 2 lines back down")
        XCTAssertEqual(String(g.row(0).map { $0.char }).trimmingCharacters(in: .whitespaces), "L4")
        XCTAssertEqual(String(g.row(5).map { $0.char }).trimmingCharacters(in: .whitespaces), ":")
    }
}
