import XCTest
@testable import DamsonTerminal

/// Unit tests for multi-row URL detection: soft-wrapped URLs, TUI-style hard-wrapped
/// URLs with indented continuation rows (the Claude Code shape), and the prose guards
/// that keep ordinary wrapped text from being glued onto a URL.
final class MultiRowURLDetectorTests: XCTestCase {

    /// Build rows from strings; pad to `cols`. `wrappedRows` marks soft-wrap flags.
    private func probe(
        rows: [String], wrappedRows: Set<Int> = [], cols: Int = 40,
        at: (row: Int, col: Int)
    ) -> MultiRowURLDetector.Match? {
        MultiRowURLDetector.match(at: at.row, col: at.col, totalCols: cols) { r in
            guard r >= 0, r < rows.count else { return nil }
            var text = Array(rows[r])
            if text.count < cols { text += Array(repeating: " ", count: cols - text.count) }
            return MultiRowURLDetector.RowData(
                chars: text, cols: Array(0..<text.count), wrapped: wrappedRows.contains(r))
        }
    }

    // MARK: - Single row (baseline)

    func testSingleRowURLStillDetects() {
        let m = probe(rows: ["see https://example.com/x ok"], at: (0, 10))
        XCTAssertEqual(m?.url.absoluteString, "https://example.com/x")
        XCTAssertEqual(m?.segments.count, 1)
        XCTAssertEqual(m?.segments[0].cols, 4..<25)
    }

    func testClickOutsideURLReturnsNil() {
        XCTAssertNil(probe(rows: ["see https://example.com/x ok"], at: (0, 1)))
        XCTAssertNil(probe(rows: ["plain text no link here"], at: (0, 5)))
    }

    // MARK: - Soft wrap

    func testSoftWrappedURLJoinsBothRows() {
        // One logical line, terminal-wrapped at col 40 mid-URL.
        let r0 = "open https://example.com/aaaa/bbbb/cccc/"  // 40 cols exactly
        let r1 = "dddd?x=1 now"
        let m = probe(rows: [r0, r1], wrappedRows: [0], at: (0, 20))
        XCTAssertEqual(m?.url.absoluteString, "https://example.com/aaaa/bbbb/cccc/dddd?x=1")
        XCTAssertEqual(m?.segments.count, 2, "match must span both rows")
        // Clicking the SECOND row's portion resolves the same full URL.
        let m2 = probe(rows: [r0, r1], wrappedRows: [0], at: (1, 3))
        XCTAssertEqual(m2?.url.absoluteString, "https://example.com/aaaa/bbbb/cccc/dddd?x=1")
    }

    func testSoftWrapChainOfThreeRows() {
        let r0 = "x https://e.com/aaaaaaaaaaaaaaaaaaaaaaaaaa"  // wraps
        let r1 = String(repeating: "b", count: 40)              // wraps
        let r2 = "cc/end"
        let m = probe(rows: [r0, r1, r2], wrappedRows: [0, 1], at: (1, 10))
        XCTAssertEqual(m?.url.absoluteString,
                       "https://e.com/aaaaaaaaaaaaaaaaaaaaaaaaaa"
                       + String(repeating: "b", count: 40) + "cc/end")
        XCTAssertEqual(m?.segments.count, 3)
    }

    // MARK: - TUI hard wrap (indented continuation — the Claude Code shape)

    func testHardWrapIndentedContinuationWithSlash() {
        // Continuation token carries URL structure ('/') → joined despite no wrap flag.
        let rows = [
            "  Read https://github.com/anthropics/cc",
            "     issues/123/comments",
        ]
        let m = probe(rows: rows, at: (0, 12))
        XCTAssertEqual(m?.url.absoluteString,
                       "https://github.com/anthropics/ccissues/123/comments")
        // Click on the continuation row resolves the same URL.
        let m2 = probe(rows: rows, at: (1, 8))
        XCTAssertEqual(m2?.url.absoluteString,
                       "https://github.com/anthropics/ccissues/123/comments")
    }

    func testHardWrapCutMidTokenFlushToEdge() {
        // Cut mid-token at the right edge; long continuation token, no symbols —
        // joins via the (length ≥ 8 + flush-to-edge) rule.
        let rows = [
            "x https://e.com/path?id=ABCDEFGHIJKLMNOPQ",   // ends at col 41 of 42
            "   RSTUVWXYZ123",
        ]
        let m = probe(rows: rows, cols: 42, at: (0, 10))
        XCTAssertEqual(m?.url.absoluteString,
                       "https://e.com/path?id=ABCDEFGHIJKLMNOPQRSTUVWXYZ123")
    }

    func testHardWrapUpperEndsWithCutCharacter() {
        // Upper row is FULL and ends in '-' (cut at the right edge) → joined.
        let r0 = "  https://e.com/issue-"
        let m = probe(rows: [r0, "    42"], cols: r0.count, at: (0, 8))
        XCTAssertEqual(m?.url.absoluteString, "https://e.com/issue-42")
    }

    func testTrailingSlashURLMidLineDoesNotSwallowNextLineDash() {
        // Reported bug: a URL ending in '/' mid-line (not flush to the edge) must NOT glue
        // the following line's leading '-'.
        let rows = [
            "open: http://127.0.0.1:8092/",
            "- WASD / move",
        ]
        let m = probe(rows: rows, cols: 60, at: (0, 12))
        XCTAssertEqual(m?.url.absoluteString, "http://127.0.0.1:8092/",
                       "the next line's dash must not be pulled into the link")
        XCTAssertEqual(m?.segments.count, 1, "match must stay on the single row")
    }

    // MARK: - Prose guards (must NOT join)

    func testCompleteURLDoesNotSwallowNextProseLine() {
        // URL ends mid-row (not flush), next line is ordinary indented prose.
        let rows = [
            "see https://a.com",
            "    and then do something",
        ]
        let m = probe(rows: rows, at: (0, 8))
        XCTAssertEqual(m?.url.absoluteString, "https://a.com",
                       "prose continuation must not be glued onto a complete URL")
    }

    func testProseFlushToEdgeWithShortNextWordDoesNotJoin() {
        // Upper row is prose ending flush at the edge with a URL at the end; the next
        // word is short and symbol-free → no join.
        let rows = [
            "go to https://ex.com/page now read this",   // 39 of 40 — near edge
            "  carefully please",
        ]
        let m = probe(rows: rows, at: (0, 12))
        XCTAssertEqual(m?.url.absoluteString, "https://ex.com/page")
    }

    func testNewSchemeOnNextLineIsSeparateURL() {
        // Two stacked URLs (a list) must stay separate — the lower starts a scheme.
        let rows = [
            "https://first.example.com/aaaaaaaaaaaaaa",
            "https://second.example.com/b",
        ]
        let m = probe(rows: rows, at: (0, 10))
        XCTAssertEqual(m?.url.absoluteString, "https://first.example.com/aaaaaaaaaaaaaa")
        let m2 = probe(rows: rows, at: (1, 10))
        XCTAssertEqual(m2?.url.absoluteString, "https://second.example.com/b")
    }

    func testClickOnIndentBeforeContinuationIsNotALink() {
        let rows = [
            "  https://e.com/issue-",
            "    42",
        ]
        // Col 1 of the continuation row is inside the stripped indent.
        XCTAssertNil(probe(rows: rows, at: (1, 1)))
    }

    // MARK: - Segments (hover ranges)

    func testSegmentsCoverEachRowsPortion() {
        // cols: 22 makes the upper row flush with the right edge — the hard-wrap
        // join requires that (a URL ending mid-line with trailing blanks was not
        // wrapped and must not swallow the next line; see the joins() doc).
        let rows = [
            "  https://e.com/issue-",
            "    42 tail",
        ]
        let m = probe(rows: rows, cols: 22, at: (0, 8))
        XCTAssertEqual(m?.url.absoluteString, "https://e.com/issue-42")
        guard let segs = m?.segments, segs.count == 2 else {
            return XCTFail("expected 2 segments, got \(m?.segments.count ?? 0)")
        }
        XCTAssertEqual(segs[0].row, 0)
        XCTAssertEqual(segs[0].cols, 2..<22)
        XCTAssertEqual(segs[1].row, 1)
        XCTAssertEqual(segs[1].cols, 4..<6)
    }
}
