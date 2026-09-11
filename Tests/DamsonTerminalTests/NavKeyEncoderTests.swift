import XCTest
@testable import DamsonTerminal

/// Modified cursor/navigation keys — the bytes a TUI reads to tell ⌥↑ from ↑.
final class NavKeyEncoderTests: XCTestCase {
    private func text(_ bytes: [UInt8]?) -> String? {
        bytes.map { String(decoding: $0, as: UTF8.self).replacingOccurrences(of: "\u{1B}", with: "ESC ") }
    }

    func testArrowsCarryTheModifier() {
        // Codex's "⌥ + ↑ to answer" — the case that sent nothing at all.
        XCTAssertEqual(text(NavKey.up.sequence(shift: false, option: true, control: false)),
                       "ESC [1;3A")
        XCTAssertEqual(text(NavKey.down.sequence(shift: false, option: true, control: false)),
                       "ESC [1;3B")
        XCTAssertEqual(text(NavKey.right.sequence(shift: false, option: true, control: false)),
                       "ESC [1;3C")
        XCTAssertEqual(text(NavKey.left.sequence(shift: false, option: true, control: false)),
                       "ESC [1;3D")
    }

    func testModifierCodesFollowXterm() {
        XCTAssertEqual(text(NavKey.up.sequence(shift: true, option: false, control: false)),
                       "ESC [1;2A")
        XCTAssertEqual(text(NavKey.up.sequence(shift: false, option: false, control: true)),
                       "ESC [1;5A")
        XCTAssertEqual(text(NavKey.up.sequence(shift: true, option: true, control: false)),
                       "ESC [1;4A")
        XCTAssertEqual(text(NavKey.up.sequence(shift: true, option: false, control: true)),
                       "ESC [1;6A")
        XCTAssertEqual(text(NavKey.up.sequence(shift: false, option: true, control: true)),
                       "ESC [1;7A")
        // Every modifier at once is code 8 — still one digit, which is what keeps the
        // sequence a fixed six bytes.
        XCTAssertEqual(text(NavKey.up.sequence(shift: true, option: true, control: true)),
                       "ESC [1;8A")
    }

    func testHomeEndAndPaging() {
        XCTAssertEqual(text(NavKey.home.sequence(shift: false, option: true, control: false)),
                       "ESC [1;3H")
        XCTAssertEqual(text(NavKey.end.sequence(shift: true, option: false, control: false)),
                       "ESC [1;2F")
        XCTAssertEqual(text(NavKey.pageUp.sequence(shift: false, option: true, control: false)),
                       "ESC [5;3~")
        XCTAssertEqual(text(NavKey.pageDown.sequence(shift: false, option: true, control: false)),
                       "ESC [6;3~")
    }

    func testBareKeyIsLeftToTheExistingPath() {
        // nil, not a sequence: the unmodified arrow keeps going through doCommand, which is
        // the path that would gain application-cursor-keys mode.
        XCTAssertNil(NavKey.up.sequence(shift: false, option: false, control: false))
        XCTAssertNil(NavKey.pageDown.sequence(shift: false, option: false, control: false))
    }

    func testKeyCodes() {
        XCTAssertEqual(NavKey(keyCode: 126), .up)
        XCTAssertEqual(NavKey(keyCode: 125), .down)
        XCTAssertEqual(NavKey(keyCode: 124), .right)
        XCTAssertEqual(NavKey(keyCode: 123), .left)
        XCTAssertEqual(NavKey(keyCode: 115), .home)
        XCTAssertEqual(NavKey(keyCode: 119), .end)
        XCTAssertEqual(NavKey(keyCode: 116), .pageUp)
        XCTAssertEqual(NavKey(keyCode: 121), .pageDown)
        XCTAssertNil(NavKey(keyCode: 0))    // 'a' — a typed character, not a motion
        XCTAssertNil(NavKey(keyCode: 36))   // Return
    }
}
