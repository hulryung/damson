import XCTest
@testable import DamsonTerminal

/// Scroll accounting for an Ink-style live region that outgrows the screen.
///
/// Claude Code redraws a streaming message by erasing the block it drew last time — cursor up
/// one row, erase line, repeat — then writing the new, longer block. The erase reaches only
/// rows still on screen, so once the block is taller than the terminal its top has already
/// gone to scrollback, the cursor-up clamps at row 0, and the rewrite puts those lines on
/// screen again. Scrolling up then shows them twice. Field report: a Claude Code markdown
/// table whose top rule stood on two consecutive rows.
///
/// That duplication is in the app's byte stream — no terminal can erase what left the screen.
/// What IS damson's to get right is the count: scroll one row earlier than the stream asks and
/// the app's erase misses by a row, turning a clean redraw into a duplicated one. So this
/// compares damson against an independent model of the same stream, built here from the VT
/// rules alone. Divergence is damson's bug; agreement means the doubling came in with the bytes.
final class OversizedRedrawTests: XCTestCase {
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

    /// A deliberately tiny terminal — only what this fixture emits. Independent of `Grid`,
    /// so agreement between the two is evidence rather than a tautology.
    private struct ModelTerminal {
        let cols: Int, rows: Int
        var scrollback: [String] = []
        var screen: [String]
        var row = 0, col = 0
        init(cols: Int, rows: Int) {
            self.cols = cols; self.rows = rows
            screen = Array(repeating: "", count: rows)
        }
        mutating func lineFeed() {
            if row == rows - 1 {
                scrollback.append(screen[0])
                screen.removeFirst()
                screen.append("")
            } else {
                row += 1
            }
        }
        mutating func put(_ s: String) {
            var line = screen[row]
            if line.count < col { line += String(repeating: " ", count: col - line.count) }
            let head = String(line.prefix(col))
            let tailStart = min(line.count, col + s.count)
            let tail = String(line.dropFirst(tailStart))
            screen[row] = String((head + s + tail).prefix(cols))
            col = min(col + s.count, cols)
        }
        mutating func eraseLine() { screen[row] = ""; }
        mutating func eraseToEnd() { screen[row] = String(screen[row].prefix(col)) }
        mutating func carriageReturn() { col = 0 }
        mutating func cursorUp() { row = max(0, row - 1) }
        var unified: [String] { scrollback + screen }
    }

    private func feed(_ b: FakeBackend, _ s: String) { b.onData?(Data(s.utf8)) }

    private func unified(_ session: DamsonSession) -> [String] {
        let g = session.grid
        return (0..<(g.scrollback.count + g.rows)).map { r in
            var line = ""
            for c in g.unifiedRow(r) where !c.isContinuation && !c.isWideSpacer { line.append(c.char) }
            while line.hasSuffix(" ") { line.removeLast() }
            return line
        }
    }

    /// One redraw frame, as both a byte stream and a sequence of model operations.
    private enum Op {
        case text(String), cr, lf, eraseLine, eraseToEnd, cursorUp
        var bytes: String {
            switch self {
            case .text(let s): return s
            case .cr: return "\r"
            case .lf: return "\n"
            case .eraseLine: return "\u{1B}[2K"
            case .eraseToEnd: return "\u{1B}[K"
            case .cursorUp: return "\u{1B}[1A"
            }
        }
    }

    func testDamsonScrollsExactlyAsOftenAsTheStreamAsks() {
        let cols = 40, rows = 10
        let backend = FakeBackend()
        let session = DamsonSession(config: DamsonConfig(), backend: backend)
        session.resize(cols: cols, rows: rows)
        feed(backend, "\u{1B}[?2026h\u{1B}[?2026l")   // a TUI, as Claude Code announces itself
        var model = ModelTerminal(cols: cols, rows: rows)

        func body(_ n: Int) -> [String] {
            (0..<n).map { i in
                i == 0 ? "+-------- table top --------+" : "line \(String(format: "%02d", i))"
            }
        }

        var ops: [Op] = []
        var drawn = 0
        for frame in 1...(rows + 6) {
            // ansi-escapes eraseLines(drawn): erase this line, step up, repeat; then column 1.
            for i in 0..<drawn {
                ops.append(.eraseLine)
                if i < drawn - 1 { ops.append(.cursorUp) }
            }
            if drawn > 0 { ops.append(.cr) }
            let lines = body(frame)
            for (i, line) in lines.enumerated() {
                ops.append(.text(line))
                ops.append(.eraseToEnd)
                if i < lines.count - 1 { ops.append(.cr); ops.append(.lf) }
            }
            drawn = lines.count
        }

        for op in ops {
            feed(backend, op.bytes)
            switch op {
            case .text(let s): model.put(s)
            case .cr: model.carriageReturn()
            case .lf: model.lineFeed()
            case .eraseLine: model.eraseLine()
            case .eraseToEnd: model.eraseToEnd()
            case .cursorUp: model.cursorUp()
            }
        }

        let got = unified(session)
        let want = model.unified.map { line -> String in
            var s = line
            while s.hasSuffix(" ") { s.removeLast() }
            return s
        }
        XCTAssertEqual(got.count, want.count,
                       "damson scrolled \(got.count - want.count) row(s) more than the stream asked for")
        if got.count == want.count {
            for (i, pair) in zip(got, want).enumerated() where pair.0 != pair.1 {
                XCTFail("row \(i): damson \"\(pair.0)\" vs model \"\(pair.1)\"")
            }
        }

        // And record what the stream itself produces, so the doubling has a documented source.
        var seen: [String: Int] = [:]
        for line in want where line.hasPrefix("line ") { seen[line, default: 0] += 1 }
        XCTAssertFalse(seen.filter { $0.value > 1 }.isEmpty,
                       "fixture no longer outgrows the screen — it is not testing the case")
    }
}
