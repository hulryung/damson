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
    }

    private func completion(_ seconds: TimeInterval, _ code: Int? = 0) -> CommandCompletion {
        CommandCompletion(exitCode: code, duration: seconds, outputStartLine: 0, outputEndLine: 0)
    }

    func testNotificationPolicy() {
        let long = completion(12)
        XCTAssertTrue(CommandNotificationPolicy.shouldNotify(long, enabled: true, threshold: 10, appActive: false, paneFocused: true))
        XCTAssertTrue(CommandNotificationPolicy.shouldNotify(long, enabled: true, threshold: 10, appActive: true, paneFocused: false))
        XCTAssertFalse(CommandNotificationPolicy.shouldNotify(long, enabled: true, threshold: 10, appActive: true, paneFocused: true))
        XCTAssertFalse(CommandNotificationPolicy.shouldNotify(long, enabled: false, threshold: 10, appActive: false, paneFocused: false))
        XCTAssertFalse(CommandNotificationPolicy.shouldNotify(completion(9.9), enabled: true, threshold: 10, appActive: false, paneFocused: false))
        XCTAssertTrue(CommandNotificationPolicy.shouldNotify(completion(10), enabled: true, threshold: 10, appActive: false, paneFocused: false))
    }

    func testNotificationThresholdSetting() throws {
        let name = "damson.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(CommandNotificationPolicy.threshold(defaults), 10)
        defaults.set(45, forKey: CommandNotificationPolicy.thresholdKey)
        XCTAssertEqual(CommandNotificationPolicy.threshold(defaults), 45)
        defaults.set(0, forKey: CommandNotificationPolicy.thresholdKey)
        XCTAssertEqual(CommandNotificationPolicy.threshold(defaults), 1)
        defaults.set("junk", forKey: CommandNotificationPolicy.thresholdKey)
        XCTAssertEqual(CommandNotificationPolicy.threshold(defaults), 1)
    }

    func testNotificationTitle() {
        XCTAssertEqual(CommandNotificationPolicy.title(for: completion(12.7, 0)), "Succeeded · 12s")
        XCTAssertEqual(CommandNotificationPolicy.title(for: completion(125, 2)), "Failed (exit 2) · 2m 05s")
        XCTAssertEqual(CommandNotificationPolicy.title(for: completion(3725, nil)), "Finished (status unknown) · 1h 02m")
    }

    func testMalformedAndInterleavedMarkers() {
        var tracker = CommandLifecycle()
        XCTAssertNil(tracker.receive("D", status: "0", line: 0, now: 1))   // end without start
        XCTAssertNil(tracker.receive("Z", line: 0, now: 2))                // unknown marker
        XCTAssertNil(tracker.receive("", line: 0, now: 2))
        tracker.receive("C", line: 1, now: 10)
        XCTAssertNil(tracker.receive("B", line: 1, now: 11))               // B does not end it
        XCTAssertTrue(tracker.isRunning)
        XCTAssertNil(tracker.receive("D", status: "abc", line: 2, now: 20)?.exitCode)
        tracker.receive("C", line: 3, now: 30)
        let skewed = tracker.receive("D", status: "256", line: 4, now: 25)
        XCTAssertEqual(skewed?.duration, 0)                                 // never negative
        XCTAssertNil(skewed?.exitCode)                                      // out of range
    }

    func testSessionMarkersWithExtraParametersAndNoStatus() {
        let backend = Backend()
        let session = DamsonSession(config: DamsonConfig(), backend: backend)
        var posted: [CommandCompletion] = []
        let token = NotificationCenter.default.addObserver(forName: DamsonSession.commandCompleted, object: session, queue: nil) {
            if let c = $0.userInfo?["completion"] as? CommandCompletion { posted.append(c) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        func feed(_ text: String) { backend.onData?(Data(text.utf8)) }
        feed("\u{1b}]133;A\u{1b}\\$ \u{1b}]133;C\u{1b}\\out\r\n\u{1b}]133;D;1;aid=7\u{1b}\\")
        feed("\u{1b}]133;D;0\u{7}")                 // repeated end: no second event
        feed("\u{1b}]133;C\u{7}x\u{1b}]133;D\u{7}")  // end without status
        XCTAssertEqual(posted.map(\.exitCode), [1, nil])
    }
}
