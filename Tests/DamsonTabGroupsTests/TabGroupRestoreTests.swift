import XCTest
@testable import DamsonTabGroups

/// Restore is the dangerous half. `SessionRestore.load()` decodes the whole state under a
/// single `try?`, so anything here that throws or refuses does not lose the groups — it
/// loses **every window's layout**. Every case below therefore has to be a repair, and
/// these tests exist to prove each one repairs rather than rejects.
final class TabGroupRestoreTests: XCTestCase {

    private let a = TabGroup(name: "run-a")
    private let b = TabGroup(name: "run-b")

    // MARK: - The no-groups case

    /// The blob for an ordinary window must not gain a key. Anything else changes the bytes
    /// of every saved window on earth for a feature they do not use.
    func testAWindowWithNoGroupsSerializesToNothing() {
        var l = TabGroupLayout()
        l.append(group: nil)
        l.append(group: nil)
        XCTAssertNil(l.restorable(), "an ungrouped window produced a payload")
    }

    /// And the reverse: no payload restores to a working, empty layout of the right size —
    /// not to something that then mismatches the tab array.
    func testNoPayloadRestoresAnEmptyLayoutOfTheRightSize() {
        let (l, order) = TabGroupLayout.restore(nil, tabCount: 3)
        XCTAssertEqual(l.membership, [nil, nil, nil])
        XCTAssertTrue(l.isEmpty)
        XCTAssertEqual(order, [0, 1, 2], "nothing to move, so the order must be the identity")
    }

    // MARK: - Round trip

    func testRoundTripPreservesGroupsAndMembership() throws {
        var l = TabGroupLayout()
        l.define(a); l.define(b)
        l.append(group: a.id); l.append(group: a.id)
        l.append(group: nil); l.append(group: b.id)

        let payload = try XCTUnwrap(l.restorable())
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(RestorableTabGroups.self, from: data)

        let (back, order) = TabGroupLayout.restore(decoded, tabCount: 4)
        XCTAssertEqual(back.membership, l.membership)
        XCTAssertEqual(back.groups, l.groups)
        XCTAssertEqual(order, [0, 1, 2, 3])
    }

    func testGroupFieldsSurviveTheRoundTrip() throws {
        var l = TabGroupLayout()
        l.define(TabGroup(id: a.id, name: "run-a", colorIndex: 4, collapsed: true))
        l.append(group: a.id)

        let payload = try XCTUnwrap(l.restorable())
        let decoded = try JSONDecoder().decode(RestorableTabGroups.self,
                                               from: try JSONEncoder().encode(payload))
        let (back, _) = TabGroupLayout.restore(decoded, tabCount: 1)
        XCTAssertEqual(back.groups[a.id]?.colorIndex, 4)
        XCTAssertEqual(back.groups[a.id]?.collapsed, true)
    }

    // MARK: - Repairs

    /// The window gained or lost tabs since the payload was written — a downgrade that
    /// dropped a pane, or hand-edited defaults. Membership cannot be aligned with the tabs,
    /// and guessing an alignment would put tabs in groups they were never in. Drop the
    /// groups; keep the windows.
    func testMembershipOfTheWrongLengthDropsGroupsAndKeepsTheLayout() {
        let saved = RestorableTabGroups(groups: [a], membership: [a.id.uuidString, nil])
        for tabCount in [1, 3, 0] {
            let (l, order) = TabGroupLayout.restore(saved, tabCount: tabCount)
            XCTAssertEqual(l.membership.count, tabCount,
                           "layout must still match the window's tab count")
            XCTAssertTrue(l.isEmpty)
            XCTAssertEqual(order, Array(0..<tabCount))
        }
    }

    /// A membership entry that is not a UUID at all. Decoding these as `String?` rather than
    /// `UUID?` is the whole point: as a UUID the decode would throw, and one bad character
    /// in the blob would cost the user every window.
    func testAMalformedIdRestoresAsUngrouped() {
        let saved = RestorableTabGroups(groups: [a],
                                        membership: ["not-a-uuid", a.id.uuidString])
        let (l, _) = TabGroupLayout.restore(saved, tabCount: 2)
        XCTAssertEqual(l.membership, [nil, a.id])
        XCTAssertEqual(l.groups.count, 1)
    }

    /// A tab pointing at a group that was not saved. The tab is real, the group is not.
    func testAnIdNamingNoSavedGroupRestoresAsUngrouped() {
        let saved = RestorableTabGroups(groups: [a],
                                        membership: [a.id.uuidString, b.id.uuidString])
        let (l, _) = TabGroupLayout.restore(saved, tabCount: 2)
        XCTAssertEqual(l.membership, [a.id, nil])
        XCTAssertNil(l.groups[b.id])
    }

    /// A saved group nothing points at would otherwise show up as an empty header.
    func testAGroupWithNoMembersIsDropped() {
        let saved = RestorableTabGroups(groups: [a, b], membership: [a.id.uuidString])
        let (l, _) = TabGroupLayout.restore(saved, tabCount: 1)
        XCTAssertEqual(l.groups.count, 1)
        XCTAssertNotNil(l.groups[a.id])
    }

    /// Saved data whose groups are interleaved — written by a version with different rules,
    /// or edited by hand. Repair it and report the permutation, so the caller can move the
    /// real tabs to match instead of the model and the screen disagreeing.
    func testInterleavedMembershipIsNormalisedAndReported() {
        let saved = RestorableTabGroups(
            groups: [a, b],
            membership: [a.id.uuidString, b.id.uuidString, a.id.uuidString, b.id.uuidString])
        let (l, order) = TabGroupLayout.restore(saved, tabCount: 4)
        XCTAssertTrue(l.isContiguous)
        XCTAssertEqual(order, [0, 2, 1, 3], "the permutation must say how to move the tabs")
        XCTAssertEqual(l.membership, order.map { [a.id, b.id, a.id, b.id][$0] })
    }

    /// Already-contiguous data must come back untouched, or an ordinary restore would
    /// shuffle the user's tabs for no reason.
    func testContiguousMembershipIsLeftAlone() {
        let saved = RestorableTabGroups(
            groups: [a, b],
            membership: [a.id.uuidString, a.id.uuidString, nil, b.id.uuidString])
        let (l, order) = TabGroupLayout.restore(saved, tabCount: 4)
        XCTAssertEqual(order, [0, 1, 2, 3])
        XCTAssertEqual(l.membership, [a.id, a.id, nil, b.id])
    }

    /// Ungrouped tabs must not be pulled together by normalisation — only groups are
    /// contiguous, loose tabs keep their positions.
    func testUngroupedTabsAreNotGatheredTogether() {
        let saved = RestorableTabGroups(
            groups: [a], membership: [nil, a.id.uuidString, nil])
        let (l, order) = TabGroupLayout.restore(saved, tabCount: 3)
        XCTAssertEqual(order, [0, 1, 2])
        XCTAssertEqual(l.membership, [nil, a.id, nil])
    }

    // MARK: - Forward compatibility

    /// A payload from a newer build carrying fields this one does not know must still
    /// decode. Failing here would propagate up to the single `try?` and lose the layout.
    func testUnknownFieldsInThePayloadStillDecode() throws {
        let json = """
        {"groups":[{"id":"\(a.id.uuidString)","name":"run-a","collapsed":false,\
        "pinned":true,"icon":"rocket"}],"membership":["\(a.id.uuidString)"],"version":9}
        """
        let decoded = try JSONDecoder().decode(RestorableTabGroups.self, from: Data(json.utf8))
        let (l, _) = TabGroupLayout.restore(decoded, tabCount: 1)
        XCTAssertEqual(l.groups[a.id]?.name, "run-a")
    }
}
