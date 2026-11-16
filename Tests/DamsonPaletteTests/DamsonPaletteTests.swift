import XCTest
@testable import DamsonPalette

final class PaletteSearchTests: XCTestCase {
    private typealias C = PaletteSearch.Candidate

    func testEmptyQueryKeepsOrderWithDisabledLast() {
        let items = [C(title: "A", detail: "", isEnabled: false), C(title: "B", detail: ""), C(title: "C", detail: "")]
        XCTAssertEqual(PaletteSearch.rank(items, query: "  "), [1, 2, 0])
    }

    func testEveryWordMustMatchTitleOrDetail() {
        let items = [C(title: "Split Right", detail: "Shell › Split"), C(title: "Pane: zsh", detail: "/tmp")]
        XCTAssertEqual(PaletteSearch.rank(items, query: "split shell"), [0])
        XCTAssertEqual(PaletteSearch.rank(items, query: "split nowhere"), [])
    }

    func testTitleHitsRankAboveDetailHits() {
        let items = [
            C(title: "Pane: build", detail: "/Users/me/dev/split"),
            C(title: "Split Right", detail: "Shell"),
        ]
        XCTAssertEqual(PaletteSearch.rank(items, query: "split"), [1, 0])
    }

    func testWordStartBeatsMidWordMatch() {
        let items = [C(title: "Unsplit All", detail: ""), C(title: "Split Down", detail: "")]
        XCTAssertEqual(PaletteSearch.rank(items, query: "split"), [1, 0])
    }

    func testEnabledBeforeDisabledAtEqualRelevance() {
        let items = [C(title: "Close Pane", detail: "", isEnabled: false), C(title: "Close Tab", detail: "")]
        XCTAssertEqual(PaletteSearch.rank(items, query: "close"), [1, 0])
    }

    func testDisabledExactTitleStillBeatsEnabledDetailHit() {
        let items = [C(title: "Pane: x", detail: "~/close"), C(title: "Close Pane", detail: "", isEnabled: false)]
        XCTAssertEqual(PaletteSearch.rank(items, query: "close"), [1, 0])
    }

    func testCaseAndDiacriticInsensitive() {
        let items = [C(title: "Pane: Café", detail: "/Users/Me/Résumé")]
        XCTAssertEqual(PaletteSearch.rank(items, query: "CAFE resume"), [0])
    }
}

final class ShortcutFormatTests: XCTestCase {
    private let cmd = ShortcutFormat.command, opt = ShortcutFormat.option
    private let shift = ShortcutFormat.shift, ctrl = ShortcutFormat.control

    func testEmpty() { XCTAssertEqual(ShortcutFormat.display(keyEquivalent: "", modifiers: cmd), "") }

    func testLetterIsUppercasedInModifierOrder() {
        XCTAssertEqual(ShortcutFormat.display(keyEquivalent: "p", modifiers: cmd | shift | ctrl | opt), "⌃⌥⇧⌘P")
    }

    func testUppercaseKeyEquivalentImpliesShift() {
        XCTAssertEqual(ShortcutFormat.display(keyEquivalent: "D", modifiers: cmd), "⇧⌘D")
    }

    func testArrowsRenderAsGlyphsNotPrivateUseChars() {
        XCTAssertEqual(ShortcutFormat.display(keyEquivalent: "\u{F702}", modifiers: cmd | opt), "⌥⌘←")
        XCTAssertEqual(ShortcutFormat.display(keyEquivalent: "\u{F700}", modifiers: cmd), "⌘↑")
        XCTAssertEqual(ShortcutFormat.display(keyEquivalent: "\u{F703}", modifiers: cmd | shift), "⇧⌘→")
    }

    func testFunctionAndControlKeys() {
        XCTAssertEqual(ShortcutFormat.display(keyEquivalent: "\u{F704}", modifiers: cmd), "⌘F1")
        XCTAssertEqual(ShortcutFormat.display(keyEquivalent: "\u{F70F}", modifiers: 0), "F12")
        XCTAssertEqual(ShortcutFormat.display(keyEquivalent: "\t", modifiers: ctrl), "⌃⇥")
        XCTAssertEqual(ShortcutFormat.display(keyEquivalent: "\r", modifiers: cmd), "⌘↩")
        XCTAssertEqual(ShortcutFormat.display(keyEquivalent: "\u{1b}", modifiers: cmd), "⌘⎋")
        XCTAssertEqual(ShortcutFormat.display(keyEquivalent: "\u{08}", modifiers: cmd), "⌘⌫")
        XCTAssertEqual(ShortcutFormat.display(keyEquivalent: " ", modifiers: ctrl), "⌃Space")
    }

    func testPunctuationAndDigits() {
        XCTAssertEqual(ShortcutFormat.display(keyEquivalent: "]", modifiers: cmd | shift), "⇧⌘]")
        XCTAssertEqual(ShortcutFormat.display(keyEquivalent: "1", modifiers: cmd), "⌘1")
    }
}
