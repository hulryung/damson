import XCTest
@testable import DamsonTerminal

final class CommandLifecycleTests: XCTestCase {
    func testExplicitCompletionCapturesDurationStatusAndLines() {
        var tracker = CommandLifecycle()
        tracker.receive("C", line: 12, now: 100)
        let result = tracker.receive("D", status: "7", line: 18, now: 115)
        XCTAssertEqual(result?.exitCode, 7)
        XCTAssertEqual(result?.duration, 15)
        XCTAssertEqual(result?.outputStartLine, 12)
        XCTAssertEqual(result?.outputEndLine, 18)
        XCTAssertFalse(tracker.isRunning)
        XCTAssertEqual(tracker.lastCompletion, result)
        XCTAssertNil(tracker.receive("D", status: "0", line: 18, now: 116))
    }
    func testPromptWithoutEndDoesNotInventSuccess() {
        var tracker = CommandLifecycle()
        tracker.receive("C", line: 1, now: 10)
        XCTAssertNil(tracker.receive("A", line: 5, now: 90))
        XCTAssertNil(tracker.lastCompletion)
        XCTAssertFalse(tracker.isRunning)
        XCTAssertNil(tracker.receive("D", status: "0", line: 5, now: 91))
    }
    func testDuplicateStartAndInvalidExitStatus() {
        var tracker = CommandLifecycle()
        tracker.receive("C", line: 1, now: 10)
        tracker.receive("C", line: 2, now: 20)
        let result = tracker.receive("D", status: "-1", line: 3, now: 30)
        XCTAssertNil(result?.exitCode)
        XCTAssertEqual(result?.duration, 20)
        XCTAssertEqual(result?.outputStartLine, 1)
    }

    private final class Backend: SessionIOBackend {
        var onData: ((Data) -> Void)?
        var onExit: ((Int32) -> Void)?
        func spawn(argv: [String], env: [String: String], cwd: String?, cols: Int, rows: Int) throws {}
        func write(_ data: Data) {}
        func resize(cols: Int, rows: Int) {}
        func terminate() {}
        var childWorkingDirectory: String? { nil }
        var isRunningForegroundJob: Bool { false }
        var foregroundPID: pid_t?
    }
    func testOSCParserIntegrationAndProviderReports() {
        let backend = Backend()
        let session = DamsonSession(config: DamsonConfig(), backend: backend)
        func feed(_ text: String) { backend.onData?(Data(text.utf8)) }
        feed("\u{1b}]133;C\u{7}output\r\n\u{1b}]133;D;3\u{7}")
        XCTAssertEqual(session.commandLifecycle.lastCompletion?.exitCode, 3)
        feed("\u{1b}]777;damson;agent;waiting\u{7}")
        XCTAssertEqual(session.reportedAgentState, .waiting)
        XCTAssertNotNil(session.agentStateReportedAt)
        feed("\u{1b}]777;damson;agent;unsupported\u{7}")
        XCTAssertEqual(session.reportedAgentState, .waiting)
        feed("\u{1b}]777;damson;agent;completed\u{7}")
        XCTAssertEqual(session.reportedAgentState, .completed)
        feed("\u{1b}]777;damson;agent;clear\u{7}")
        XCTAssertNil(session.reportedAgentState)
        XCTAssertNil(session.agentStateReportedAt)
        // ST-terminated, as documented; extra fields are not the protocol.
        feed("\u{1b}]777;damson;agent;failed\u{1b}\\")
        XCTAssertEqual(session.reportedAgentState, .failed)
        feed("\u{1b}]777;damson;agent;running;extra\u{7}")
        XCTAssertEqual(session.reportedAgentState, .failed)
    }

    /// A reporter that died without `clear` no longer speaks for the pane: the pane reads
    /// as unreported, not as working forever.
    func testReportExpiresWhenTheReportingProcessGroupIsGone() throws {
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()

        let backend = Backend()
        let session = DamsonSession(config: DamsonConfig(), backend: backend)
        func feed(_ text: String) { backend.onData?(Data(text.utf8)) }

        backend.foregroundPID = getpgrp()          // a group that certainly exists
        feed("\u{1b}]777;damson;agent;running\u{7}")
        XCTAssertEqual(session.agentReport?.ownerProcessGroup, getpgrp())
        XCTAssertEqual(session.reportedAgentState, .running)

        backend.foregroundPID = finished.processIdentifier   // reaped: no such group
        feed("\u{1b}]777;damson;agent;waiting\u{7}")
        XCTAssertNil(session.reportedAgentState)
        XCTAssertNil(session.agentStateReportedAt)
        // Expiry is final; the group coming back (pid reuse) cannot revive it.
        backend.foregroundPID = getpgrp()
        XCTAssertNil(session.agentReport)
    }

    func testReportOwnershipRule() {
        let date = Date()
        let owned = AgentReport(state: .waiting, receivedAt: date, ownerProcessGroup: 42)
        XCTAssertTrue(owned.isCurrent { $0 == 42 })
        XCTAssertFalse(owned.isCurrent { _ in false })
        // No tty to ask (tmux -CC, tests): lasts until `clear`, never guessed stale.
        let unowned = AgentReport(state: .waiting, receivedAt: date, ownerProcessGroup: nil)
        XCTAssertTrue(unowned.isCurrent { _ in false })
        XCTAssertFalse(AgentReport.processGroupExists(0))
        XCTAssertTrue(AgentReport.processGroupExists(getpgrp()))
    }
}
