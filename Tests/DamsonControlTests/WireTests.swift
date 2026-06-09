import Foundation
import XCTest
@testable import DamsonControl

/// Regression guard for wire-format compatibility. The bytes must match the Rust
/// damson-cli `docs/CLI.md` spec exactly, or cross-impl compatibility breaks.
final class WireTests: XCTestCase {
    // MARK: - encodeCommand (CLI → server)

    func testEncodeNewTab() {
        XCTAssertEqual(encodeCommand(.newTab), #"{"cmd":"new-tab"}"#)
    }

    func testEncodeCloseTab() {
        XCTAssertEqual(encodeCommand(.closeTab), #"{"cmd":"close-tab"}"#)
    }

    func testEncodeListTabs() {
        XCTAssertEqual(encodeCommand(.listTabs), #"{"cmd":"list-tabs"}"#)
    }

    func testEncodeSplitHorizontal() {
        XCTAssertEqual(
            encodeCommand(.split(.horizontal)),
            #"{"cmd":"split","args":{"dir":"horizontal"}}"#
        )
    }

    func testEncodeSplitVertical() {
        XCTAssertEqual(
            encodeCommand(.split(.vertical)),
            #"{"cmd":"split","args":{"dir":"vertical"}}"#
        )
    }

    func testEncodeSwitchTab() {
        XCTAssertEqual(
            encodeCommand(.switchTab(index: 7)),
            #"{"cmd":"switch-tab","args":{"index":7}}"#
        )
    }

    // MARK: - ControlCommand decoding (server side)

    func testDecodeNewTab() throws {
        let data = Data(#"{"cmd":"new-tab"}"#.utf8)
        let cmd = try JSONDecoder().decode(ControlCommand.self, from: data)
        XCTAssertEqual(cmd.kind, .newTab)
    }

    func testDecodeCloseTab() throws {
        let data = Data(#"{"cmd":"close-tab"}"#.utf8)
        let cmd = try JSONDecoder().decode(ControlCommand.self, from: data)
        XCTAssertEqual(cmd.kind, .closeTab)
    }

    func testDecodeSplitHorizontal() throws {
        let data = Data(#"{"cmd":"split","args":{"dir":"horizontal"}}"#.utf8)
        let cmd = try JSONDecoder().decode(ControlCommand.self, from: data)
        XCTAssertEqual(cmd.kind, .split(.horizontal))
    }

    func testDecodeSwitchTab() throws {
        let data = Data(#"{"cmd":"switch-tab","args":{"index":3}}"#.utf8)
        let cmd = try JSONDecoder().decode(ControlCommand.self, from: data)
        XCTAssertEqual(cmd.kind, .switchTab(index: 3))
    }

    func testDecodeUnknownCommandRejected() {
        let data = Data(#"{"cmd":"obliterate-universe"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ControlCommand.self, from: data))
    }

    // MARK: - ControlResponse

    func testResponseOkOmitsOptionalFields() throws {
        let r = ControlResponse.ok()
        let data = try JSONEncoder().encode(r)
        let s = String(data: data, encoding: .utf8)!
        XCTAssertEqual(s, #"{"ok":true}"#)
    }

    func testResponseErrIncludesMessage() throws {
        let r = ControlResponse.err("nope")
        let data = try JSONEncoder().encode(r)
        let s = String(data: data, encoding: .utf8)!
        // JSONEncoder does not guarantee key order matches declaration order,
        // so verify via round-trip.
        let back = try JSONDecoder().decode(ControlResponse.self, from: data)
        XCTAssertEqual(back, r)
        XCTAssertTrue(s.contains(#""ok":false"#))
        XCTAssertTrue(s.contains(#""err":"nope""#))
        XCTAssertFalse(s.contains(#""tabs""#))
    }

    func testResponseTabsRoundtrip() throws {
        let r = ControlResponse.tabs([
            TabInfo(index: 0, pane_count: 1),
            TabInfo(index: 1, pane_count: 1),
        ])
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(ControlResponse.self, from: data)
        XCTAssertEqual(back, r)
    }

    // MARK: - runtimeDir / pick

    func testRuntimeDirHonorsXDG() {
        let orig = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"]
        setenv("XDG_RUNTIME_DIR", "/tmp/damson-xdg-test", 1)
        XCTAssertEqual(damsonRuntimeDir(), "/tmp/damson-xdg-test/damson")
        if let v = orig {
            setenv("XDG_RUNTIME_DIR", v, 1)
        } else {
            unsetenv("XDG_RUNTIME_DIR")
        }
    }

    func testPickWithExplicitMissingPidErrors() {
        // No instance with PID 0 ever exists in the runtime environment.
        switch pickDamsonSocket(pid: 0) {
        case .success:
            XCTFail("expected failure for missing pid")
        case .failure(let e):
            XCTAssertTrue(e.message.contains("pid 0"))
        }
    }
}
