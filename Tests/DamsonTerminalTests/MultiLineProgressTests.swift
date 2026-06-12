import XCTest
@testable import DamsonTerminal

/// Reproduces Homebrew-style multi-line progress redraws. brew's concurrent
/// download UI repaints its status block by moving the cursor to the start of
/// the line N rows up (CPL, `ESC[NF`) and rewriting each line — if CPL (or its
/// sibling CNL, `ESC[NE`) is dropped, every refresh appends a fresh copy of
/// the block below the previous one instead of updating in place. Field
/// report: `brew install wrangler` duplicated its two download-progress lines
/// on every spinner tick.
final class MultiLineProgressTests: XCTestCase {
    private final class FakeBackend: SessionIOBackend {
        var onData: ((Data) -> Void)?
        var onExit: ((Int32) -> Void)?
        func spawn(argv: [String], env: [String: String], cwd: String?, cols: Int, rows: Int) throws {}
        func write(_ data: Data) {}
        func resize(cols: Int, rows: Int) {}
        func terminate() {}
        var childWorkingDirectory: String? { nil }
        var isRunningForegroundJob: Bool { false }
    }

    private func makeSession(cols: Int = 80, rows: Int = 24) -> (DamsonSession, FakeBackend) {
        let backend = FakeBackend()
        let session = DamsonSession(config: DamsonConfig(), backend: backend)
        session.resize(cols: cols, rows: rows)
        return (session, backend)
    }

    private func feed(_ backend: FakeBackend, _ s: String) {
        backend.onData?(Data(s.utf8))
    }

    private func screenLines(_ session: DamsonSession) -> [String] {
        let g = session.grid
        return (0..<g.rows).map { r in
            var line = ""
            for c in g.row(r) where !c.isContinuation { line.append(c.char) }
            while line.hasSuffix(" ") { line.removeLast() }
            return line
        }
    }

    /// brew-style block repaint: print N lines, then ESC[NF + rewrite, several
    /// times. The block must update in place — no duplicates below.
    func testCPLRedrawsProgressBlockInPlace() {
        let (session, backend) = makeSession()
        feed(backend, "==> Fetching downloads\r\n")
        // Initial block (two progress lines, cursor ends on the line below).
        feed(backend, "formula.jws.json   0.0MB\r\ncask.jws.json   0.0MB\r\n")
        // Three spinner refreshes, each: cursor to start of line 2 rows up,
        // rewrite both lines (EL clears the tails).
        for tick in 1...3 {
            feed(backend, "\u{1B}[2F")
            feed(backend, "formula.jws.json  \(tick * 11).3MB\u{1B}[K\r\n")
            feed(backend, "cask.jws.json  \(tick * 7).2MB\u{1B}[K\r\n")
        }
        let lines = screenLines(session)
        XCTAssertEqual(lines[0], "==> Fetching downloads")
        XCTAssertEqual(lines[1], "formula.jws.json  33.3MB")
        XCTAssertEqual(lines[2], "cask.jws.json  21.2MB")
        XCTAssertEqual(lines[3], "", "block duplicated below instead of updating in place")
        XCTAssertEqual(session.grid.scrollback.count, 0, "in-place repaint must not scroll")
    }

    /// CNL (ESC[E) is CPL's downward twin: down N lines, column 1.
    func testCNLMovesToStartOfLineBelow() {
        let (session, backend) = makeSession()
        feed(backend, "aaaa\r\nbbbb\r\ncccc")
        // From end of row 2, up to row 0 col 1, then CNL down 1 → row 1 col 1.
        feed(backend, "\u{1B}[2F\u{1B}[1EXX")
        let lines = screenLines(session)
        XCTAssertEqual(lines[0], "aaaa")
        XCTAssertEqual(lines[1], "XXbb")
        XCTAssertEqual(lines[2], "cccc")
    }

    /// CPL/CNL clamp at the screen edges (no scrolling), like CUU/CUD.
    func testCPLClampsAtTop() {
        let (session, backend) = makeSession()
        feed(backend, "top\r\nnext")
        feed(backend, "\u{1B}[99FX")   // way past the top → row 0, col 1
        let lines = screenLines(session)
        XCTAssertEqual(lines[0], "Xop")
        XCTAssertEqual(lines[1], "next")
    }
}
