import XCTest
@testable import DamsonTerminal

/// Device Status Report (DSR). Many CLIs — gh, shell prompt frameworks, vim —
/// send `CSI 6 n` (cursor position request) and BLOCK on a read until the
/// terminal answers. A terminal that ignores it makes those tools stall ~5s on
/// a timeout (the "gh is slow inside damson" symptom). These tests assert the
/// session writes the report back to the PTY.
final class DSRTests: XCTestCase {
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

    private func session(cols: Int = 80, rows: Int = 24) -> (DamsonSession, CapturingBackend) {
        let backend = CapturingBackend()
        let s = DamsonSession(config: DamsonConfig(), backend: backend)
        s.resize(cols: cols, rows: rows)
        return (s, backend)
    }

    private func feed(_ b: CapturingBackend, _ s: String) { b.onData?(Data(s.utf8)) }

    /// `CSI 6 n` at the home position → `ESC [ 1 ; 1 R`.
    func testCursorPositionReportAtHome() {
        let (_, b) = session()
        feed(b, "\u{1B}[6n")
        XCTAssertEqual(String(decoding: b.written, as: UTF8.self), "\u{1B}[1;1R")
    }

    /// CPR is 1-based and reflects the current cursor position.
    func testCursorPositionReportAfterMove() {
        let (_, b) = session()
        // Move the cursor to row 5, col 10 (CUP is 1-based), then request CPR.
        feed(b, "\u{1B}[5;10H")
        b.written.removeAll()
        feed(b, "\u{1B}[6n")
        XCTAssertEqual(String(decoding: b.written, as: UTF8.self), "\u{1B}[5;10R")
    }

    /// `CSI 5 n` (operating-status request) → `ESC [ 0 n` (terminal OK).
    func testOperatingStatusReport() {
        let (_, b) = session()
        feed(b, "\u{1B}[5n")
        XCTAssertEqual(String(decoding: b.written, as: UTF8.self), "\u{1B}[0n")
    }

    /// The private-marker form (`CSI ? 6 n`, DECXCPR) is NOT the ANSI DSR and
    /// must not produce the plain CPR (we only answer the ANSI form).
    func testPrivateDSRIgnored() {
        let (_, b) = session()
        feed(b, "\u{1B}[?6n")
        XCTAssertTrue(b.written.isEmpty, "private CSI ?6n must not yield a plain CPR")
    }
}
