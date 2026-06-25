import XCTest
@testable import DamsonOrchestrator

final class ReadinessDetectorTests: XCTestCase {

    // MARK: - Snapshot factory

    /// Build a snapshot with sensible defaults; override only what a test cares about.
    private func snap(
        lines: [String] = [],
        cursorRow: Int = 0,
        cursorCol: Int = 0,
        isAltScreen: Bool = true,
        sinceData: TimeInterval = 2.0,
        sinceSync: TimeInterval = 5.0,
        sinceSpawn: TimeInterval = 10.0,
        exited: Bool = false,
        exitCode: Int32? = nil,
        fgJob: Bool = true,
        newPromptMark: Bool = false
    ) -> ReadinessSnapshot {
        ReadinessSnapshot(
            lines: lines, cursorRow: cursorRow, cursorCol: cursorCol,
            cols: 80, rows: 24, isAltScreen: isAltScreen,
            timeSinceLastData: sinceData, timeSinceLastSyncFrame: sinceSync,
            timeSinceSpawn: sinceSpawn, processExited: exited, exitCode: exitCode,
            isRunningForegroundJob: fgJob, newPromptMarkSinceTaskStart: newPromptMark
        )
    }

    private let claudeIdleLines = [
        "╭──────────────────────────────────────────╮",
        "│ > Try \"refactor the parser\"               │",
        "╰──────────────────────────────────────────╯",
        "  ? for shortcuts",
    ]
    private let claudeWorkingLines = [
        "✻ Thinking… (12s · esc to interrupt)",
    ]
    private let claudeApprovalLines = [
        "Do you want to proceed?",
        "❯ 1. Yes",
        "  2. Yes, and don't ask again",
        "  3. No, and tell Claude what to do differently",
    ]

    // MARK: - Claude Code TUI

    func testStartingToIdle() {
        let d = ReadinessDetector(engine: ClaudeCodeEngine())
        XCTAssertEqual(d.state, .starting)
        // Within the spawn floor: must NOT go idle even if the screen looks ready.
        _ = d.update(snap(lines: claudeIdleLines, sinceSpawn: 0.5))
        XCTAssertEqual(d.state, .starting)
        // After the floor, two confirmations debounce into idle.
        _ = d.update(snap(lines: claudeIdleLines, sinceSpawn: 3.0))
        _ = d.update(snap(lines: claudeIdleLines, sinceSpawn: 3.2))
        XCTAssertEqual(d.state, .idle)
    }

    func testIdleToWorkingToIdleCycle() {
        let d = ReadinessDetector(engine: ClaudeCodeEngine())
        _ = d.update(snap(lines: claudeIdleLines))
        _ = d.update(snap(lines: claudeIdleLines))
        XCTAssertEqual(d.state, .idle)

        // Deliver a task → optimistic working.
        d.noteTaskDelivered()
        XCTAssertEqual(d.state, .working)

        // Spinner confirms working.
        _ = d.update(snap(lines: claudeWorkingLines, sinceData: 0.2, sinceSync: 0.5))
        XCTAssertEqual(d.state, .working)

        // Turn ends: input box returns, quiescent → idle (debounced).
        _ = d.update(snap(lines: claudeIdleLines))
        XCTAssertEqual(d.state, .working, "first idle observation should be debounced")
        _ = d.update(snap(lines: claudeIdleLines))
        XCTAssertEqual(d.state, .idle)
    }

    /// The safety-critical property: an approval prompt must NEVER read as idle.
    func testApprovalNeverIdle() {
        let d = ReadinessDetector(engine: ClaudeCodeEngine())
        _ = d.update(snap(lines: claudeIdleLines))
        _ = d.update(snap(lines: claudeIdleLines))
        XCTAssertEqual(d.state, .idle)

        d.noteTaskDelivered()
        _ = d.update(snap(lines: claudeWorkingLines, sinceData: 0.2, sinceSync: 0.5))
        // Now an approval prompt appears — even quiescent, it is NOT idle.
        for _ in 0..<5 {
            _ = d.update(snap(lines: claudeApprovalLines, sinceData: 3.0, sinceSync: 5.0))
        }
        XCTAssertEqual(d.state, .awaitingApproval)
        XCTAssertFalse(d.state.acceptsTask)
    }

    /// Spinner repaints while working must not be mistaken for idle quiescence.
    func testSpinnerNotIdle() {
        let d = ReadinessDetector(engine: ClaudeCodeEngine())
        d.noteTaskDelivered()
        // A recent sync frame with no input box ⇒ working, even if bytes paused briefly.
        _ = d.update(snap(lines: claudeWorkingLines, sinceData: 1.0, sinceSync: 0.9))
        XCTAssertEqual(d.state, .working)
    }

    /// Right after delivery, a stale idle-looking frame must not flip to idle before
    /// any work is observed (the just-typed-prompt race).
    func testPostDeliveryRaceGuard() {
        let d = ReadinessDetector(engine: ClaudeCodeEngine())
        d.noteTaskDelivered()
        _ = d.update(snap(lines: claudeIdleLines, sinceData: 0.7))
        _ = d.update(snap(lines: claudeIdleLines, sinceData: 0.7))
        XCTAssertEqual(d.state, .working, "must hold working until work is seen")
        // But a long quiet period means the turn was a no-op → allow idle.
        _ = d.update(snap(lines: claudeIdleLines, sinceData: 6.0))
        _ = d.update(snap(lines: claudeIdleLines, sinceData: 6.0))
        XCTAssertEqual(d.state, .idle)
    }

    // MARK: - Terminal states

    func testProcessExitSuccess() {
        let d = ReadinessDetector(engine: ClaudeCodeEngine())
        _ = d.update(snap(exited: true, exitCode: 0))
        XCTAssertEqual(d.state, .finished(0))
        XCTAssertTrue(d.state.isTerminal)
    }

    func testProcessExitFailure() {
        let d = ReadinessDetector(engine: ClaudeCodeEngine())
        _ = d.update(snap(exited: true, exitCode: 1))
        if case .errored = d.state {} else { XCTFail("expected errored, got \(d.state)") }
    }

    // MARK: - Generic shell engine (process-signal path)

    func testGenericShellForegroundJobIsWorking() {
        let d = ReadinessDetector(engine: GenericShellEngine())
        d.noteTaskDelivered()
        _ = d.update(snap(fgJob: true, sinceData: 0.1))
        XCTAssertEqual(d.state, .working)
    }

    func testGenericShellReturnsIdleAtPrompt() {
        let d = ReadinessDetector(engine: GenericShellEngine())
        d.noteTaskDelivered()
        _ = d.update(snap(fgJob: true, sinceData: 0.1))          // running
        XCTAssertEqual(d.state, .working)
        _ = d.update(snap(fgJob: false, newPromptMark: true))    // back at prompt
        _ = d.update(snap(fgJob: false, newPromptMark: true))
        XCTAssertEqual(d.state, .idle)
    }
}
