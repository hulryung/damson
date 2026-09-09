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
        var targets: [PaneTarget] = []
        var response: Result<ControlResponse, CrewError> = .success(.ok())

        func send(_ kind: ControlCommandKind, target: PaneTarget) -> Result<ControlResponse, CrewError> {
            sent.append(kind)
            targets.append(target)
            return response
        }
    }

    func testRevealAddressesThePaneInOneRequest() {
        let fake = FakeDamson()
        XCTAssertNil(PaneFocuser(client: fake).reveal(paneID: "A"))
        XCTAssertEqual(fake.sent, [.revealPane])
        XCTAssertEqual(fake.targets, [.id("A")])
    }

    func testRevealReportsAClosedPaneWithoutFallingBack() {
        let fake = FakeDamson()
        fake.response = .success(.err("no such pane: A"))
        XCTAssertEqual(PaneFocuser(client: fake).reveal(paneID: "A"), "no such pane: A")
        XCTAssertEqual(fake.sent, [.revealPane])
    }

    func testRevealReportsTransportFailureWithoutRetrying() {
        let fake = FakeDamson()
        fake.response = .failure(CrewError("connection lost"))
        XCTAssertEqual(PaneFocuser(client: fake).reveal(paneID: "A"), "connection lost")
        XCTAssertEqual(fake.sent, [.revealPane])
    }

}

/// Agent questions are free-form model output and routinely contain quotes and backslashes.
/// Unescaped, they turn the AppleScript into a syntax error and the alert silently never
/// appears — the failure mode that looks exactly like "nothing was waiting".
final class NotifierQuotingTests: XCTestCase {
    func testQuotesAndBackslashesSurviveIntoTheScript() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("damson-notification-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("notification.scpt")
        let alert = Escalation(kind: .blocked, subject: #"task "quoted""#,
                               question: "Overwrite \"foo\\bar.swift\"?\nChoose an option.", paneID: "A")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        // Compile the real production script without posting a notification during tests.
        proc.arguments = ["-o", output.path, "-e", SystemNotifier().script(for: alert)]
        let errors = Pipe()
        proc.standardError = errors
        try proc.run()
        let details = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0, details)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }
}
