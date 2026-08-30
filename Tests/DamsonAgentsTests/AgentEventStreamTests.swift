import XCTest
@testable import DamsonAgents

/// The stream exists so a coordinator can wait instead of poll, which means its output is
/// load-bearing: a missed transition leaves a driver waiting forever, and a spurious one
/// makes it act on a change that never happened.
final class AgentEventStreamTests: XCTestCase {
    private func obs(_ id: String, _ status: String, pid: Int32 = 100,
                     waitingFor: String? = nil) -> AgentObservation {
        AgentObservation(paneID: id, pid: pid, status: status, waitingFor: waitingFor, cwd: "/p")
    }

    func testFirstSightIsAppeared() {
        var s = AgentEventStream()
        let e = s.ingest([obs("A", "busy")])
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].kind, .appeared)
        XCTAssertEqual(e[0].status, "busy")
        XCTAssertNil(e[0].previousStatus)
    }

    /// Edge-triggered: an unchanged sweep must be silent, or an idle machine would produce
    /// traffic forever and a subscriber could not tell activity from elapsed time.
    func testUnchangedSweepsAreSilent() {
        var s = AgentEventStream()
        _ = s.ingest([obs("A", "busy")])
        XCTAssertTrue(s.ingest([obs("A", "busy")]).isEmpty)
        XCTAssertTrue(s.ingest([obs("A", "busy")]).isEmpty)
    }

    func testStatusChangeCarriesBothSides() {
        var s = AgentEventStream()
        _ = s.ingest([obs("A", "busy")])
        let e = s.ingest([obs("A", "waiting", waitingFor: "permission to edit main.swift")])
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].kind, .changed)
        XCTAssertEqual(e[0].previousStatus, "busy")
        XCTAssertEqual(e[0].status, "waiting")
        XCTAssertEqual(e[0].waitingFor, "permission to edit main.swift")
    }

    /// An agent that moves from one question to another is still `waiting`, but it is a
    /// change the coordinator has to see — the thing it is blocked on is different now.
    func testNewQuestionUnderTheSameStatusIsAChange() {
        var s = AgentEventStream()
        _ = s.ingest([obs("A", "waiting", waitingFor: "run tests?")])
        let e = s.ingest([obs("A", "waiting", waitingFor: "push to main?")])
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].kind, .changed)
        XCTAssertEqual(e[0].waitingFor, "push to main?")
    }

    func testDisappearanceIsReported() {
        var s = AgentEventStream()
        _ = s.ingest([obs("A", "idle"), obs("B", "busy", pid: 200)])
        let e = s.ingest([obs("B", "busy", pid: 200)])
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].kind, .vanished)
        XCTAssertEqual(e[0].paneID, "A")
        XCTAssertEqual(e[0].previousStatus, "idle")
        XCTAssertNil(e[0].status)
    }

    /// The trap: a pane whose agent exited and was replaced by a NEW one. Reporting that as
    /// a status change would let a coordinator carry conclusions about the old conversation
    /// into an unrelated one, so it is reported as a death and a birth.
    func testSamePaneNewProcessIsVanishedThenAppeared() {
        var s = AgentEventStream()
        _ = s.ingest([obs("A", "idle", pid: 100)])
        let e = s.ingest([obs("A", "busy", pid: 999)])
        XCTAssertEqual(e.map(\.kind), [.vanished, .appeared])
        XCTAssertEqual(e[0].pid, 100)
        XCTAssertEqual(e[1].pid, 999)
        XCTAssertNil(e[1].previousStatus, "a new process has no previous status")
    }

    func testMultiplePanesAreReportedInAStableOrder() {
        var s = AgentEventStream()
        let e = s.ingest([obs("C", "busy"), obs("A", "idle"), obs("B", "waiting")])
        XCTAssertEqual(e.map(\.paneID), ["A", "B", "C"])
    }

    /// A subscriber that connects mid-run must start from the present, not from the next
    /// thing that happens to change.
    func testSnapshotDescribesTheCurrentWorld() {
        var s = AgentEventStream()
        XCTAssertTrue(s.snapshot().isEmpty)
        _ = s.ingest([obs("A", "idle"), obs("B", "waiting", pid: 200, waitingFor: "q")])
        let snap = s.snapshot()
        XCTAssertEqual(snap.map(\.paneID), ["A", "B"])
        XCTAssertTrue(snap.allSatisfy { $0.kind == .appeared })
        XCTAssertEqual(snap[1].waitingFor, "q")
    }

    func testEmptySweepClearsEverything() {
        var s = AgentEventStream()
        _ = s.ingest([obs("A", "busy")])
        XCTAssertEqual(s.ingest([]).map(\.kind), [.vanished])
        XCTAssertTrue(s.snapshot().isEmpty)
        // And a later reappearance is a fresh `appeared`, not a `changed`.
        XCTAssertEqual(s.ingest([obs("A", "busy")]).map(\.kind), [.appeared])
    }
}
