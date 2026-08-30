import XCTest
@testable import DamsonControl

/// Group commands on the wire. `DamsonControl` is a public library product another repo
/// links, so the first duty is the same as for every addition before this one: prove the
/// payloads that already exist did not move.
final class GroupWireTests: XCTestCase {

    private func decode(_ json: String) throws -> ControlCommand {
        try JSONDecoder().decode(ControlCommand.self, from: Data(json.utf8))
    }

    // MARK: - Compatibility

    /// A spawn with no group must encode to exactly the bytes it did before the field
    /// existed. The encoder is hand-rolled and appends optionals conditionally, so this is
    /// what catches an unconditional append.
    func testSpawnWithoutGroupIsByteIdentical() {
        XCTAssertEqual(encodeCommand(.spawnPane(SpawnSpec(argv: ["claude"]))),
                       #"{"cmd":"spawn-pane","args":{"argv":["claude"]}}"#)
        XCTAssertEqual(
            encodeCommand(.spawnPane(SpawnSpec(split: .vertical, cwd: "/p", argv: ["claude"],
                                               key: "k1", title: "review-api"))),
            #"{"cmd":"spawn-pane","args":{"split":"vertical","cwd":"/p","argv":["claude"],"key":"k1","title":"review-api"}}"#)
    }

    func testSpawnPayloadWithoutGroupStillDecodes() throws {
        guard case .spawnPane(let spec) =
                try decode(#"{"cmd":"spawn-pane","args":{"argv":["claude"],"title":"t"}}"#).kind
        else { return XCTFail("wrong kind") }
        XCTAssertNil(spec.group)
    }

    /// A pane row for an ungrouped pane must keep exactly the keys it had. `agents` output is
    /// parsed by scripts, and a new always-present key changes every row.
    func testPaneInfoWithoutGroupOmitsTheKey() throws {
        let info = PaneInfo(index: 0, cols: 80, rows: 24, active: false, id: "X")
        let json = String(data: try JSONEncoder().encode(info), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("group"), json)
    }

    // MARK: - spawn --group

    func testSpawnGroupRoundTrips() throws {
        let spec = SpawnSpec(argv: ["claude"], key: "k", title: "t", group: "run-7")
        let json = encodeCommand(.spawnPane(spec))
        XCTAssertTrue(json.contains(#""group":"run-7""#), json)
        guard case .spawnPane(let back) = try decode(json).kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(back, spec)
    }

    /// Group names come from humans and issue trackers.
    func testGroupNameIsEscaped() throws {
        let spec = SpawnSpec(argv: ["claude"], group: #"run "7" \ b"#)
        guard case .spawnPane(let back) = try decode(encodeCommand(.spawnPane(spec))).kind else {
            return XCTFail("wrong kind")
        }
        XCTAssertEqual(back.group, #"run "7" \ b"#)
    }

    // MARK: - group commands

    func testGroupCommandsEncodeAndDecode() throws {
        let cases: [(ControlCommandKind, String)] = [
            (.listGroups, #"{"cmd":"group-list"}"#),
            (.closeGroup("run-7"), #"{"cmd":"group-close","args":{"name":"run-7"}}"#),
            (.setGroupCollapsed("run-7", true), #"{"cmd":"group-collapse","args":{"name":"run-7","collapsed":true}}"#),
            (.setGroupCollapsed("run-7", false), #"{"cmd":"group-collapse","args":{"name":"run-7","collapsed":false}}"#),
            (.renameGroup("run-7", to: "run-8"), #"{"cmd":"group-rename","args":{"name":"run-7","to":"run-8"}}"#),
        ]
        for (kind, expected) in cases {
            XCTAssertEqual(encodeCommand(kind), expected)
            XCTAssertEqual(try decode(expected).kind, kind)
        }
    }

    func testGroupInfoRoundTrips() throws {
        let g = GroupInfo(name: "run-7", tabs: 3, collapsed: true, colorIndex: 2)
        let back = try JSONDecoder().decode(GroupInfo.self, from: try JSONEncoder().encode(g))
        XCTAssertEqual(back, g)
    }

    func testResponseCarriesGroups() throws {
        let resp = ControlResponse.groups([GroupInfo(name: "run-7", tabs: 1)])
        let json = String(data: try JSONEncoder().encode(resp), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains(#""groups""#), json)
        // …and an ordinary ok() must still be exactly `{"ok":true}`.
        XCTAssertEqual(String(data: try JSONEncoder().encode(ControlResponse.ok()),
                              encoding: .utf8), #"{"ok":true}"#)
    }

    /// A group name is the whole payload of a destructive command. An empty one is a client
    /// interpolating an unset variable, and must not decode into "close the group called ''".
    func testEmptyGroupNameIsRejected() {
        for json in [#"{"cmd":"group-close","args":{"name":""}}"#,
                     #"{"cmd":"group-rename","args":{"name":"a","to":""}}"#] {
            XCTAssertThrowsError(try decode(json), json)
        }
    }
}
