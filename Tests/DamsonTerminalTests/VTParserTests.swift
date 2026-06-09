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
