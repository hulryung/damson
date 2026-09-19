import XCTest
@testable import DamsonTerminal

/// A row must not end up in scrollback AND in the viewport after a shrink.
///
/// Shrinking the window pushes rows off the top into scrollback. A full-screen TUI on the
/// primary screen answers the SIGWINCH by repainting the whole viewport from its own model,
/// starting at CUP home — so whatever damson pushed is written again inside the viewport, and
/// scrolling up shows the line twice. Field report: a Claude Code markdown table whose top
/// rule appeared on two consecutive rows, one row apart.
final class ResizeDuplicateRowTests: XCTestCase {
    private final class FakeBackend: SessionIOBackend {
        var onData: ((Data) -> Void)?
        var onExit: ((Int32) -> Void)?
        var resizes: [(Int, Int)] = []
        func spawn(argv: [String], env: [String: String], cwd: String?, cols: Int, rows: Int) throws {}
        func write(_ data: Data) {}
        func resize(cols: Int, rows: Int) { resizes.append((cols, rows)) }
        func terminate() {}
        var childWorkingDirectory: String? { nil }
        var isRunningForegroundJob: Bool { false }
    }

    private func feed(_ b: FakeBackend, _ s: String) { b.onData?(Data(s.utf8)) }

    /// Every line of the unified buffer, trailing blanks trimmed.
    private func unified(_ session: DamsonSession) -> [String] {
        let g = session.grid
        return (0..<(g.scrollback.count + g.rows)).map { r in
            var line = ""
            for c in g.unifiedRow(r) where !c.isContinuation && !c.isWideSpacer { line.append(c.char) }
            while line.hasSuffix(" ") { line.removeLast() }
            return line
        }
    }

    /// The app's model: a transcript that is taller than the screen, so the top of it has
    /// already scrolled into scrollback by the time the resize lands.
    private func transcript(_ n: Int) -> [String] {
        (0..<n).map { i in
            switch i % 4 {
            case 0: return "┌──────────┬──────────┐ block \(i)"
            case 1: return "│ cell \(i)   │ cell \(i)   │"
            case 2: return "├──────────┼──────────┤ block \(i)"
            default: return "└──────────┴──────────┘ block \(i)"
            }
        }
    }

    func testShrinkDoesNotDuplicateTheRowItPushes() {
        let cols = 40, rows = 12
        let backend = FakeBackend()
        let session = DamsonSession(config: DamsonConfig(), backend: backend)
        session.resize(cols: cols, rows: rows)
        // A TUI: sticky sync output, and a repaint that erases from home.
        feed(backend, "\u{1B}[?2026h\u{1B}[?2026l")

        let lines = transcript(20)
        for line in lines { feed(backend, line + "\r\n") }
        // Claude Code parks its cursor in the input box with a status line BELOW it, so the
        // bottom of the viewport is not blank and a shrink cannot trim there — it has to push
        // from the top. Reproduce that: two footer rows, cursor back up onto the first.
        feed(backend, "input line\r\n")
        feed(backend, "status line")
        feed(backend, "\u{1B}[1A\r")

        let before = unified(session)
        let beforeCount = before.filter { $0.hasPrefix("┌") }.count

        // SIGWINCH: one row shorter.
        session.resize(cols: cols, rows: rows - 1)
        // The TUI repaints its whole viewport from its own model, top-aligned from home —
        // the tail of the same transcript, which is what Claude Code does.
        feed(backend, "\u{1B}[?2026h\u{1B}[H\u{1B}[J")
        let visible = lines.suffix(rows - 1)
        for (i, line) in visible.enumerated() {
            feed(backend, line)
            if i < visible.count - 1 { feed(backend, "\r\n") }
        }
        feed(backend, "\u{1B}[?2026l")

        let after = unified(session)
        let afterCount = after.filter { $0.hasPrefix("┌") }.count

        // Each "┌" line of the transcript must appear exactly once, before and after.
        var seen: [String: Int] = [:]
        for line in after where line.hasPrefix("┌") { seen[line, default: 0] += 1 }
        let dupes = seen.filter { $0.value > 1 }.keys.sorted()
        XCTAssertEqual(beforeCount, 5, "fixture: five box tops printed")
        XCTAssertTrue(dupes.isEmpty,
                      "a shrink duplicated \(dupes.count) row(s) — scrollback kept the pushed "
                      + "copy while the repaint wrote it again: \(dupes)")
        XCTAssertEqual(afterCount, beforeCount,
                       "box-top count changed across the resize (\(beforeCount) → \(afterCount))")
    }
}
