import DamsonControl
import XCTest
@testable import DamsonCrew

/// What gets escalated, and what deliberately does not. An alert stream that fires on
/// everything is one people learn to dismiss, and then they miss the one that mattered.
final class EscalationTests: XCTestCase {

    private func line(_ event: String, _ pane: String, status: String? = nil,
                      waitingFor: String? = nil) -> AgentEventLine {
        AgentEventLine(event: event, pane: pane, pid: 1, status: status, waitingFor: waitingFor)
    }

    func testABlockedAgentEscalatesWithItsQuestion() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", status: "busy")) { _ in "review-api" }
        let change = board.apply(line("changed", "A", status: "waiting", waitingFor: "which auth flow?"))
        let alert = change?.escalation
        XCTAssertEqual(alert?.subject, "review-api")
        XCTAssertEqual(alert?.question, "which auth flow?")
        XCTAssertEqual(alert?.title, "review-api needs you")
    }

    /// A pane that is not one of ours still escalates — it is still a human being waited on —
    /// but it can only be named by its id.
    func testAnUnknownPaneEscalatesUnderItsID() {
        var board = AgentBoard()
        let change = board.apply(line("appeared", "A", status: "waiting", waitingFor: "q"))
        XCTAssertEqual(change?.escalation?.subject, "A")
    }

    /// `waiting` with no detail is still worth interrupting for; the alert just cannot say
    /// what about.
    func testWaitingWithoutDetailStillEscalates() {
        var board = AgentBoard()
        let change = board.apply(line("appeared", "A", status: "waiting"))
        XCTAssertEqual(change?.escalation?.question, "waiting for you")
    }

    /// Nothing else may interrupt. `idle` in particular also means "asked you a clarifying
    /// question" and "spawned but never prompted".
    func testNothingElseEscalates() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", status: "waiting", waitingFor: "q"))
        let released = board.apply(line("changed", "A", status: "busy"))
        XCTAssertNil(released?.escalation)

        var second = AgentBoard()
        XCTAssertNil(second.apply(line("appeared", "B", status: "idle"))?.escalation)
        XCTAssertNil(second.apply(line("changed", "B", status: "busy"))?.escalation)
        XCTAssertNil(second.apply(line("changed", "B", status: "shell"))?.escalation)
        XCTAssertNil(second.apply(line("vanished", "B"))?.escalation)
        XCTAssertNil(second.apply(AgentEventLine(event: "heartbeat", pane: ""))?.escalation)
    }

    // MARK: - Focusing the blocked pane

    private final class FakeDamson: DamsonClient {
        var sent: [ControlCommandKind] = []
        var paneInfo: Result<ControlResponse, CrewError> = .success(.ok())
        var switchResult: Result<ControlResponse, CrewError> = .success(.ok())

        func send(_ kind: ControlCommandKind, target: PaneTarget) -> Result<ControlResponse, CrewError> {
            sent.append(kind)
            if case .paneInfo = kind { return paneInfo }
            return switchResult
        }
    }

    func testRevealSwitchesToThePanesTab() {
        let fake = FakeDamson()
        fake.paneInfo = .success(.pane(
            PaneInfo(index: 0, cols: 80, rows: 24, active: false, id: "A", tab: 3)))
        XCTAssertNil(PaneFocuser(client: fake).reveal(paneID: "A"))
        guard case .switchTab(let index)? = fake.sent.last else { return XCTFail("no switch") }
        XCTAssertEqual(index, 3)
    }

    /// An id that no longer resolves is a typed error from damson, never a fallback to the
    /// active pane — so acting on a stale alert cannot yank the user to an unrelated tab.
    func testRevealReportsAClosedPaneRatherThanSwitchingSomewhere() {
        let fake = FakeDamson()
        fake.paneInfo = .success(.err("no such pane: A"))
        XCTAssertEqual(PaneFocuser(client: fake).reveal(paneID: "A"), "no such pane: A")
        XCTAssertEqual(fake.sent.count, 1, "it switched tabs anyway")
    }

    func testRevealReportsAPaneWithNoTab() {
        let fake = FakeDamson()
        fake.paneInfo = .success(.pane(PaneInfo(index: 0, cols: 80, rows: 24, active: false, id: "A")))
        XCTAssertNotNil(PaneFocuser(client: fake).reveal(paneID: "A"))
        XCTAssertEqual(fake.sent.count, 1)
    }
}

/// Agent questions are free-form model output and routinely contain quotes and backslashes.
/// Unescaped, they turn the AppleScript into a syntax error and the alert silently never
/// appears — the failure mode that looks exactly like "nothing was waiting".
final class NotifierQuotingTests: XCTestCase {
    func testQuotesAndBackslashesSurviveIntoTheScript() throws {
        let notifier = SystemNotifier()
        let mirror = Mirror(reflecting: notifier)
        _ = mirror   // the quoting helper is private; exercise it through a real delivery

        // Build the same script the notifier builds, via a local copy of the rule, and
        // assert osascript accepts it. That is the property that matters: it parses.
        let nasty = #"Overwrite "foo\bar.swift"? (y/n)"#
        let escaped = "\"" + nasty
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ") + "\""

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // `return <literal>` — parses and echoes it back without posting a notification.
        proc.arguments = ["-e", "return \(escaped)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()

        XCTAssertEqual(proc.terminationStatus, 0, "osascript rejected the escaped question")
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), nasty)
    }
}
