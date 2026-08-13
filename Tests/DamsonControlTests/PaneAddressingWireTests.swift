import XCTest
@testable import DamsonControl

/// Stage 3 added pane addressing to a wire format that damson-cli speaks and that another
/// repo links as a library product. So the first duty of these tests is NOT the new
/// commands — it is proving the old ones did not move: same JSON out, same meaning in.
final class PaneAddressingWireTests: XCTestCase {

    private func decode(_ json: String) throws -> ControlCommand {
        try JSONDecoder().decode(ControlCommand.self, from: Data(json.utf8))
    }

    // MARK: - Compatibility

    /// Every pre-existing command must encode to exactly the bytes it always did. A new
    /// optional field that leaks into these payloads would break any peer matching on them.
    func testExistingCommandsEncodeByteIdentically() {
        let cases: [(ControlCommandKind, String)] = [
            (.newTab, #"{"cmd":"new-tab"}"#),
            (.closeTab, #"{"cmd":"close-tab"}"#),
            (.listTabs, #"{"cmd":"list-tabs"}"#),
            (.closePane, #"{"cmd":"close-pane"}"#),
            (.listPanes, #"{"cmd":"list-panes"}"#),
            (.dumpGrid, #"{"cmd":"dump-grid"}"#),
            (.split(.horizontal), #"{"cmd":"split","args":{"dir":"horizontal"}}"#),
            (.switchTab(index: 2), #"{"cmd":"switch-tab","args":{"index":2}}"#),
            (.sendText("ls -la"), #"{"cmd":"send-text","args":{"text":"ls -la"}}"#),
            (.sendKeys(["enter"]), #"{"cmd":"send-key","args":{"keys":["enter"]}}"#),
            (.resizeWindow(cols: 120, rows: 40), #"{"cmd":"resize-window","args":{"cols":120,"rows":40}}"#),
            (.resizePane(dir: .right, amount: 3), #"{"cmd":"resize-pane","args":{"dir":"right","amount":3}}"#),
            (.focusPane(dir: .left), #"{"cmd":"focus-pane","args":{"dir":"left"}}"#),
            (.zoom("in"), #"{"cmd":"zoom","args":{"action":"in"}}"#),
            (.applyLayout("grid2x2"), #"{"cmd":"layout","args":{"name":"grid2x2"}}"#),
        ]
        for (kind, expected) in cases {
            XCTAssertEqual(encodeCommand(kind), expected)
            // And with no target, the targeted encoder must produce the same bytes.
            XCTAssertEqual(encodeCommand(kind, target: .active), expected)
        }
    }

    /// JSON written before pane addressing existed has no `"pane"` key. It must keep meaning
    /// exactly what it meant: the active pane.
    func testCommandWithoutPaneKeyTargetsTheActivePane() throws {
        for json in [#"{"cmd":"new-tab"}"#,
                     #"{"cmd":"send-text","args":{"text":"hi"}}"#,
                     #"{"cmd":"split","args":{"dir":"vertical"}}"#] {
            XCTAssertEqual(try decode(json).target, .active, "\(json) must default to .active")
        }
    }

    /// An empty target is not a target — otherwise a client interpolating a missing id would
    /// address a pane called "".
    func testEmptyPaneKeyIsTreatedAsActive() throws {
        XCTAssertEqual(try decode(#"{"cmd":"new-tab","pane":""}"#).target, .active)
    }

    func testPaneTargetRoundTrips() throws {
        let id = "6E7F1B2C-0000-4000-8000-000000000001"
        let json = encodeCommand(.sendText("hi"), target: .id(id))
        let cmd = try decode(json)
        XCTAssertEqual(cmd.target, .id(id))
        XCTAssertEqual(cmd.kind, .sendText("hi"), "the target must not disturb the payload")
    }

    /// `PaneInfo` grew six optional fields. An ordinary pane's row must still serialize as
    /// the original four keys — nils omitted, not encoded as null.
    func testPaneInfoWithoutTheNewFieldsIsUnchanged() throws {
        let data = try JSONEncoder().encode(PaneInfo(index: 0, cols: 80, rows: 24, active: true))
        let json = String(decoding: data, as: UTF8.self)
        for absent in ["id", "tab", "pid", "cwd", "title", "agent", "null"] {
            XCTAssertFalse(json.contains("\"\(absent)\""), "\(absent) must not appear: \(json)")
        }
        XCTAssertFalse(json.contains("null"), "nil fields must be omitted, not null: \(json)")
        // And it still decodes into the same value.
        XCTAssertEqual(try JSONDecoder().decode(PaneInfo.self, from: data),
                       PaneInfo(index: 0, cols: 80, rows: 24, active: true))
    }

    func testControlResponseWithoutAPaneIsUnchanged() throws {
        let data = try JSONEncoder().encode(ControlResponse.ok())
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"ok":true}"#)
    }

    // MARK: - The new commands

    func testSpawnPaneRoundTrips() throws {
        let spec = SpawnSpec(split: .vertical, cwd: "/p", argv: ["claude", "-w", "feat"], key: "k1")
        let cmd = try decode(encodeCommand(.spawnPane(spec)))
        XCTAssertEqual(cmd.kind, .spawnPane(spec))
    }

    func testSpawnPaneMinimalFormOmitsAbsentFields() throws {
        let json = encodeCommand(.spawnPane(SpawnSpec(argv: ["claude"])))
        XCTAssertEqual(json, #"{"cmd":"spawn-pane","args":{"argv":["claude"]}}"#)
        XCTAssertEqual(try decode(json).kind, .spawnPane(SpawnSpec(argv: ["claude"])))
    }

    /// An empty argv would open a pane that runs nothing — reject it at the boundary rather
    /// than trapping in `PTYHost.spawn`, which has a precondition on exactly this.
    func testSpawnPaneRejectsEmptyArgv() {
        XCTAssertThrowsError(try decode(#"{"cmd":"spawn-pane","args":{"argv":[]}}"#))
    }

    func testSpawnArgvSurvivesQuotingAndUnicode() throws {
        let argv = ["claude", "-p", #"say "hi"\n"#, "경로/한글", "tab\there"]
        let cmd = try decode(encodeCommand(.spawnPane(SpawnSpec(argv: argv))))
        guard case .spawnPane(let spec) = cmd.kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(spec.argv, argv)
    }

    func testListAgentsAndPaneInfoRoundTrip() throws {
        XCTAssertEqual(encodeCommand(.listAgents), #"{"cmd":"list-agents"}"#)
        XCTAssertEqual(encodeCommand(.paneInfo), #"{"cmd":"pane-info"}"#)
        XCTAssertEqual(try decode(#"{"cmd":"list-agents"}"#).kind, .listAgents)
        XCTAssertEqual(try decode(#"{"cmd":"pane-info"}"#).kind, .paneInfo)
    }

    func testPaneInfoResponseCarriesTheNewFields() throws {
        let info = PaneInfo(index: 1, cols: 80, rows: 24, active: true,
                            id: "ID", tab: 2, pid: 4242, cwd: "/p", title: "t", agent: "busy")
        let data = try JSONEncoder().encode(ControlResponse.pane(info))
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: data)
        XCTAssertEqual(decoded.pane, info)
        XCTAssertTrue(decoded.ok)
    }

    func testUnknownCommandStillFails() {
        XCTAssertThrowsError(try decode(#"{"cmd":"teleport"}"#))
    }
}
