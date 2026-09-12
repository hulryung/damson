import XCTest
@testable import DamsonTabGroups

/// Colour assignment for new groups.
final class TabGroupColorTests: XCTestCase {
    private func layout(colors: [Int?]) -> TabGroupLayout {
        var l = TabGroupLayout()
        for (i, c) in colors.enumerated() {
            let g = TabGroup(name: "g\(i)", colorIndex: c)
            l.define(g)
            _ = l.append(group: g.id)
        }
        return l
    }

    func testFirstGroupTakesTheFirstSlot() {
        XCTAssertEqual(TabGroupLayout().nextColorIndex(paletteCount: 8), 0)
    }

    func testSkipsSlotsAlreadyInUse() {
        XCTAssertEqual(layout(colors: [0, 1]).nextColorIndex(paletteCount: 8), 2)
    }

    func testFillsAGapLeftByAClosedGroup() {
        XCTAssertEqual(layout(colors: [0, 2]).nextColorIndex(paletteCount: 8), 1)
    }

    func testRoundRobinsOnceEverySlotIsTaken() {
        XCTAssertEqual(layout(colors: [0, 1, 2]).nextColorIndex(paletteCount: 3), 0)
    }

    func testUncolouredGroupsDoNotReserveASlot() {
        // Groups from before colours existed must not push a new group off slot 0.
        XCTAssertEqual(layout(colors: [nil, nil]).nextColorIndex(paletteCount: 8), 0)
    }

    func testEmptyPaletteIsNotADivideByZero() {
        XCTAssertEqual(layout(colors: [0]).nextColorIndex(paletteCount: 0), 0)
    }
}
