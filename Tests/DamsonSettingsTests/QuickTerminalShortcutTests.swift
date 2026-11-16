import XCTest
@testable import DamsonSettings

/// The quick terminal's global shortcut (#49): only chords nobody types can be registered,
/// the Carbon modifiers are right, and storage falls back to the default.
final class QuickTerminalShortcutTests: XCTestCase {
    private typealias S = QuickTerminalShortcut

    private func suite() -> UserDefaults {
        let name = "QuickTerminalShortcutTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testDefaultIsControlCommandGrave() {
        XCTAssertEqual(S.default.keyCode, 50)
        XCTAssertEqual(S.default.carbonModifiers, (1 << 8) | (1 << 12))   // cmdKey | controlKey
        XCTAssertNil(S.default.problem)
    }

    func testChordsPeopleTypeAreRejected() {
        XCTAssertNotNil(S(keyCode: 0, modifiers: 0, display: "A").problem)
        XCTAssertNotNil(S(keyCode: 0, modifiers: S.shift, display: "⇧A").problem)
        XCTAssertNotNil(S(keyCode: 0, modifiers: S.option, display: "⌥A").problem)
        XCTAssertNotNil(S(keyCode: 0, modifiers: S.option | S.shift, display: "⌥⇧A").problem)
        XCTAssertNil(S(keyCode: 0, modifiers: S.command | S.option, display: "⌥⌘A").problem)
        XCTAssertNil(S(keyCode: 49, modifiers: S.control, display: "⌃Space").problem)
    }

    func testCarbonModifiers() {
        let all = S(keyCode: 1, modifiers: S.command | S.shift | S.option | S.control, display: "")
        XCTAssertEqual(all.carbonModifiers, (1 << 8) | (1 << 9) | (1 << 11) | (1 << 12))
        // Bits outside ⌘⇧⌥⌃ (caps lock, fn) are dropped.
        XCTAssertEqual(S(keyCode: 1, modifiers: S.command | (1 << 16) | (1 << 23), display: "").modifiers, S.command)
    }

    func testStorageRoundTripAndFallbacks() {
        let d = suite()
        XCTAssertEqual(S.load(from: d), .default)
        let custom = S(keyCode: 49, modifiers: S.control | S.option, display: "⌃⌥Space")
        custom.save(to: d)
        XCTAssertEqual(S.load(from: d), custom)
        S.default.save(to: d)
        XCTAssertNil(d.object(forKey: S.storageKey), "the default is stored as unset")
        d.set(Data("junk".utf8), forKey: S.storageKey)
        XCTAssertEqual(S.load(from: d), .default)
        d.set(try? JSONEncoder().encode(S(keyCode: 0, modifiers: S.shift, display: "⇧A")), forKey: S.storageKey)
        XCTAssertEqual(S.load(from: d), .default, "an edited, typeable chord is never registered")
    }

    func testBothKeysAreCatalogued() {
        XCTAssertEqual(SettingsCatalog.item(S.enabledKey)?.defaultValue, .bool(false))
        XCTAssertEqual(SettingsCatalog.item(S.storageKey)?.defaultValue, .data)
    }
}
