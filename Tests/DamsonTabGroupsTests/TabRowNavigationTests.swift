import XCTest
@testable import DamsonTabGroups

/// Stepping along the visible row (scroll wheel over the tab bar).
final class TabRowNavigationTests: XCTestCase {
    func testStepsToTheAdjacentTab() {
        XCTAssertEqual(TabRow.neighbor(of: 1, count: 4, hidden: [], next: true), 2)
        XCTAssertEqual(TabRow.neighbor(of: 1, count: 4, hidden: [], next: false), 0)
    }

    func testWrapsAtBothEnds() {
        XCTAssertEqual(TabRow.neighbor(of: 3, count: 4, hidden: [], next: true), 0)
        XCTAssertEqual(TabRow.neighbor(of: 0, count: 4, hidden: [], next: false), 3)
    }

    func testSkipsFoldedTabs() {
        // Tabs 1 and 2 are folded into a collapsed group: 0 → 3, not 0 → 1.
        XCTAssertEqual(TabRow.neighbor(of: 0, count: 4, hidden: [1, 2], next: true), 3)
        XCTAssertEqual(TabRow.neighbor(of: 3, count: 4, hidden: [1, 2], next: false), 0)
    }

    func testWrapsOverFoldedTabsAtTheEnd() {
        XCTAssertEqual(TabRow.neighbor(of: 0, count: 4, hidden: [2, 3], next: false), 1)
        XCTAssertEqual(TabRow.neighbor(of: 1, count: 4, hidden: [2, 3], next: true), 0)
    }

    func testStepsFromAFoldedSelection() {
        // A group collapsed around the active tab: keep going from where it sits.
        XCTAssertEqual(TabRow.neighbor(of: 2, count: 5, hidden: [1, 2, 3], next: true), 4)
        XCTAssertEqual(TabRow.neighbor(of: 2, count: 5, hidden: [1, 2, 3], next: false), 0)
        // ...and wrap when that side of the row is empty.
        XCTAssertEqual(TabRow.neighbor(of: 1, count: 3, hidden: [0, 1], next: false), 2)
        XCTAssertEqual(TabRow.neighbor(of: 1, count: 3, hidden: [1, 2], next: true), 0)
    }

    func testNowhereToGo() {
        XCTAssertNil(TabRow.neighbor(of: 0, count: 1, hidden: [], next: true))
        XCTAssertNil(TabRow.neighbor(of: 0, count: 0, hidden: [], next: true))
        // One visible tab plus folded ones is still nowhere to go.
        XCTAssertNil(TabRow.neighbor(of: 0, count: 3, hidden: [1, 2], next: true))
    }
}
