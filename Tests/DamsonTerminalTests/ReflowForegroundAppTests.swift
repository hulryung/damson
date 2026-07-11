import AppKit
import XCTest
@testable import DamsonTerminal

/// Regression tests for reflow while a foreground app owns the screen.
///
/// Field bug (§zoom clip): with an app running, the nearest OSC 133;A mark is the
/// prompt the app was LAUNCHED from — far above its output. Treating everything from
/// that mark as the shell's "live prompt block" preserved it physically (clip/pad, no
/// rewrap), so zooming in over a wide TUI table truncated every row at the new width;
/// zooming back out could not restore them. `preservePromptBlock: false` (passed by
/// DamsonSession while `hasRunningForegroundJob`) rewraps that span losslessly instead.
final class ReflowForegroundAppTests: XCTestCase {
    private func write(_ g: Grid, _ s: String) { for ch in s { g.putChar(ch) } }
    private func newline(_ g: Grid) { g.lineFeed(); g.carriageReturn() }

    /// Logical lines (scrollback + viewport), soft-wraps rejoined, trailing blanks trimmed.
    private func logicalText(_ g: Grid) -> [String] {
        var phys: [(cells: [Cell], wrapped: Bool)] = g.scrollback.map { ($0.cells, $0.wrapped) }
        for r in 0..<g.rows { phys.append((g.row(r), g.rowWrapped(r))) }
        var out: [String] = []
        var cur = ""
        for (cells, wrapped) in phys {
            for c in cells where !c.isContinuation && !c.isWideSpacer { cur.append(c.char) }
            if !wrapped {
                while cur.hasSuffix(" ") { cur.removeLast() }
                out.append(cur)
                cur = ""
            }
        }
        if !cur.isEmpty { while cur.hasSuffix(" ") { cur.removeLast() }; out.append(cur) }
        while let last = out.last, last.isEmpty { out.removeLast() }
        return out
    }

    /// The field scenario: a marked prompt row (where the app was launched), wide app
    /// output rows below it, cursor at the bottom (app still running, no new prompt).
    private func makeAppScreen() -> Grid {
        let g = Grid(cols: 40, rows: 8, pen: CellAttrs(fg: .default))
        g.markPromptStart()
        write(g, "prompt$ app")
        newline(g)
        write(g, "+------- WIDE TABLE TOP -------- END1+")   // 38 cols — fits at 40
        newline(g)
        write(g, "| row content abcdefghijklmnop END2 |")
        newline(g)
        write(g, "+------- WIDE TABLE BOT -------- END3+")
        newline(g)
        return g
    }

    func testForegroundReflowKeepsContentAcrossShrinkAndRestore() {
        let g = makeAppScreen()
        let before = logicalText(g)
        XCTAssertTrue(before.contains { $0.hasSuffix("END1+") }, "precondition")

        // App running → no physical preservation: shrink must rewrap, not clip.
        g.resize(cols: 25, rows: 8, preservePromptBlock: false)
        let narrow = logicalText(g)
        for suffix in ["END1+", "END2 |", "END3+"] {
            XCTAssertTrue(narrow.contains { $0.hasSuffix(suffix) },
                          "content must survive the shrink (rewrapped): \(suffix)")
        }

        // Widen back — the rows must be fully restored, not left truncated.
        g.resize(cols: 40, rows: 8, preservePromptBlock: false)
        let restored = logicalText(g)
        for line in before where !line.isEmpty {
            XCTAssertTrue(restored.contains(line), "row must restore intact: \(line)")
        }
    }

    func testAtPromptReflowStillPreservesPromptBlockPhysically() {
        // At the prompt (default preservePromptBlock: true) the marked block keeps its
        // physical row count so the shell's ↑N+erase redraw stays consistent — the
        // original invariant, unchanged by the foreground fix.
        let g = Grid(cols: 40, rows: 8, pen: CellAttrs(fg: .default))
        write(g, "finished output line")
        newline(g)
        g.markPromptStart()
        write(g, "PROMPT> ")
        g.resize(cols: 25, rows: 8)   // default: preserve
        // The prompt row is still exactly one physical row with the mark on it.
        var markedRows = 0
        for r in 0..<g.rows where g.rowIsPromptStart(r) { markedRows += 1 }
        XCTAssertEqual(markedRows, 1, "prompt mark row preserved as one physical row")
    }

    func testPromptMarksSurviveRewrap() {
        // Marks in the REWRAP span used to be dropped (breaking ⌘↑ prompt jumps after
        // any width change). They must survive on the first row of the logical line.
        let g = makeAppScreen()
        g.resize(cols: 25, rows: 8, preservePromptBlock: false)
        var marks = g.scrollback.filter { $0.isPromptStart }.count
        for r in 0..<g.rows where g.rowIsPromptStart(r) { marks += 1 }
        XCTAssertEqual(marks, 1, "the launch prompt's mark must survive the rewrap")
    }
}
