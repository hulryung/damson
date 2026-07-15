import XCTest
@testable import DamsonTerminal

/// Regression for the "TUI line breaks" report: with `treatAmbiguousAsWide` on, the
/// geometric-shape particles Claude Code's compacting animation scatters (U+25A0
/// block) used to get 2 grid cells in Damson while the app laid them out assuming 1
/// (string-width/wcwidth = 1) — so everything after each particle drifted right and
/// the row broke. Geometric shapes / arrows / suits are now excluded from the
/// full-width set precisely because TUIs draw them as one-cell glyphs.
final class AmbiguousWidthDriftTests: XCTestCase {
    override func tearDown() {
        Cell.treatAmbiguousAsWide = false   // process-global; don't leak into other tests
        super.tearDown()
    }

    private func write(_ g: Grid, _ s: String) { for ch in s { g.putChar(ch) } }

    /// Column at which a trailing marker lands after the animation-like particle run.
    private func markerColumn(ambiguousWide: Bool) -> Int {
        Cell.treatAmbiguousAsWide = ambiguousWide
        let g = Grid(cols: 40, rows: 4, pen: CellAttrs(fg: .default))
        write(g, "▱ ▪ ◇ X")   // "▱0 ' '1 ▪2 ' '3 ◇4 ' '5 X6" if every glyph is 1 cell
        let cells = g.row(0)
        for (i, c) in cells.enumerated() where c.char == "X" { return i }
        return -1
    }

    func testGeometricParticlesStayOneCellWithSettingOff() {
        XCTAssertEqual(markerColumn(ambiguousWide: false), 6,
                       "Default: ambiguous geometric shapes occupy 1 cell")
    }

    func testGeometricParticlesStayOneCellEvenWithSettingOn() {
        // The fix: geometric shapes are excluded from the full-width set, so enabling
        // the setting no longer drifts TUI particles / spinners / bullets.
        XCTAssertEqual(markerColumn(ambiguousWide: true), 6,
                       "Geometric shapes must NOT be widened — they are TUI drawing glyphs")
    }

    func testArrowsAndSuitsAreNotWidened() {
        Cell.treatAmbiguousAsWide = true
        for ch: Character in ["→", "←", "↑", "↓", "●", "○", "■", "□", "◇", "▶", "♪", "♠"] {
            XCTAssertFalse(Cell.isWide(ch), "\(ch) is a 1-cell TUI drawing glyph, must not widen")
        }
    }

    func testCircledNumbersRemainTheIntendedFullWidthTarget() {
        Cell.treatAmbiguousAsWide = true
        for ch: Character in ["①", "⑳", "Ⓐ", "ⓐ", "❶", "※", "★", "℃"] {
            XCTAssertTrue(Cell.isWide(ch), "\(ch) is the feature's intended full-width target")
        }
    }
}
