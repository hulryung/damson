import XCTest
@testable import DamsonControl

/// `set-title` and `spawn-pane`'s `title`. `DamsonControl` is a public library product that
/// another repo links, so the first duty here is the same as everywhere else in this file's
/// neighbours: prove the payloads that already exist did not move.
final class SetTitleWireTests: XCTestCase {

    private func decode(_ json: String) throws -> ControlCommand {
        try JSONDecoder().decode(ControlCommand.self, from: Data(json.utf8))
    }

    // MARK: - Compatibility

    /// A `spawn-pane` with no title must encode to exactly the bytes it did before the
    /// field existed. The encoder is hand-rolled and appends optionals conditionally, so
    /// this is the test that catches an unconditional append.
    func testSpawnWithoutTitleIsByteIdentical() {
        let cases: [(SpawnSpec, String)] = [
            (SpawnSpec(argv: ["claude"]),
             #"{"cmd":"spawn-pane","args":{"argv":["claude"]}}"#),
            (SpawnSpec(split: .vertical, cwd: "/p", argv: ["claude", "-w", "feat"], key: "k1"),
             #"{"cmd":"spawn-pane","args":{"split":"vertical","cwd":"/p","argv":["claude","-w","feat"],"key":"k1"}}"#),
        ]
        for (spec, expected) in cases {
            XCTAssertEqual(encodeCommand(.spawnPane(spec)), expected)
        }
    }

    /// JSON written by an older client has no `title` key; it must still decode, with the
    /// field nil rather than the whole command failing.
    func testSpawnPayloadWithoutTitleStillDecodes() throws {
        let cmd = try decode(#"{"cmd":"spawn-pane","args":{"argv":["claude"]}}"#)
        guard case .spawnPane(let spec) = cmd.kind else { return XCTFail("wrong kind") }
        XCTAssertNil(spec.title)
        XCTAssertEqual(spec.argv, ["claude"])
    }

    // MARK: - spawn --title

    func testSpawnTitleRoundTrips() throws {
        let spec = SpawnSpec(cwd: "/p", argv: ["claude"], key: "k1", title: "review-api")
        let json = encodeCommand(.spawnPane(spec))
        XCTAssertTrue(json.contains(#""title":"review-api""#), json)
        guard case .spawnPane(let back) = try decode(json).kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(back, spec)
    }

    /// Labels come from task names, which come from humans and issue trackers. A quote or
    /// a backslash in one must not produce malformed JSON on the socket.
    func testSpawnTitleIsEscaped() throws {
        let spec = SpawnSpec(argv: ["claude"], title: #"fix "quoting" \ now"#)
        guard case .spawnPane(let back) = try decode(encodeCommand(.spawnPane(spec))).kind else {
            return XCTFail("wrong kind")
        }
        XCTAssertEqual(back.title, #"fix "quoting" \ now"#)
    }

    // MARK: - set-title

    func testSetTitleEncodesAndDecodes() throws {
        XCTAssertEqual(encodeCommand(.setTitle("review-api")),
                       #"{"cmd":"set-title","args":{"title":"review-api"}}"#)
        XCTAssertEqual(try decode(#"{"cmd":"set-title","args":{"title":"review-api"}}"#).kind,
                       .setTitle("review-api"))
    }

    /// The whole point of the command is naming a *background* agent's tab, so it has to
    /// carry a pane target like every other pane-addressed command.
    func testSetTitleCarriesAPaneTarget() throws {
        let id = "6E7F1B2C-0000-4000-8000-000000000001"
        let json = encodeCommand(.setTitle("review-api"), target: .id(id))
        let cmd = try decode(json)
        XCTAssertEqual(cmd.kind, .setTitle("review-api"))
        XCTAssertEqual(cmd.target, .id(id))
    }

    /// An empty title is the documented way to hand the tab back to the child, so it must
    /// survive the wire rather than being rejected as a missing argument.
    func testEmptyTitleRoundTripsAsAClear() throws {
        XCTAssertEqual(try decode(encodeCommand(.setTitle(""))).kind, .setTitle(""))
    }
}
