import XCTest
@testable import DamsonControl

/// `spawn-pane`'s window key on the wire. Same first duty as every field before it: the
/// payloads that already exist must not move, because `DamsonControl` is a public library
/// another repo links.
final class WindowWireTests: XCTestCase {

    private func decode(_ json: String) throws -> ControlCommand {
        try JSONDecoder().decode(ControlCommand.self, from: Data(json.utf8))
    }

    /// The hand-rolled encoder appends optionals conditionally; this catches an
    /// unconditional append.
    func testSpawnWithoutWindowIsByteIdentical() {
        XCTAssertEqual(encodeCommand(.spawnPane(SpawnSpec(argv: ["claude"]))),
                       #"{"cmd":"spawn-pane","args":{"argv":["claude"]}}"#)
        XCTAssertEqual(
            encodeCommand(.spawnPane(SpawnSpec(cwd: "/p", argv: ["claude"], key: "k1",
                                               title: "review-api", group: "run-7"))),
            #"{"cmd":"spawn-pane","args":{"cwd":"/p","argv":["claude"],"key":"k1","title":"review-api","group":"run-7"}}"#)
    }

    func testSpawnPayloadWithoutWindowStillDecodes() throws {
        guard case .spawnPane(let spec) =
                try decode(#"{"cmd":"spawn-pane","args":{"argv":["claude"],"group":"g"}}"#).kind
        else { return XCTFail("wrong kind") }
        XCTAssertNil(spec.window)
    }

    func testSpawnWindowRoundTrips() throws {
        let spec = SpawnSpec(argv: ["claude"], key: "k", title: "t", group: "run-7",
                             window: "crew:group:run-7")
        let json = encodeCommand(.spawnPane(spec))
        XCTAssertTrue(json.hasSuffix(#""group":"run-7","window":"crew:group:run-7"}}"#), json)
        guard case .spawnPane(let back) = try decode(json).kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(back, spec)
    }

    /// Window keys are derived from group names, which come from humans.
    func testWindowKeyIsEscaped() throws {
        let spec = SpawnSpec(argv: ["claude"], window: #"crew:group:run "7" \ b"#)
        guard case .spawnPane(let back) = try decode(encodeCommand(.spawnPane(spec))).kind else {
            return XCTFail("wrong kind")
        }
        XCTAssertEqual(back.window, #"crew:group:run "7" \ b"#)
    }
}
