import XCTest
@testable import DamsonTerminal

/// An oversized glyph — a Nerd icon from a non-Mono variant or from a Nerd face
/// standing in for a half-width base font, or a full-width symbol design — draws at
/// the size its font designed into a box made of its own cell and the next one, but
/// only where that next cell is blank. Otherwise the renderer swaps in the
/// shrink-to-one-cell variant. This is the rule kitty, WezTerm and Ghostty use, and it
/// replaced the "Double-width icons" setting: the decision is made per instance,
/// where the overlap would actually happen.
final class IconOverflowRuleTests: XCTestCase {
    private let icon: Character = "\u{E70E}"       // Devicons — an oversized icon
    private let arrow: Character = "\u{E0B0}"      // Powerline separator — tiles, never oversized

    private func row(_ chars: [Character]) -> [Cell] {
        var cells: [Cell] = []
        for ch in chars {
            cells.append(Cell(char: ch, attrs: CellAttrs(fg: .default)))
            if Cell.isWide(ch) {
                cells.append(Cell(char: " ", attrs: CellAttrs(fg: .default), isContinuation: true))
            }
        }
        return cells
    }

    private func may(_ chars: [Character], col: Int) -> Bool {
        MetalTerminalBackend.mayOverflowRight(row(chars), col: col, wcells: 1)
    }

    func testBlankNextCellGrantsTheBox() {
        XCTAssertTrue(may([" ", icon, " "], col: 1))
    }

    func testOccupiedNextCellForcesFit() {
        XCTAssertFalse(may([" ", icon, "x"], col: 1))
    }

    func testWideGlyphNextForcesFit() {
        XCTAssertFalse(may([" ", icon, "한"], col: 1))
    }

    func testEndOfRowForcesFit() {
        XCTAssertFalse(may([" ", icon], col: 1), "nothing to spill into past the last column")
    }

    /// The cell on the left is not consulted: text right before an icon is the common
    /// "on  main" shape and must not shrink the icon.
    func testLeftNeighborIsIgnored() {
        XCTAssertTrue(may(["x", icon, " "], col: 1))
        XCTAssertTrue(may(["한", icon, " "], col: 2))
    }

    /// A run of icons stays one cell each so they line up (Ghostty's rule).
    func testIconAfterIconForcesFit() {
        XCTAssertFalse(may([icon, icon, " "], col: 1))
    }

    /// …but a Powerline shape before an icon is a segment edge, not a neighboring
    /// icon: the icon after it keeps its box.
    func testIconAfterPowerlineKeepsTheBox() {
        XCTAssertTrue(may([arrow, icon, " "], col: 1))
    }

    /// Full-width symbols (①) are not icons, so the icon-run rule does not apply.
    func testFullWidthSymbolAfterSymbolKeepsTheBox() {
        XCTAssertTrue(may(["①", "②", " "], col: 1))
    }
}
