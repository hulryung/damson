import XCTest
@testable import DamsonTerminal

/// Vertical (row-count) resize of the primary screen — the "grow the window and a
/// blank gap opens at the bottom / shrink it back and duplicated TUI rows appear
/// above" report. Grow must pull lines back from scrollback (bottom-anchored,
/// kitty/ghostty/iTerm2 behavior) and shrink must trim trailing blanks below the
/// cursor before pushing from the top, so grow→shrink round-trips losslessly.
final class VerticalResizeTests: XCTestCase {
    private func write(_ g: Grid, _ s: String) { for ch in s { g.putChar(ch) } }
    private func rowText(_ cells: [Cell]) -> String {
        var out = ""
        for c in cells where !c.isContinuation { out.append(c.char) }
        while out.hasSuffix(" ") { out.removeLast() }
        return out
    }
    private func rowText(_ line: Line) -> String { rowText(line.cells) }
    private func viewportTexts(_ g: Grid) -> [String] { (0..<g.rows).map { rowText(g.row($0)) } }
    /// scrollback + viewport as one sequence of trimmed row texts, sans trailing blanks.
    private func unifiedTexts(_ g: Grid) -> [String] {
        var all = g.scrollback.map(rowText) + viewportTexts(g)
        while let last = all.last, last.isEmpty { all.removeLast() }
        return all
    }

    /// 30 numbered lines into a 10-row grid → 21 lines in scrollback ("line0"…"line20"),
    /// viewport "line21"…"line29" + cursor line, cursor on the last row.
    private func filledGrid(rows: Int = 10) -> Grid {
        let g = Grid(cols: 20, rows: rows, pen: CellAttrs(fg: .default))
        for i in 0..<30 {
            write(g, "line\(i)")
            g.carriageReturn(); g.lineFeed()
        }
        return g
    }

    // MARK: - Grow

    func testGrowPullsFromScrollbackBottomAnchored() {
        let g = filledGrid()
        let beforeUnified = unifiedTexts(g)
        let beforeSb = g.scrollback.count
        let beforeCursor = g.cursorRow

        g.resize(cols: g.cols, rows: 16)

        XCTAssertEqual(g.scrollback.count, beforeSb - 6, "grow by 6 pulls 6 lines back")
        XCTAssertEqual(g.cursorRow, beforeCursor + 6, "cursor rides down with the content")
        XCTAssertEqual(unifiedTexts(g), beforeUnified, "unified content unchanged")
        // The former scrollback tail is now the viewport top — no blank gap at the bottom.
        XCTAssertEqual(rowText(g.row(0)), "line15")
        XCTAssertFalse((0..<g.rows - 1).map { self.rowText(g.row($0)) }.contains(""),
                       "no blank gap inside the grown viewport")
    }

    func testGrowBeyondScrollbackPadsBottomWithBlanks() {
        let g = Grid(cols: 20, rows: 5, pen: CellAttrs(fg: .default))
        for i in 0..<7 { write(g, "line\(i)"); g.carriageReturn(); g.lineFeed() }
        XCTAssertEqual(g.scrollback.count, 3)

        g.resize(cols: g.cols, rows: 12)   // +7 rows but only 3 in scrollback

        XCTAssertEqual(g.scrollback.count, 0, "everything pulled back")
        XCTAssertEqual(rowText(g.row(0)), "line0")
        XCTAssertEqual(g.cursorRow, 7, "cursor moved down by the 3 pulled rows")
        for r in 8..<12 { XCTAssertEqual(rowText(g.row(r)), "", "shortfall pads blank at bottom") }
    }

    func testGrowShrinkRoundTripIsLossless() {
        let g = filledGrid()
        let beforeUnified = unifiedTexts(g)
        let beforeSb = g.scrollback.count
        let beforeCursor = g.cursorRow
        let beforePush = g.scrollbackPushCount

        g.resize(cols: g.cols, rows: 18)
        g.resize(cols: g.cols, rows: 10)

        XCTAssertEqual(g.scrollback.count, beforeSb, "pulled lines went back")
        XCTAssertEqual(g.cursorRow, beforeCursor)
        XCTAssertEqual(g.scrollbackPushCount, beforePush, "push counter round-trips")
        XCTAssertEqual(unifiedTexts(g), beforeUnified, "no duplicated or lost rows")
    }

    // MARK: - Shrink

    func testShrinkTrimsTrailingBlanksBeforePushing() {
        // Prompt at the top, blanks below (plain shell look): shrinking must trim
        // the blank bottom, not push the prompt into scrollback (prompt pile-up).
        let g = Grid(cols: 20, rows: 10, pen: CellAttrs(fg: .default))
        write(g, "prompt$")
        XCTAssertEqual(g.cursorRow, 0)

        g.resize(cols: g.cols, rows: 4)

        XCTAssertEqual(g.scrollback.count, 0, "nothing pushed — bottom blanks trimmed")
        XCTAssertEqual(rowText(g.row(0)), "prompt$")
        XCTAssertEqual(g.cursorRow, 0)
    }

    func testShrinkPreservesStatusLineBelowCursor() {
        // Claude Code shape: input line (cursor) with a non-blank status line BELOW it.
        // The old policy bottom-trimmed rows below the cursor whenever the cursor fit,
        // destroying the status row.
        let g = Grid(cols: 20, rows: 10, pen: CellAttrs(fg: .default))
        for i in 0..<6 { write(g, "ui\(i)"); g.carriageReturn(); g.lineFeed() }   // rows 0–5
        g.setCursor(row: 9, col: 1); write(g, "status")                          // row 8, below…
        g.setCursor(row: 7, col: 1); write(g, "input>")                          // …the cursor row 6

        g.resize(cols: g.cols, rows: 8)   // shrink by 2; only row 9 is blank

        XCTAssertEqual(g.scrollback.count, 1, "1 blank trimmed, 1 top row pushed")
        XCTAssertEqual(rowText(g.scrollback[0]), "ui0")
        XCTAssertEqual(rowText(g.row(g.cursorRow)), "input>", "cursor stays on its row")
        XCTAssertTrue(viewportTexts(g).contains("status"), "status below cursor survives")
    }

    func testExtremeShrinkKeepsCursorRowInViewport() {
        // Content everywhere, cursor near the top: the push is capped at cursorRow so
        // the cursor's own row never scrolls out of the viewport.
        let g = Grid(cols: 20, rows: 10, pen: CellAttrs(fg: .default))
        for i in 0..<9 { write(g, "row\(i)"); g.carriageReturn(); g.lineFeed() }
        write(g, "row9")                 // fill all 10 rows, no trailing LF
        g.setCursor(row: 3, col: 5)   // 1-based CUP -> cursorRow 2

        g.resize(cols: g.cols, rows: 3)

        XCTAssertEqual(g.scrollback.count, 2, "push capped at the cursor row")
        XCTAssertEqual(g.cursorRow, 0)
        XCTAssertEqual(rowText(g.row(0)), "row2", "cursor's row is the new top")
    }

    // MARK: - Invariants across the change

    func testPromptMarkMappingStableAcrossGrowAndShrink() {
        // absLine = pushCount + cursorRow at record time; mapped back later as
        // scrollback.count + absLine − pushCount. The mapped row must keep pointing
        // at the same content through vertical resizes.
        let g = filledGrid()
        let absLine = g.scrollbackPushCount + UInt64(g.cursorRow - 1)   // the "line29" row
        func mappedText(_ g: Grid) -> String {
            let row = g.scrollback.count + Int(absLine) - Int(g.scrollbackPushCount)
            return row < g.scrollback.count
                ? rowText(g.scrollback[row])
                : rowText(g.row(row - g.scrollback.count))
        }
        XCTAssertEqual(mappedText(g), "line29")
        g.resize(cols: g.cols, rows: 17)
        XCTAssertEqual(mappedText(g), "line29", "mapping survives grow (pushCount decremented)")
        g.resize(cols: g.cols, rows: 8)
        XCTAssertEqual(mappedText(g), "line29", "mapping survives shrink")
    }

    func testAltScreenRowChangeDoesNotTouchScrollback() {
        // Entering the alt screen stashes the primary scrollback into savedPrimary;
        // the live scrollback is the alt one (empty) and must stay that way.
        let g = filledGrid()
        let primaryUnified = unifiedTexts(g)
        g.enterAltScreen()
        g.resize(cols: g.cols, rows: 16)
        XCTAssertEqual(g.scrollback.count, 0, "alt-screen grow must not pull from scrollback")
        g.resize(cols: g.cols, rows: 10)
        XCTAssertEqual(g.scrollback.count, 0, "alt-screen shrink must not push")
        g.leaveAltScreen()
        XCTAssertEqual(unifiedTexts(g), primaryUnified,
                       "primary content intact after alt-screen row changes")
    }

    func testGrowAlwaysBottomAnchorsEvenWithABottomGap() {
        // Bottom-anchor is UNCONDITIONAL on grow (iTerm2/wezterm semantics): even
        // with blank rows below the content, history pulls back in and the content
        // slides down. Claude Code keeps one blank row under its status line — an
        // earlier gap-discount variant absorbed every +1-row drag step into that
        // gap, never pulled, and Ink's bottom-anchored re-render then left a stale
        // duplicate row behind (the reported artifact).
        let g = filledGrid()
        g.eraseInDisplay(mode: 2)          // cleared screen: content blanked in place
        g.setCursor(row: 1, col: 1)
        write(g, "prompt$")
        let sb = g.scrollback.count

        g.resize(cols: g.cols, rows: 16)   // +6 rows

        XCTAssertEqual(g.scrollback.count, sb - 6, "history pulls back in (Terminal.app-style)")
        XCTAssertEqual(rowText(g.row(6)), "prompt$", "prompt slid down with the pull")
        XCTAssertEqual(g.cursorRow, 6)
        XCTAssertEqual(rowText(g.row(5)), "line20", "pulled history sits above the prompt")
    }

    func testGrowWithShortScrollbackLinesDoesNotCrash() {
        // SessionRestore seeds scrollback lines trimmed to content width (narrower
        // than cols). Pulling one into the viewport must pad, not trap.
        let g = Grid(cols: 20, rows: 4, pen: CellAttrs(fg: .default))
        let shortLine = Line((0..<5).map { i in
            var c = Cell.empty(attrs: CellAttrs(fg: .default)); c.char = "s"; _ = i; return c
        })
        g.seedScrollback([shortLine, shortLine])
        for i in 0..<5 { write(g, "line\(i)"); g.carriageReturn(); g.lineFeed() }

        g.resize(cols: g.cols, rows: 10)   // pulls the seeded short lines

        XCTAssertEqual(rowText(g.row(0)), "sssss", "short line pulled and padded")
        XCTAssertEqual(g.row(0).count, g.cols, "pulled row padded to full width")
    }

    func testPromptStartMarkSurvivesRowResize() {
        let g = Grid(cols: 20, rows: 10, pen: CellAttrs(fg: .default))
        write(g, "before"); g.carriageReturn(); g.lineFeed()
        g.markPromptStart()
        write(g, "prompt$")
        XCTAssertTrue(g.rowIsPromptStart(1))

        g.resize(cols: g.cols, rows: 6)    // trims trailing blanks only
        XCTAssertTrue(g.rowIsPromptStart(1), "prompt mark survives a shrink")
        g.resize(cols: g.cols, rows: 10)
        XCTAssertTrue(g.rowIsPromptStart(1), "prompt mark survives a grow")
    }

    func testGrowNeverPullsLinesWiderThanTheViewport() {
        // Wide lines land in scrollback at unchanged cols via an alt-screen column
        // shrink (trim/pad resizes only the saved viewport, not saved scrollback).
        // Pulling one would clip it to the current width permanently; it must stay
        // in scrollback, where a later widening reflow rejoins it losslessly.
        let g = Grid(cols: 30, rows: 5, pen: CellAttrs(fg: .default))
        for i in 0..<10 {
            write(g, "line\(i)-ABCDEFGHIJKLMNOPQRST")   // ~28 cols wide
            g.carriageReturn(); g.lineFeed()
        }
        g.enterAltScreen()
        g.resize(cols: 20, rows: 5)      // alt active → saved scrollback keeps 30-wide lines
        g.leaveAltScreen()

        g.resize(cols: 20, rows: 12)     // row grow: wide tail lines must NOT pull

        XCTAssertTrue(g.scrollback.allSatisfy { $0.count > 20 } == false ||
                      !g.scrollback.isEmpty, "sanity")
        g.resize(cols: 30, rows: 12)     // widening reflow reunites the full lines
        let all = unifiedTexts(g).joined(separator: "\n")
        XCTAssertTrue(all.contains("line2-ABCDEFGHIJKLMNOPQRST"),
                      "wide history line survives the grow→widen sequence intact")
    }

    func testPromptMarkMappingSurvivesNarrowReflowThenGrow() {
        // A narrowing reflow inflates scrollback.count past pushCount (documented
        // skew). A later row grow must not let the pull exceed pushCount — the
        // saturating clamp would permanently offset the absolute mark frame.
        let g = Grid(cols: 40, rows: 6, pen: CellAttrs(fg: .default))
        for i in 0..<8 {
            write(g, String(repeating: "x", count: 38) + String(i))
            g.carriageReturn(); g.lineFeed()
        }
        g.resize(cols: 20, rows: 6)      // narrow reflow: count > pushCount now
        write(g, "PROMPT")
        let absLine = g.scrollbackPushCount + UInt64(g.cursorRow)
        func mappedText(_ g: Grid) -> String {
            let row = g.scrollback.count + Int(absLine) - Int(g.scrollbackPushCount)
            guard row >= 0 else { return "<negative>" }
            return row < g.scrollback.count
                ? rowText(g.scrollback[row])
                : rowText(g.row(row - g.scrollback.count))
        }
        XCTAssertEqual(mappedText(g), "PROMPT")

        g.resize(cols: 20, rows: 30)     // grow: pull must cap at pushCount

        XCTAssertEqual(mappedText(g), "PROMPT",
                       "absolute mark frame survives a grow after a narrowing reflow")
    }

    func testSavedCursorRidesDownWithThePull() {
        // DECSC state must shift with the content on a grow pull, so a later DECRC
        // lands on the row it was saved against (xterm adjusts the same way).
        let g = filledGrid()                       // cursor on the bottom row
        g.setCursor(row: g.rows, col: 1)           // 1-based CUP → last row
        write(g, "HERE")
        g.saveCursor()
        let savedText = rowText(g.row(g.cursorRow))

        g.resize(cols: g.cols, rows: 16)           // pulls 6, content moves down 6
        g.setCursor(row: 1, col: 1)                // wander away
        g.restoreCursor()

        XCTAssertEqual(rowText(g.row(g.cursorRow)), savedText,
                       "DECRC lands on the same content row after the pull")
    }

    func testSavedPrimaryGrowPullsFromItsOwnScrollback() {
        // While the alt screen is active, the saved primary must follow the same
        // bottom-anchor policy so leaving the alt screen after a grow shows no gap.
        let g = filledGrid()
        let beforeUnified = unifiedTexts(g)
        g.enterAltScreen()
        g.resize(cols: g.cols, rows: 16)
        g.leaveAltScreen()
        XCTAssertEqual(unifiedTexts(g), beforeUnified, "primary content intact after alt-screen resize")
        XCTAssertEqual(rowText(g.row(0)), "line15", "saved primary pulled from its scrollback")
    }
}
