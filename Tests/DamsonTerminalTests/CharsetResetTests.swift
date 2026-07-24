import XCTest
@testable import DamsonTerminal

/// DEC Special Graphics (VT100 line-drawing via `ESC ( 0` / SI / SO) and RIS (`ESC c`)
/// full reset. Feeds bytes through a real DamsonSession and inspects the resulting grid.
final class CharsetResetTests: XCTestCase {
    private final class NoopBackend: SessionIOBackend {
        var onData: ((Data) -> Void)?
        var onExit: ((Int32) -> Void)?
        func spawn(argv: [String], env: [String: String], cwd: String?, cols: Int, rows: Int) throws {}
        func write(_ data: Data) {}
        func resize(cols: Int, rows: Int) {}
        func terminate() {}
        var childWorkingDirectory: String? { nil }
        var isRunningForegroundJob: Bool { false }
    }

    private func session(cols: Int = 20, rows: Int = 6) -> (DamsonSession, NoopBackend) {
        let b = NoopBackend()
        let s = DamsonSession(config: DamsonConfig(), backend: b)
        s.resize(cols: cols, rows: rows)
        return (s, b)
    }

    private func feed(_ b: NoopBackend, _ str: String) { b.onData?(Data(str.utf8)) }

    // The session must outlive `feed` (pty.onData captures it weakly) — see DSRTests.
    private func row0(_ s: DamsonSession) -> String {
        String(s.grid.debugDump().split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
    }

    /// `ESC ( 0` selects DEC Special Graphics into G0 (active by default): `lqk` → `┌─┐`.
    func testDECLineDrawingViaG0() {
        let (s, b) = session()
        withExtendedLifetime(s) {
            feed(b, "\u{1B}(0lqk\u{1B}(B")   // graphics on → ┌─┐ → back to ASCII (also flushes)
            XCTAssertTrue(row0(s).hasPrefix("┌─┐"), "got: \(row0(s).debugDescription)")
        }
    }

    /// `ESC ) 0` designates G1 as graphics; SO (0x0E) invokes G1 → `x` = `│`, SI (0x0F)
    /// restores G0 (ASCII) → `x` = literal `x`.
    func testDECLineDrawingG1ShiftOutShiftIn() {
        let (s, b) = session()
        withExtendedLifetime(s) {
            feed(b, "\u{1B})0\u{0E}x\u{0F}x\u{1B}[m")   // trailing ESC flushes the last 'x'
            XCTAssertTrue(row0(s).hasPrefix("│x"), "got: \(row0(s).debugDescription)")
        }
    }

    /// Without any charset designation, `qxl` render literally (the graphics map only
    /// applies when the active charset is `'0'`).
    func testASCIIUnaffectedByDefault() {
        let (s, b) = session()
        withExtendedLifetime(s) {
            feed(b, "qxl\u{1B}[m")
            XCTAssertTrue(row0(s).hasPrefix("qxl"), "got: \(row0(s).debugDescription)")
        }
    }

    /// RIS resets the scroll region to full-screen and the charset back to ASCII.
    func testRISResetsCharsetAndScrollRegion() {
        let (s, b) = session()
        withExtendedLifetime(s) {
            feed(b, "\u{1B}[2;4r")   // DECSTBM scroll region rows 2..4
            feed(b, "\u{1B}(0")      // G0 = graphics
            feed(b, "\u{1B}c")       // RIS
            XCTAssertEqual(s.grid.scrollTop, 0, "RIS must reset the scroll region to the full screen")
            XCTAssertEqual(s.grid.scrollBottom, s.grid.rows - 1)
            feed(b, "q\u{1B}[m")     // charset must be ASCII again → literal 'q'
            XCTAssertTrue(row0(s).hasPrefix("q"), "charset must reset to ASCII after RIS; got \(row0(s).debugDescription)")
        }
    }
}
