import XCTest
@testable import DamsonTabGroups

/// The invariant is that a group's tabs occupy one unbroken index range. Collapsing,
/// moving a group, and "which group is this tab in" all rest on it, so every mutation is
/// checked against it here rather than trusted.
final class TabGroupLayoutTests: XCTestCase {

    private let a = TabGroup(name: "run-a")
    private let b = TabGroup(name: "run-b")

    /// Build a layout from a compact spelling: "a a . b" = two tabs in a, one loose, one in b.
    private func layout(_ spec: String) -> TabGroupLayout {
        var l = TabGroupLayout()
        l.define(a); l.define(b)
        for token in spec.split(separator: " ") {
            switch token {
            case "a": l.append(group: a.id)
            case "b": l.append(group: b.id)
            default:  l.append(group: nil)
            }
        }
        return l
    }

    private func spell(_ l: TabGroupLayout) -> String {
        l.membership.map { id in
            id == a.id ? "a" : id == b.id ? "b" : "."
        }.joined(separator: " ")
    }

    // MARK: - Insertion

    /// A tab joining a group must land next to that group, not wherever it was asked to go.
    /// Honouring the requested index would split the range on the very first insert.
    func testJoiningAGroupRelocatesToKeepItContiguous() {
        var l = layout("a a . .")
        let at = l.insert(group: a.id, at: 3)
        XCTAssertEqual(at, 2, "a tab joining group a landed outside it")
        XCTAssertEqual(spell(l), "a a a . .")
        XCTAssertTrue(l.isContiguous)
    }

    func testUngroupedInsertHonoursTheRequestedIndex() {
        var l = layout("a a . .")
        XCTAssertEqual(l.insert(group: nil, at: 1), 1)
        XCTAssertEqual(spell(l), "a . a . .")
    }

    func testAppendingToAnUnknownGroupGoesToTheEnd() {
        var l = layout("a a")
        let fresh = TabGroup(name: "run-c")
        l.define(fresh)
        XCTAssertEqual(l.append(group: fresh.id), 2)
        XCTAssertTrue(l.isContiguous)
    }

    // MARK: - Removal

    /// Removing from a contiguous range cannot break contiguity — but it can empty a group,
    /// and a group nobody is in must not linger in the tab bar.
    func testRemovingTheLastMemberDropsTheGroup() {
        var l = layout("a . .")
        l.remove(at: 0)
        XCTAssertNil(l.groups[a.id], "an empty group survived")
        XCTAssertEqual(spell(l), ". .")
    }

    func testRemovingAMiddleMemberKeepsTheGroup() {
        var l = layout("a a a")
        l.remove(at: 1)
        XCTAssertEqual(l.range(of: a.id), 0..<2)
        XCTAssertTrue(l.isContiguous)
    }

    // MARK: - Moving

    /// The rule that makes moves safe by construction: a tab joins a group only when both
    /// its neighbours are in that group. It can therefore never come to rest between two
    /// members of a group it is not in, so no move can split one.
    func testATabLandingInsideAGroupJoinsIt() {
        var l = layout("a a . b")
        l.move(from: 2, to: 1)
        XCTAssertEqual(spell(l), "a a a b")
        XCTAssertTrue(l.isContiguous)
    }

    func testATabLandingOnABoundaryStaysUngrouped() {
        var l = layout("a a . b")
        l.move(from: 2, to: 0)      // in front of group a, touching nothing on the left
        XCTAssertEqual(spell(l), ". a a b")
        XCTAssertTrue(l.isContiguous)
    }

    /// Dragging a tab out of its group and far away leaves the group behind, still whole.
    func testMovingAMemberAwayLeavesTheGroupContiguous() {
        var l = layout("a a a . .")
        l.move(from: 0, to: 4)
        XCTAssertEqual(spell(l), "a a . . .")
        XCTAssertTrue(l.isContiguous)
    }

    /// A member shuffled inside its own group stays in it — the common case of reordering
    /// tasks within a run.
    func testMovingWithinAGroupKeepsMembership() {
        var l = layout("a a a")
        l.move(from: 0, to: 2)
        XCTAssertEqual(spell(l), "a a a")
    }

    /// Every move, from anywhere to anywhere, over a layout with two groups and loose tabs.
    /// This is the test that would catch a rule that is right in the cases someone thought of.
    func testNoMoveEverBreaksContiguity() {
        for from in 0..<5 {
            for to in 0..<5 {
                var l = layout("a a . b b")
                l.move(from: from, to: to)
                XCTAssertTrue(l.isContiguous,
                              "move \(from)->\(to) produced \(spell(l))")
            }
        }
    }

    // MARK: - Assignment

    func testAssigningIntoAGroupRelocatesTheTab() {
        var l = layout("a a . .")
        let at = l.assign(at: 3, to: a.id)
        XCTAssertEqual(at, 2)
        XCTAssertEqual(spell(l), "a a a .")
        XCTAssertTrue(l.isContiguous)
    }

    func testAssigningOutOfAGroupLeavesItInPlace() {
        var l = layout("a a a")
        l.assign(at: 2, to: nil)
        XCTAssertEqual(spell(l), "a a .")
        XCTAssertTrue(l.isContiguous)
    }

    // MARK: - Ordering and lookup

    /// Group order is not stored; it is where the group's first tab sits. So moving a group
    /// reorders them, and there is no second ordering to fall out of sync.
    func testGroupOrderFollowsTheFirstTab() {
        var l = layout("b b . a")
        XCTAssertEqual(l.orderedGroups().map(\.name), ["run-b", "run-a"])
        l.moveGroup(a.id, to: 0)
        XCTAssertEqual(spell(l), "a b b .")
        XCTAssertEqual(l.orderedGroups().map(\.name), ["run-a", "run-b"])
    }

    /// Moving a *member* tab can only take it out of its group — so for a group of one,
    /// dragging the tab dissolves the group. That is why `moveGroup` exists: dragging the
    /// header is a different gesture, and without it a one-tab group could not be moved at
    /// all without being destroyed.
    func testMovingTheOnlyMemberDissolvesTheGroup() {
        var l = layout("a . .")
        l.move(from: 0, to: 2)
        XCTAssertEqual(spell(l), ". . .")
        XCTAssertNil(l.groups[a.id])

        var whole = layout("a . .")
        whole.moveGroup(a.id, to: 2)
        XCTAssertEqual(spell(whole), ". . a")
        XCTAssertNotNil(whole.groups[a.id], "moving the group must not destroy it")
    }

    /// A group must never come to rest inside another group.
    func testMovingAGroupNeverSplitsAnother() {
        for dest in 0..<6 {
            var l = layout("a a . b b")
            l.moveGroup(a.id, to: dest)
            XCTAssertTrue(l.isContiguous, "moveGroup to \(dest) produced \(spell(l))")
            XCTAssertEqual(l.range(of: b.id)?.count, 2, "group b was split by \(spell(l))")
        }
    }

    /// Names are for humans and are not unique. Lookup returns the first on screen, which is
    /// the only answer a user could predict.
    func testLookupByNameReturnsTheFirstOnScreen() {
        var l = TabGroupLayout()
        let one = TabGroup(name: "dup"), two = TabGroup(name: "dup")
        l.define(one); l.define(two)
        l.append(group: two.id)
        l.append(group: one.id)
        XCTAssertEqual(l.group(named: "dup")?.id, two.id)
    }

    func testIsContiguousDetectsASplitGroup() {
        var l = TabGroupLayout()
        l.define(a)
        l.membership = [a.id, nil, a.id]
        XCTAssertFalse(l.isContiguous)
    }
}
