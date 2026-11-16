import AppKit
import XCTest
@testable import DamsonTerminal

final class PaneIndicatorStyleTests: XCTestCase {
    private let dark = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1)
    private let light = NSColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: 1)
    private let accent = NSColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 1)

    private func resolve(_ s: PaneIndicatorSettings, active: Bool, multi: Bool = true,
                         key: Bool = true, bg: NSColor? = nil) -> PaneIndicatorAppearance {
        PaneIndicatorStyle.resolve(s, isActive: active, multiPane: multi, windowIsKey: key,
                                   background: bg ?? dark, systemAccent: accent)
    }

    private func suite() -> UserDefaults {
        let name = "damson.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    private func assertSameColor(_ a: NSColor?, _ b: NSColor?, file: StaticString = #filePath, line: UInt = #line) {
        guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else {
            return XCTAssertEqual(a == nil, b == nil, file: file, line: line)
        }
        XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(a.greenComponent, b.greenComponent, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(a.blueComponent, b.blueComponent, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(a.alphaComponent, b.alphaComponent, accuracy: 0.002, file: file, line: line)
    }

    // MARK: Defaults reproduce the look before these settings existed

    func testEmptyDefaultsMatchPreviousLook() {
        let s = PaneIndicatorSettings(defaults: suite())
        XCTAssertEqual(s, PaneIndicatorSettings())
        let a = resolve(s, active: true)
        XCTAssertEqual(a.borderWidth, 1)
        XCTAssertEqual(a.borderOpacity, 1)
        assertSameColor(a.borderColor, PaneIndicatorStyle.mutedAccent(accent))
        XCTAssertFalse(a.dimEnabled)
        assertSameColor(PaneIndicatorStyle.dividerColor(s), .separatorColor)
    }

    func testDimDefaultIsFortyPercentBlackOnDarkTheme() {
        var s = PaneIndicatorSettings()
        s.mode = .dimInactive
        let inactive = resolve(s, active: false)
        XCTAssertTrue(inactive.dimEnabled)
        XCTAssertEqual(inactive.dimOpacity, 0.4)
        assertSameColor(inactive.dimColor, .black)
        XCTAssertNil(inactive.borderColor)
        XCTAssertEqual(resolve(s, active: true).dimOpacity, 0)
    }

    // MARK: 1. Dim strength

    func testDimStrengthIsApplied() {
        let d = suite()
        d.set(PaneIndicatorMode.dimInactive.rawValue, forKey: PaneIndicatorSettings.Keys.mode)
        d.set(0.65, forKey: PaneIndicatorSettings.Keys.dimStrength)
        XCTAssertEqual(resolve(PaneIndicatorSettings(defaults: d), active: false).dimOpacity, 0.65, accuracy: 1e-6)
    }

    func testOutOfRangeValuesFallBackToDefaults() {
        let d = suite()
        d.set(0.0, forKey: PaneIndicatorSettings.Keys.dimStrength)   // would make dim invisible
        d.set(40.0, forKey: PaneIndicatorSettings.Keys.borderWidth)  // would cover the text
        d.set(-1.0, forKey: PaneIndicatorSettings.Keys.dividerWidth)
        d.set("not-a-mode", forKey: PaneIndicatorSettings.Keys.mode)
        d.set("zzz", forKey: PaneIndicatorSettings.Keys.accentColor)
        XCTAssertEqual(PaneIndicatorSettings(defaults: d), PaneIndicatorSettings())
    }

    // MARK: 2. Accent color and width

    func testCustomAccentColorAndWidth() {
        let d = suite()
        d.set("#FF8800", forKey: PaneIndicatorSettings.Keys.accentColor)
        d.set(3.0, forKey: PaneIndicatorSettings.Keys.borderWidth)
        let a = resolve(PaneIndicatorSettings(defaults: d), active: true)
        assertSameColor(a.borderColor, NSColor(srgbRed: 1, green: 0x88 / 255.0, blue: 0, alpha: 1))
        XCTAssertEqual(a.borderWidth, 3)
    }

    func testEmptyAccentStringMeansSystemAccent() {
        let d = suite()
        d.set("", forKey: PaneIndicatorSettings.Keys.accentColor)
        assertSameColor(resolve(PaneIndicatorSettings(defaults: d), active: true).borderColor,
                        PaneIndicatorStyle.mutedAccent(accent))
    }

    func testWidthAppliesToSubtleBorderToo() {
        var s = PaneIndicatorSettings()
        s.mode = .subtleBorder
        s.borderWidth = 2
        XCTAssertEqual(resolve(s, active: true).borderWidth, 2)
    }

    /// The inactive pane keeps the border's color and width at opacity 0, so it can
    /// fade out when focus leaves instead of vanishing.
    func testInactivePaneKeepsBorderAtZeroOpacity() {
        let a = resolve(PaneIndicatorSettings(), active: false)
        XCTAssertNotNil(a.borderColor)
        XCTAssertEqual(a.borderWidth, 1)
        XCTAssertEqual(a.borderOpacity, 0)
    }

    func testLonePaneGetsNoBorder() {
        XCTAssertEqual(resolve(PaneIndicatorSettings(), active: true, multi: false).borderOpacity, 0)
    }

    // MARK: 3. Dim + border

    func testDimAndBorderDoesBoth() {
        var s = PaneIndicatorSettings()
        s.mode = .dimAndBorder
        let active = resolve(s, active: true), inactive = resolve(s, active: false)
        XCTAssertEqual(active.borderOpacity, 1)
        XCTAssertEqual(active.dimOpacity, 0)
        XCTAssertEqual(inactive.borderOpacity, 0)
        XCTAssertEqual(inactive.dimOpacity, 0.4)
    }

    // MARK: 4. Dim tint

    func testAutoTintUsesBackgroundOnLightTheme() {
        var s = PaneIndicatorSettings()
        s.mode = .dimInactive
        assertSameColor(resolve(s, active: false, bg: light).dimColor, light)
        assertSameColor(resolve(s, active: false, bg: dark).dimColor, .black)
    }

    func testExplicitTints() {
        var s = PaneIndicatorSettings()
        s.mode = .dimInactive
        s.dimTint = .black
        assertSameColor(resolve(s, active: false, bg: light).dimColor, .black)
        s.dimTint = .background
        assertSameColor(resolve(s, active: false, bg: dark).dimColor, dark)
    }

    // MARK: 5. Dim inactive windows

    func testInactiveWindowDimsEveryPaneIncludingALoneOne() {
        var s = PaneIndicatorSettings()
        s.dimInactiveWindows = true
        s.dimStrength = 0.3
        for (active, multi) in [(true, true), (false, true), (true, false)] {
            let a = resolve(s, active: active, multi: multi, key: false)
            XCTAssertTrue(a.dimEnabled)
            XCTAssertEqual(a.dimOpacity, 0.3, accuracy: 1e-6, "active=\(active) multi=\(multi)")
        }
        XCTAssertEqual(resolve(s, active: true, key: true).dimOpacity, 0)
    }

    func testInactiveWindowDoesNotDimWhenOff() {
        XCTAssertEqual(resolve(PaneIndicatorSettings(), active: true, key: false).dimOpacity, 0)
    }

    // MARK: 6. Divider

    func testCustomDivider() {
        let d = suite()
        d.set("#336699", forKey: PaneIndicatorSettings.Keys.dividerColor)
        d.set(2.0, forKey: PaneIndicatorSettings.Keys.dividerWidth)
        let s = PaneIndicatorSettings(defaults: d)
        XCTAssertEqual(s.dividerWidth, 2)
        assertSameColor(PaneIndicatorStyle.dividerColor(s),
                        NSColor(srgbRed: 0x33 / 255.0, green: 0x66 / 255.0, blue: 0x99 / 255.0, alpha: 1))
    }
}
