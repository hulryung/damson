import XCTest
@testable import DamsonComputer

final class ComputerEngineTests: XCTestCase {
    @MainActor
    func testStrictArgumentsCannotStopOrResume() async throws {
        let engine = ComputerEngine()
        let result = await engine.handle(ComputerRequest(command: "stop", arguments: ["pid": "1"]))
        XCTAssertFalse(try XCTUnwrap(response(result)["ok"] as? Bool))
        XCTAssertFalse(engine.sessions.paused)
        _ = await engine.handle(ComputerRequest(command: "stop"))
        XCTAssertTrue(engine.sessions.paused)
        let invalid = await engine.handle(ComputerRequest(command: "resume", arguments: ["unexpected": "true"]))
        XCTAssertFalse(try XCTUnwrap(response(invalid)["ok"] as? Bool))
        XCTAssertTrue(engine.sessions.paused)
    }

    @MainActor
    func testDuplicateRequestNeverRepeatsStateMutation() async throws {
        let engine = ComputerEngine()
        let stop = ComputerRequest(command: "stop")
        let first = await engine.handle(stop)
        _ = await engine.handle(ComputerRequest(command: "resume"))
        XCTAssertFalse(engine.sessions.paused)
        let repeated = await engine.handle(stop)
        XCTAssertEqual(first, repeated)
        XCTAssertFalse(engine.sessions.paused)
        let conflict = await engine.handle(ComputerRequest(id: stop.id, command: "resume"))
        let error = try XCTUnwrap(response(conflict)["error"] as? [String: String])
        XCTAssertEqual(error["code"], "request_id_reused")
    }

    @MainActor
    func testStatusDoesNotRevealSessionAuthority() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = ComputerEngine(root: root)
        let session = try engine.sessions.acquire(owner: "a", pid: 1, started: "x", ttl: 30)
        let data = await engine.handle(ComputerRequest(command: "status"))
        let result = try XCTUnwrap(response(data)["result"] as? [String: Any])
        let publicSession = try XCTUnwrap(result["session"] as? [String: Any])
        XCTAssertNil(publicSession["token"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(session.token))
        XCTAssertEqual(publicSession["owner"] as? String, session.owner)
    }

    @MainActor
    func testStopRejectsPreviouslyValidAuthorityBeforeTargetLookup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = ComputerEngine(root: root)
        let session = try engine.sessions.acquire(owner: "a", pid: 1, started: "x", ttl: 30)
        engine.stop()
        let data = await engine.handle(ComputerRequest(command: "key", arguments: ["session": session.token, "key": "enter"]))
        XCTAssertEqual((try response(data)["error"] as? [String: String])?["code"], "paused")
    }

    @MainActor
    func testDelayedInputFromBeforeAcquisitionDoesNotRevokeNewSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = ComputerEngine(root: root)
        let session = try engine.sessions.acquire(owner: "a", pid: 1, started: "x", ttl: 30)
        engine.interruptForInput(timestamp: session.inputStarted - 0.1, kind: "mouseMoved")
        XCTAssertEqual(engine.sessions.session?.token, session.token)
        XCTAssertFalse(engine.sessions.paused)
        engine.interruptForInput(timestamp: session.inputStarted + 0.1, kind: "mouseMoved")
        XCTAssertNil(engine.sessions.session)
        XCTAssertTrue(engine.sessions.paused)
        XCTAssertEqual(engine.sessions.pauseReason, "external_input:mouseMoved")
    }

    @MainActor
    func testInvalidPermissionSectionDoesNotOpenSetup() async throws {
        let engine = ComputerEngine()
        let result = await engine.handle(ComputerRequest(command: "setup-permissions", arguments: ["section": "wrong"]))
        let error = try XCTUnwrap(response(result)["error"] as? [String: String])
        XCTAssertEqual(error["code"], "invalid_argument")
    }

    private func response(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
