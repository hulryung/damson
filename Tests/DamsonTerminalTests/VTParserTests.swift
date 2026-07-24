import XCTest
@testable import DamsonTerminal

private final class RecordingDelegate: VTParserDelegate {
    enum Event: Equatable {
        case text(String)
        case execute(UInt8)
        case csi(params: [Int], finalByte: UInt8, privateMarker: UInt8?)
        case osc([String])
    }
    var events: [Event] = []

    func vtParser(_ parser: VTParser, didEmitText text: String) {
        events.append(.text(text))
    }
    func vtParser(_ parser: VTParser, didExecute byte: UInt8) {
        events.append(.execute(byte))
    }
    func vtParser(
        _ parser: VTParser,
        didEmitCSI params: [Int],
        intermediates: [UInt8],
        finalByte: UInt8,
        privateMarker: UInt8?
    ) {
        events.append(.csi(params: params, finalByte: finalByte, privateMarker: privateMarker))
    }
    func vtParser(_ parser: VTParser, didEmitOSC params: [String]) {
        events.append(.osc(params))
    }
}

final class VTParserTests: XCTestCase {
    private func parse(_ s: String) -> [RecordingDelegate.Event] {
        let p = VTParser()
        let d = RecordingDelegate()
        p.delegate = d
        p.feed(Data(s.utf8))
        return d.events
    }

    func testPlainText() {
        XCTAssertEqual(parse("hello"), [.text("hello")])
    }

    func testControlBytes() {
        let events = parse("a\u{08}b")
        XCTAssertEqual(events, [.text("a"), .execute(0x08), .text("b")])
    }

    func testCSISGRSingleParam() {
        let events = parse("\u{1B}[31mX")
        XCTAssertEqual(events, [
            .csi(params: [31], finalByte: 0x6D, privateMarker: nil),
            .text("X"),
        ])
    }

    func testCSIMultipleParams() {
        let events = parse("\u{1B}[1;31mX")
        XCTAssertEqual(events, [
            .csi(params: [1, 31], finalByte: 0x6D, privateMarker: nil),
            .text("X"),
        ])
    }

    func testCSIEmptyParam() {
        // CSI m → SGR reset
        let events = parse("\u{1B}[m")
        XCTAssertEqual(events, [
            .csi(params: [-1], finalByte: 0x6D, privateMarker: nil),
        ])
    }

    func testCSIPrivateMarker() {
        // CSI ?25l → hide cursor
        let events = parse("\u{1B}[?25l")
        XCTAssertEqual(events, [
            .csi(params: [25], finalByte: 0x6C, privateMarker: 0x3F),
        ])
    }

    func testOSCWithBELTerminator() {
        let events = parse("\u{1B}]0;hello\u{07}")
        XCTAssertEqual(events, [.osc(["0", "hello"])])
    }

    func testOSCWithSTTerminator() {
        let events = parse("\u{1B}]2;world\u{1B}\\")
        XCTAssertEqual(events, [.osc(["2", "world"])])
    }

    func testOSC7CwdSplit() {
        // OSC 7 ; file://host/path — keep it as a single token even if the host has ordinary characters.
        let events = parse("\u{1B}]7;file://mac/Users/dk/dev\u{07}")
        XCTAssertEqual(events, [.osc(["7", "file://mac/Users/dk/dev"])])
    }

    func testParseFileURLPath() {
        XCTAssertEqual(
            DamsonSession.parseFileURLPath("file://mac/Users/dk/dev"),
            "/Users/dk/dev")
        // host omitted (file:///path)
        XCTAssertEqual(
            DamsonSession.parseFileURLPath("file:///tmp/x"),
            "/tmp/x")
        // percent-encoded space
        XCTAssertEqual(
            DamsonSession.parseFileURLPath("file://h/Users/dk/My%20Code"),
            "/Users/dk/My Code")
        // not file:// → nil
        XCTAssertNil(DamsonSession.parseFileURLPath("http://x/y"))
    }

    func testPartialUTF8AcrossFeeds() {
        // "안" is 0xEC 0x95 0x88 — split in the middle
        let p = VTParser()
        let d = RecordingDelegate()
        p.delegate = d
        p.feed(Data([0xEC, 0x95]))
        XCTAssertTrue(d.events.isEmpty, "partial UTF-8 must not emit yet")
        p.feed(Data([0x88]))
        XCTAssertEqual(d.events, [.text("안")])
    }

    func testCSIInterleavedWithText() {
        let events = parse("a\u{1B}[31mb\u{1B}[0mc")
        XCTAssertEqual(events, [
            .text("a"),
            .csi(params: [31], finalByte: 0x6D, privateMarker: nil),
            .text("b"),
            .csi(params: [0], finalByte: 0x6D, privateMarker: nil),
            .text("c"),
        ])
    }

    func testCSIWithGTIntermediateCapturesPrivateMarker() {
        // \x1b[>4;2m sent by Claude Code at startup (xterm modifyOtherKeys /
        // Kitty keyboard protocol). privateMarker '>' (0x3E) must be captured
        // exactly so that DamsonSession does not misinterpret it as SGR.
        // Mirror: anthropics/claude-code#23698, halite Rust 40bd82f.
        let events = parse("\u{1B}[>4;2m")
        XCTAssertEqual(events, [
            .csi(params: [4, 2], finalByte: 0x6D, privateMarker: 0x3E),
        ])
    }
}

// MARK: - Colon-delimited SGR sub-parameters (ISO 8613-6 / ITU-T T.416)

extension VTParserTests {
    /// Colon-form truecolor `38:2:r:g:b` must normalize to the same flat params the
    /// semicolon form produces, so the SGR interpreter applies the RGB color. Before the
    /// fix the colons were dropped and the digits concatenated into one garbage param.
    func testColonTruecolorForeground() {
        let events = parse("\u{1B}[38:2:255:0:0mX")
        XCTAssertEqual(events, [
            .csi(params: [38, 2, 255, 0, 0], finalByte: 0x6D, privateMarker: nil),
            .text("X"),
        ])
    }

    /// The ISO 8613-6 form carries an (often empty) colorspace id between `2` and R —
    /// `38:2::r:g:b` — which must be dropped, leaving 5 flat params.
    func testColonTruecolorWithEmptyColorspace() {
        let events = parse("\u{1B}[38:2::10:20:30m")
        XCTAssertEqual(events, [
            .csi(params: [38, 2, 10, 20, 30], finalByte: 0x6D, privateMarker: nil),
        ])
    }

    /// Colon-form indexed color `38:5:n` → `38 ; 5 ; n`.
    func testColonIndexedColor() {
        let events = parse("\u{1B}[38:5:200m")
        XCTAssertEqual(events, [
            .csi(params: [38, 5, 200], finalByte: 0x6D, privateMarker: nil),
        ])
    }

    /// Underline color via colon form (`58:2::r:g:b`).
    func testColonUnderlineColor() {
        let events = parse("\u{1B}[58:2::0:255:0m")
        XCTAssertEqual(events, [
            .csi(params: [58, 2, 0, 255, 0], finalByte: 0x6D, privateMarker: nil),
        ])
    }

    /// `4:3` (curly) and other underline styles must map to plain underline-on (SGR 4),
    /// never be mis-parsed as `4;3` (underline + italic).
    func testColonUnderlineStyleMapsToUnderlineOn() {
        XCTAssertEqual(parse("\u{1B}[4:3m"), [
            .csi(params: [4], finalByte: 0x6D, privateMarker: nil),
        ])
        // style 0 = no underline → SGR 24 (underline off).
        XCTAssertEqual(parse("\u{1B}[4:0m"), [
            .csi(params: [24], finalByte: 0x6D, privateMarker: nil),
        ])
    }

    /// A mix of plain, underline-style, and colon-truecolor groups in one SGR.
    func testMixedColonAndSemicolonGroups() {
        let events = parse("\u{1B}[1;4:3;38:2:10:20:30m")
        XCTAssertEqual(events, [
            .csi(params: [1, 4, 38, 2, 10, 20, 30], finalByte: 0x6D, privateMarker: nil),
        ])
    }

    /// The plain semicolon truecolor form is unaffected (fast path, no colon).
    func testSemicolonTruecolorUnchanged() {
        let events = parse("\u{1B}[38;2;1;2;3m")
        XCTAssertEqual(events, [
            .csi(params: [38, 2, 1, 2, 3], finalByte: 0x6D, privateMarker: nil),
        ])
    }
}

// MARK: - Parser-state bounds (unbounded-growth hardening)

extension VTParserTests {
    /// A flood of `;` in a CSI must not grow `params` without bound — it's capped, and
    /// the parser still terminates and dispatches on the final byte (no hang/crash).
    func testCSIParamCountIsCapped() {
        let flood = "\u{1B}[" + String(repeating: "1;", count: 500) + "m"
        let events = parse(flood)
        guard case .csi(let params, let finalByte, _)? = events.first else {
            return XCTFail("expected a CSI dispatch, got \(events)")
        }
        XCTAssertEqual(finalByte, 0x6D)
        XCTAssertLessThanOrEqual(params.count, 32, "params must be bounded")
        XCTAssertEqual(events.count, 1)
    }

    /// A large-but-reasonable OSC (well under the cap) still dispatches intact — the cap
    /// must not truncate legitimate payloads (e.g. an OSC 52 clipboard set).
    func testLargeOSCUnderCapDispatchesIntact() {
        let payload = String(repeating: "a", count: 200_000)
        let events = parse("\u{1B}]52;c;\(payload)\u{07}")
        XCTAssertEqual(events, [.osc(["52", "c", payload])])
    }
}

// MARK: - DCS / tmux -CC takeover (P3-4)

extension VTParserTests {
    /// `ESC P1000p` is tmux's "enter control mode": the parser must flag detection, stop
    /// interpreting, and stash everything after the final byte as the takeover remainder.
    func testTmuxControlModeDCSDetected() {
        let p = VTParser()
        let d = RecordingDelegate()
        p.delegate = d
        p.feed(Data("before\u{1B}P1000p%begin 1 2 0\r\n".utf8))
        XCTAssertTrue(p.tmuxControlModeDetected)
        XCTAssertEqual(d.events, [.text("before")], "nothing after the DCS may be interpreted")
        XCTAssertEqual(p.takeTakeoverRemainder(), Data("%begin 1 2 0\r\n".utf8))
        // Subsequent feeds keep accumulating raw control bytes.
        p.feed(Data("%output %0 hi\r\n".utf8))
        XCTAssertEqual(p.takeTakeoverRemainder(), Data("%output %0 hi\r\n".utf8))
        XCTAssertEqual(d.events, [.text("before")])
        // endTmuxTakeover resumes normal parsing.
        p.endTmuxTakeover()
        XCTAssertFalse(p.tmuxControlModeDetected)
        p.feed(Data("after".utf8))
        XCTAssertEqual(d.events, [.text("before"), .text("after")])
    }

    /// A non-tmux DCS (e.g. DECRQSS/sixel-shaped) must be swallowed up to ST — its payload
    /// may not leak into the grid as text — and must NOT trigger takeover.
    func testOtherDCSIsSwallowedWithoutTakeover() {
        let events = parse("a\u{1B}P0;1qPAYLOAD\u{1B}\\b")
        XCTAssertEqual(events, [.text("a"), .text("b")])

        let p = VTParser()
        p.feed(Data("\u{1B}P0;1qPAYLOAD\u{1B}\\".utf8))
        XCTAssertFalse(p.tmuxControlModeDetected)
    }

    /// The detection requires exactly params [1000] and final 'p' — `1000q` or `999p`
    /// must not take the stream over.
    func testNearMissDCSDoesNotTakeOver() {
        for s in ["\u{1B}P1000qX\u{1B}\\t", "\u{1B}P999pX\u{1B}\\t", "\u{1B}P1000;1pX\u{1B}\\t"] {
            let p = VTParser()
            let d = RecordingDelegate()
            p.delegate = d
            p.feed(Data(s.utf8))
            XCTAssertFalse(p.tmuxControlModeDetected, "near-miss \(s.debugDescription) took over")
            XCTAssertEqual(d.events, [.text("t")], "payload of \(s.debugDescription) leaked")
        }
    }
}

// MARK: - DCS false-start hardening (§15.2 "TUI commands stopped being processed")

extension VTParserTests {
    /// A C0 control inside a DCS payload marks a FALSE START (real sixel/DECRQSS payloads
    /// never contain C0) — the parser must bail to ground and reprocess the byte, so a
    /// stray ESC P can't swallow CSI commands all the way to a far-away ST.
    func testFalseDCSAbortsOnC0Control() {
        let events = parse("a\u{1B}Pxoo\rbar")
        XCTAssertEqual(events, [.text("a"), .execute(0x0D), .text("bar")],
                       "CR inside a 'DCS payload' must abort the swallow and execute")
    }

    /// ESC [ inside a DCS payload is a CSI starting — the false DCS must yield and let the
    /// CSI parse for real (cursor/erase commands must never be swallowed).
    func testFalseDCSYieldsToCSI() {
        let events = parse("\u{1B}P0q\u{1B}[31mX")
        XCTAssertEqual(events, [
            .csi(params: [31], finalByte: 0x6D, privateMarker: nil),
            .text("X"),
        ])
    }

    /// A well-formed DCS (printable payload, ST-terminated) is still swallowed whole.
    func testWellFormedDCSStillSwallowed() {
        let events = parse("\u{1B}P0;1q#0;2;0;0;0-ooo\u{1B}\\after")
        XCTAssertEqual(events, [.text("after")])
    }

    /// A C0 in the DCS *parameter* section also aborts and reprocesses (not eaten).
    func testFalseDCSParamAbortsOnC0() {
        let events = parse("\u{1B}P12\nrest")
        XCTAssertEqual(events, [.execute(0x0A), .text("rest")])
    }
}
