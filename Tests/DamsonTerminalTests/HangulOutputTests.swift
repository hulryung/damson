import XCTest
@testable import DamsonTerminal

/// Reproduces whether Hangul output breaks when it arrives split across a write
/// boundary (PTY read). Mirrors DamsonSession's parser.didEmitText →
/// grid.putChar(per grapheme) flow.
final class HangulOutputTests: XCTestCase {
    private final class Sink: VTParserDelegate {
        let grid: Grid
        init(_ g: Grid) { grid = g }
        func vtParser(_ parser: VTParser, didEmitText text: String) {
            for ch in text { grid.putChar(ch) }
        }
        func vtParser(_ parser: VTParser, didExecute byte: UInt8) {}
        func vtParser(_ parser: VTParser, didEmitCSI params: [Int], intermediates: [UInt8],
                      finalByte: UInt8, privateMarker: UInt8?) {}
        func vtParser(_ parser: VTParser, didEmitOSC params: [String]) {}
    }

    /// Feeds the chunks in order, then concatenates and returns the characters in row0.
    private func render(_ chunks: [[UInt8]]) -> String {
        let grid = Grid(cols: 20, rows: 2, pen: CellAttrs(fg: .default))
        let parser = VTParser()
        let sink = Sink(grid)
        parser.delegate = sink
        for c in chunks { parser.feed(Data(c)) }
        var s = ""
        for col in 0..<20 {
            let cell = grid.cell(row: 0, col: col)
            if cell.isContinuation { continue }
            if cell.char == " " { break }
            s.append(cell.char)
        }
        return s
    }

    // 개 U+AC1C, 선 U+C120, 점 U+C810 (NFC)
    private let nfc: [UInt8] = [0xEA, 0xB0, 0x9C, 0xEC, 0x84, 0xA0, 0xEC, 0xA0, 0x90]
    // NFD: 개=ㄱㅐ, 선=ㅅㅓㄴ, 점=ㅈㅓㅁ
    private let nfd: [UInt8] = [
        0xE1, 0x84, 0x80, 0xE1, 0x85, 0xA2,             // 개
        0xE1, 0x84, 0x89, 0xE1, 0x85, 0xA5, 0xE1, 0x86, 0xAB, // 선
        0xE1, 0x84, 0x8C, 0xE1, 0x85, 0xA5, 0xE1, 0x86, 0xB7, // 점
    ]

    func testNFCWhole() { XCTAssertEqual(render([nfc]), "개선점") }

    func testNFCSplitEveryByte() {
        // Feed one byte at a time — verifies partial UTF-8 reassembly.
        XCTAssertEqual(render(nfc.map { [$0] }), "개선점")
    }

    func testNFDWhole() { XCTAssertEqual(render([nfd]), "개선점") }

    func testNFDSplitAtJamo() {
        // One chunk up through "점"'s ㅈㅓ, with the final ㅁ (U+11B7) in the next
        // chunk — the real case where NFD splits into Jamo at a write boundary.
        let head = Array(nfd[0..<(nfd.count - 3)])   // up through 개선저 (ㅈㅓ)
        let tail = Array(nfd[(nfd.count - 3)...])     // ㅁ (U+11B7)
        XCTAssertEqual(render([head, tail]), "개선점")
    }

    func testNFDOneJamoPerFeed() {
        // Feed one Jamo (3 bytes) at a time.
        var chunks: [[UInt8]] = []
        var i = 0
        while i < nfd.count { chunks.append(Array(nfd[i..<i + 3])); i += 3 }
        XCTAssertEqual(render(chunks), "개선점")
    }

    func testNFCSplitMidByteEachChar() {
        // Split each character into 2+1 bytes.
        let chunks: [[UInt8]] = [
            [0xEA, 0xB0], [0x9C],   // 개
            [0xEC, 0x84], [0xA0],   // 선
            [0xEC, 0xA0], [0x90],   // 점
        ]
        XCTAssertEqual(render(chunks), "개선점")
    }

    // MARK: cleanup of partial overwrites of wide characters (the real cause of TUI redraw breakage)

    func testOverwriteWideLeadClearsOrphanContinuation() {
        let g = Grid(cols: 10, rows: 2, pen: CellAttrs(fg: .default))
        g.putChar("점")                 // col0 lead, col1 continuation
        XCTAssertTrue(g.cell(row: 0, col: 1).isContinuation)
        g.setCursor(row: 1, col: 1)      // (0,0)
        g.putChar("x")                   // overwrite the lead
        XCTAssertEqual(g.cell(row: 0, col: 0).char, "x")
        XCTAssertFalse(g.cell(row: 0, col: 1).isContinuation, "orphan continuation removed")
    }

    func testOverwriteWideContinuationClearsOrphanLead() {
        let g = Grid(cols: 10, rows: 2, pen: CellAttrs(fg: .default))
        g.putChar("점")
        g.setCursor(row: 1, col: 2)      // (0,1) = continuation
        g.putChar("x")
        XCTAssertEqual(g.cell(row: 0, col: 1).char, "x")
        XCTAssertEqual(g.cell(row: 0, col: 0).char, " ", "orphan lead removed")
    }

    func testWideOverWideClearsTrailingOrphan() {
        let g = Grid(cols: 10, rows: 2, pen: CellAttrs(fg: .default))
        g.putChar("점")                 // col0-1
        g.putChar("안")                 // col2-3
        g.setCursor(row: 1, col: 2)      // (0,1) = 점 continuation
        g.putChar("강")                 // wide → overwrites col1-2
        XCTAssertEqual(g.cell(row: 0, col: 0).char, " ", "점 lead removed")
        XCTAssertEqual(g.cell(row: 0, col: 1).char, "강")
        XCTAssertTrue(g.cell(row: 0, col: 2).isContinuation)
        XCTAssertFalse(g.cell(row: 0, col: 3).isContinuation, "안 orphan continuation removed")
    }

    func testNFDPointWithSGRBetweenJamo() {
        // The case where a streaming re-render inserts an SGR (color) escape between Jamo.
        // 개선 + (ㅈ) ESC[33m (ㅓ) (ㅁ) — an SGR with no cursor movement.
        let head = Array(nfd[0..<(nfd.count - 9)])  // up through 개선
        let cho: [UInt8] = [0xE1, 0x84, 0x8C]       // ㅈ
        let sgr: [UInt8] = [0x1B, 0x5B, 0x33, 0x33, 0x6D]  // ESC[33m
        let jung: [UInt8] = [0xE1, 0x85, 0xA5]      // ㅓ
        let jong: [UInt8] = [0xE1, 0x86, 0xB7]      // ㅁ
        XCTAssertEqual(render([head, cho, sgr, jung, jong]), "개선점")
    }
}
