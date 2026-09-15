import XCTest
@testable import DamsonTerminal

/// Queries a program sends to learn what the terminal can do, and the answers it waits for.
///
/// Claude Code asks XTVERSION first and asks DECRQM 2026 only if XTVERSION is answered. With
/// neither answered it guesses from the environment, finds no terminal it knows, and draws
/// without synchronized output — so a frame that a PTY read splits in two reaches the screen
/// half-written: under scrolling output the input box and status line flicker. Measured on
/// 2026-09-16 by recording a real session: 12 of 74 frames torn without sync, 0 of 121 with.
final class TerminalQueryTests: XCTestCase {
    /// Captures everything the session writes back toward the program (PTY input).
    private final class CapturingBackend: SessionIOBackend {
        var onData: ((Data) -> Void)?
        var onExit: ((Int32) -> Void)?
        var written = Data()
        func spawn(argv: [String], env: [String: String], cwd: String?, cols: Int, rows: Int) throws {}
        func write(_ data: Data) { written.append(data) }
        func resize(cols: Int, rows: Int) {}
        func terminate() {}
        var childWorkingDirectory: String? { nil }
        var isRunningForegroundJob: Bool { false }
    }

    private func session() -> (DamsonSession, CapturingBackend) {
        let backend = CapturingBackend()
        let s = DamsonSession(config: DamsonConfig(), backend: backend)
        s.resize(cols: 80, rows: 24)
        return (s, backend)
    }

    private func feed(_ b: CapturingBackend, _ s: String) { b.onData?(Data(s.utf8)) }

    /// What the session writes back for `query`, and nothing written before it.
    /// (Callers keep the session alive: `pty.onData` holds it weakly — see DSRTests.)
    private func reply(_ b: CapturingBackend, to query: String) -> String {
        b.written.removeAll()
        feed(b, query)
        return String(decoding: b.written, as: UTF8.self)
    }

    // MARK: - XTVERSION

    func testXTVERSIONNamesTheTerminal() {
        let (s, b) = session()
        withExtendedLifetime(s) {
            for query in ["\u{1B}[>0q", "\u{1B}[>q"] {
                let r = reply(b, to: query)
                XCTAssertTrue(r.hasPrefix("\u{1B}P>|damson"), "\(query.debugDescription) → \(r.debugDescription)")
                XCTAssertTrue(r.hasSuffix("\u{1B}\\"), "\(query.debugDescription) → \(r.debugDescription)")
            }
        }
    }

    /// Probes put DA1 right behind XTVERSION as a sentinel: every terminal answers DA1, so a
    /// DA1 answer arriving first means XTVERSION went unanswered. This is Claude Code's probe.
    func testXTVERSIONIsAnsweredBeforeTheDA1Sentinel() {
        let (s, b) = session()
        withExtendedLifetime(s) {
            let r = reply(b, to: "\u{1B}[>0q\u{1B}[c")
            XCTAssertTrue(r.hasPrefix("\u{1B}P>|damson"), r.debugDescription)
            XCTAssertTrue(r.hasSuffix("\u{1B}\\\u{1B}[?6c"), r.debugDescription)
        }
    }

    /// `q` is shared: with a space intermediate it is DECSCUSR, which changes state and
    /// answers nothing. Answering XTVERSION must not take that away.
    func testDECSCUSRStillSetsTheCursorShapeAndAnswersNothing() {
        let (s, b) = session()
        withExtendedLifetime(s) {
            XCTAssertEqual(reply(b, to: "\u{1B}[5 q"), "")
            XCTAssertEqual(s.grid.cursorShape, .bar)
        }
    }

    // MARK: - DECRQM

    /// The answer Claude Code turns synchronized output on for: 2026 is known, and reported
    /// set (1) inside a synchronized update and reset (2) outside one.
    func testDECRQMReportsSynchronizedOutput() {
        let (s, b) = session()
        withExtendedLifetime(s) {
            XCTAssertEqual(reply(b, to: "\u{1B}[?2026$p"), "\u{1B}[?2026;2$y")
            feed(b, "\u{1B}[?2026h")
            XCTAssertEqual(reply(b, to: "\u{1B}[?2026$p"), "\u{1B}[?2026;1$y")
            feed(b, "\u{1B}[?2026l")
            XCTAssertEqual(reply(b, to: "\u{1B}[?2026$p"), "\u{1B}[?2026;2$y")
        }
    }

    /// Every mode damson tracks is reported as it actually stands, so the answer can be trusted.
    func testDECRQMReportsTheModesDamsonTracks() {
        let (s, b) = session()
        withExtendedLifetime(s) {
            XCTAssertEqual(reply(b, to: "\u{1B}[?25$p"), "\u{1B}[?25;1$y")        // cursor shown
            feed(b, "\u{1B}[?25l")
            XCTAssertEqual(reply(b, to: "\u{1B}[?25$p"), "\u{1B}[?25;2$y")

            XCTAssertEqual(reply(b, to: "\u{1B}[?2004$p"), "\u{1B}[?2004;2$y")
            feed(b, "\u{1B}[?2004h")
            XCTAssertEqual(reply(b, to: "\u{1B}[?2004$p"), "\u{1B}[?2004;1$y")

            XCTAssertEqual(reply(b, to: "\u{1B}[?1049$p"), "\u{1B}[?1049;2$y")
            feed(b, "\u{1B}[?1049h")
            XCTAssertEqual(reply(b, to: "\u{1B}[?1049$p"), "\u{1B}[?1049;1$y")

            feed(b, "\u{1B}[?1002h\u{1B}[?1006h")
            XCTAssertEqual(reply(b, to: "\u{1B}[?1002$p"), "\u{1B}[?1002;1$y")
            XCTAssertEqual(reply(b, to: "\u{1B}[?1000$p"), "\u{1B}[?1000;2$y")  // only the strongest is kept
            XCTAssertEqual(reply(b, to: "\u{1B}[?1006$p"), "\u{1B}[?1006;1$y")

            // ANSI (non-private) modes: IRM is the one damson implements.
            XCTAssertEqual(reply(b, to: "\u{1B}[4$p"), "\u{1B}[4;2$y")
            feed(b, "\u{1B}[4h")
            XCTAssertEqual(reply(b, to: "\u{1B}[4$p"), "\u{1B}[4;1$y")
        }
    }

    /// A mode damson does not know is answered 0, "not recognized", rather than left
    /// hanging — the program stops waiting at once instead of at its timeout.
    func testDECRQMAnswersUnknownModesAsNotRecognized() {
        let (s, b) = session()
        withExtendedLifetime(s) {
            XCTAssertEqual(reply(b, to: "\u{1B}[?9999$p"), "\u{1B}[?9999;0$y")
            XCTAssertEqual(reply(b, to: "\u{1B}[20$p"), "\u{1B}[20;0$y")
        }
    }
}
