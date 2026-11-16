import Foundation
import XCTest
@testable import DamsonSettings

final class SettingsCatalogTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "damson.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    private func item(_ key: String) -> SettingItem { SettingsCatalog.item(key)! }

    // MARK: Structure

    func testKeysAreUnique() {
        let keys = SettingsCatalog.all.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testEveryPageHasASection() {
        for page in SettingsPage.allCases {
            XCTAssertFalse(SettingsCatalog.sections(of: page).isEmpty, page.rawValue)
        }
    }

    func testSectionsKeepDisplayOrder() {
        XCTAssertEqual(SettingsCatalog.sections(of: .panes), ["Active Pane", "Inactive Windows", "Dividers"])
    }

    // MARK: Search

    func testSearchMatchesTitleSectionAndKeywords() {
        XCTAssertTrue(SettingsCatalog.search("divider").map(\.key).contains("damson.paneDividerWidth"))
        XCTAssertTrue(SettingsCatalog.search("padding").map(\.key).contains("damson.paddingH"))  // section
        XCTAssertTrue(SettingsCatalog.search("단축키").map(\.key).contains("damson.keybindings"))  // keyword
    }

    func testSearchRequiresEveryWordAndIgnoresCase() {
        let keys = SettingsCatalog.search("DIM width").map(\.key)
        XCTAssertFalse(keys.contains("damson.paneDimStrength"))
        XCTAssertEqual(SettingsCatalog.search("cursor blink").first?.key, "damson.cursorBlink")
    }

    func testTitleHitsRankFirst() {
        // "dim" is in three Panes titles and only a keyword of other items.
        let first = SettingsCatalog.search("dim").prefix(3).map(\.key)
        XCTAssertEqual(Set(first), ["damson.paneDimStrength", "damson.paneDimTint", "damson.dimInactiveWindows"])
    }

    func testBlankQueryFindsNothing() {
        XCTAssertTrue(SettingsCatalog.search("   ").isEmpty)
    }

    // MARK: Modified

    func testUnsetIsNotModified() {
        XCTAssertFalse(SettingsCatalog.isModified(item("damson.fontSize"), in: suite()))
    }

    func testSetToDefaultIsNotModified() {
        let d = suite()
        d.set(13.0, forKey: "damson.fontSize")
        d.set(true, forKey: "damson.evenSplits")
        d.set(5, forKey: "damson.orchestration.stallMinutes")
        XCTAssertFalse(SettingsCatalog.isModified(item("damson.fontSize"), in: d))
        XCTAssertFalse(SettingsCatalog.isModified(item("damson.evenSplits"), in: d))
        XCTAssertFalse(SettingsCatalog.isModified(item("damson.orchestration.stallMinutes"), in: d))
    }

    func testChangedValueIsModified() {
        let d = suite()
        d.set(0.55, forKey: "damson.paneDimStrength")
        d.set("Solarized Dark", forKey: "damson.theme")
        XCTAssertTrue(SettingsCatalog.isModified(item("damson.paneDimStrength"), in: d))
        XCTAssertTrue(SettingsCatalog.isModified(item("damson.theme"), in: d))
        XCTAssertEqual(SettingsCatalog.modifiedItems(page: .panes, in: d).map(\.key), ["damson.paneDimStrength"])
    }

    func testDynamicAndDataCountAsModifiedOnceStored() {
        let d = suite()
        d.set("Menlo", forKey: "damson.fontFamily")
        d.set(Data([1, 2]), forKey: "damson.keybindings")
        XCTAssertTrue(SettingsCatalog.isModified(item("damson.fontFamily"), in: d))
        XCTAssertTrue(SettingsCatalog.isModified(item("damson.keybindings"), in: d))
    }

    // MARK: Reset

    func testResetSectionClearsOnlyThatSection() {
        let d = suite()
        d.set(12.0, forKey: "damson.paddingH")
        d.set(0.5, forKey: "damson.backgroundOpacity")
        SettingsCatalog.reset(page: .window, section: "Padding", in: d)
        XCTAssertNil(d.object(forKey: "damson.paddingH"))
        XCTAssertEqual(d.double(forKey: "damson.backgroundOpacity"), 0.5)
    }

    func testResetPageClearsEverySection() {
        let d = suite()
        d.set("dimInactive", forKey: "damson.activePaneIndicator")
        d.set(3.0, forKey: "damson.paneDividerWidth")
        SettingsCatalog.reset(page: .panes, in: d)
        XCTAssertTrue(SettingsCatalog.modifiedItems(page: .panes, in: d).isEmpty)
    }

    // MARK: Export / import

    func testRoundTripReproducesSettings() throws {
        let src = suite()
        src.set(16.0, forKey: "damson.fontSize")
        src.set("Menlo", forKey: "damson.fontFamily")
        src.set(false, forKey: "damson.copyOnSelect")
        src.set(20, forKey: "damson.orchestration.stallMinutes")
        src.set(Data([9, 9]), forKey: "damson.customTheme")
        let file = try SettingsCatalog.exportData(from: src)

        let dst = suite()
        dst.set(0.3, forKey: "damson.backgroundOpacity")   // differs on the target Mac
        let result = try SettingsCatalog.importData(file, into: dst)
        XCTAssertTrue(result.skipped.isEmpty)
        XCTAssertEqual(dst.double(forKey: "damson.fontSize"), 16)
        XCTAssertEqual(dst.string(forKey: "damson.fontFamily"), "Menlo")
        XCTAssertEqual(dst.object(forKey: "damson.copyOnSelect") as? Bool, false)
        XCTAssertEqual(dst.integer(forKey: "damson.orchestration.stallMinutes"), 20)
        XCTAssertEqual(dst.data(forKey: "damson.customTheme"), Data([9, 9]))
        // The source had the default opacity, so the export carries it and the target
        // goes back to "unset" rather than keeping its own 0.3.
        XCTAssertNil(dst.object(forKey: "damson.backgroundOpacity"))
        for i in SettingsCatalog.all {
            XCTAssertEqual(SettingsCatalog.isModified(i, in: dst), SettingsCatalog.isModified(i, in: src), i.key)
        }
    }

    func testImportSkipsUnknownKeysAndWrongTypes() throws {
        let root: [String: Any] = ["format": "damson-settings", "version": 1, "settings": [
            "damson.fontSize": "huge",            // wrong type
            "damson.evenSplits": 1,               // a number, not a boolean
            "damson.restorableState": Data(),     // not a setting: never imported
            "damson.cursorBlink": true,
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
        let d = suite()
        let r = try SettingsCatalog.importData(data, into: d)
        XCTAssertEqual(r.applied, ["damson.cursorBlink"])
        XCTAssertEqual(Set(r.skipped), ["damson.fontSize", "damson.evenSplits", "damson.restorableState"])
        XCTAssertNil(d.object(forKey: "damson.restorableState"))
        XCTAssertNil(d.object(forKey: "damson.fontSize"))
    }

    func testImportRejectsOtherFiles() throws {
        let other = try PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .xml, options: 0)
        XCTAssertThrowsError(try SettingsCatalog.importData(other, into: suite())) {
            XCTAssertEqual($0 as? SettingsCatalog.ImportError, .notASettingsFile)
        }
        XCTAssertThrowsError(try SettingsCatalog.importData(Data("not a plist".utf8), into: suite()))
        let newer = try PropertyListSerialization.data(fromPropertyList:
            ["format": "damson-settings", "version": 99, "settings": [:]], format: .xml, options: 0)
        XCTAssertThrowsError(try SettingsCatalog.importData(newer, into: suite())) {
            XCTAssertEqual($0 as? SettingsCatalog.ImportError, .newerVersion(99))
        }
    }
}

/// Keeps the catalogue honest against the Settings window: every `@AppStorage` key in
/// SettingsView.swift must be catalogued, and a literal default there must equal the
/// catalogue's. Without this the two drift silently — "modified" dots would light up on
/// untouched settings, and reset/export would use the wrong default.
final class SettingsCatalogSourceTests: XCTestCase {
    private struct Storage { let key: String; let defaultExpr: String }

    private func appStorageDeclarations() throws -> [Storage] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/damson/SettingsView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        let re = try NSRegularExpression(
            pattern: #"@AppStorage\(([^)]+)\)\s*(?:private\s+)?var\s+\w+\s*:\s*\w+\s*=\s*([^\n]+)"#)
        let ns = src as NSString
        return re.matches(in: src, range: NSRange(location: 0, length: ns.length)).map { m in
            var key = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("\"") {
                key = String(key.dropFirst().dropLast())
            } else if key.hasPrefix("OrchestrationSettings.Keys.") {
                key = "damson.orchestration." + key.dropFirst("OrchestrationSettings.Keys.".count)
            }
            return Storage(key: key, defaultExpr: ns.substring(with: m.range(at: 2))
                            .trimmingCharacters(in: .whitespaces))
        }
    }

    func testFoundTheDeclarations() throws {
        XCTAssertGreaterThan(try appStorageDeclarations().count, 40, "regex no longer matches SettingsView")
    }

    func testEveryAppStorageKeyIsCatalogued() throws {
        for s in try appStorageDeclarations() {
            XCTAssertNotNil(SettingsCatalog.item(s.key), "\(s.key) is in SettingsView but not in SettingsCatalog")
        }
    }

    func testEveryCatalogueKeyIsInTheWindow() throws {
        let declared = Set(try appStorageDeclarations().map(\.key))
        // Blobs are written by their own editors (custom theme, Keys page), not @AppStorage.
        for i in SettingsCatalog.all where i.defaultValue != .data {
            XCTAssertTrue(declared.contains(i.key), "\(i.key) is catalogued but has no control")
        }
    }

    func testLiteralDefaultsMatch() throws {
        for s in try appStorageDeclarations() {
            guard let item = SettingsCatalog.item(s.key) else { continue }
            let e = s.defaultExpr
            switch item.defaultValue {
            case .bool(let b):
                XCTAssertEqual(e, b ? "true" : "false", s.key)
            case .int(let i):
                XCTAssertEqual(Int(e.replacingOccurrences(of: "_", with: "")), i, s.key)
            case .double(let x):
                XCTAssertEqual(Double(e), x, s.key)
            case .string(let str):
                if e.hasPrefix("\"") {
                    XCTAssertEqual(String(e.dropFirst().dropLast()), str, s.key)
                } else if let raw = e.split(separator: ".").dropLast().last, e.hasSuffix(".rawValue") {
                    // `TabBarStyle.compact.rawValue` — a case name equal to its raw value.
                    XCTAssertEqual(String(raw), str, s.key)
                } else if e.hasSuffix(".name") {
                    continue   // DamsonTheme.defaultDark.name: not visible from here; catalogued as "Default Dark"
                } else {
                    XCTFail("\(s.key): can't read default `\(e)`")
                }
            case .dynamicString, .data:
                continue
            }
        }
    }
}
