import DamsonControl
import XCTest
@testable import DamsonCrew

/// The `watch-agents` contract puts four things on the consumer, and each is a way to be
/// quietly wrong rather than visibly broken. These pin all four.
final class AgentBoardTests: XCTestCase {

    private func line(_ event: String, _ pane: String, pid: Int32? = 1,
                      status: String? = nil, waitingFor: String? = nil) -> AgentEventLine {
        AgentEventLine(event: event, pane: pane, pid: pid, status: status, waitingFor: waitingFor)
    }

    // MARK: - Heartbeat

    /// A heartbeat exists so a dead peer is found by the write failing. Treating it as a
    /// change would make an idle machine look busy, and would let a caller measure elapsed
    /// time instead of activity.
    func testHeartbeatIsNotAChange() {
        var board = AgentBoard()
        XCTAssertNil(board.apply(AgentEventLine(event: "heartbeat", pane: "")))
        XCTAssertTrue(board.agents.isEmpty)
    }

    /// A line from a newer damson must be ignored, not guessed at — the same direction
    /// damson's own badge vocabulary degrades in.
    func testAnUnknownEventIsIgnored() {
        var board = AgentBoard()
        XCTAssertNil(board.apply(line("teleported", "A", status: "busy")))
        XCTAssertTrue(board.agents.isEmpty)
    }

    // MARK: - Attention

    func testWaitingRaisesAttention() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", status: "busy"))
        guard case .needsAttention(let s)? =
                board.apply(line("changed", "A", status: "waiting", waitingFor: "which auth flow?"))
        else { return XCTFail("a blocked agent did not raise attention") }
        XCTAssertEqual(s.waitingFor, "which auth flow?")
    }

    /// An agent moving from one question to the next is `waiting` both times. The thing
    /// blocking it changed, so it is news — deduplicating on status alone would swallow the
    /// second question and leave the user waiting on an agent that is waiting on them.
    func testASecondDifferentQuestionRaisesAttentionAgain() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", status: "busy"))
        board.apply(line("changed", "A", status: "waiting", waitingFor: "which auth flow?"))
        guard case .needsAttention? =
                board.apply(line("changed", "A", status: "waiting", waitingFor: "overwrite foo.swift?"))
        else { return XCTFail("a new question did not raise attention") }
    }

    func testTheSameQuestionDoesNotRaiseAttentionTwice() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", status: "busy"))
        board.apply(line("changed", "A", status: "waiting", waitingFor: "which auth flow?"))
        XCTAssertNil(board.apply(line("changed", "A", status: "waiting", waitingFor: "which auth flow?")))
    }

    func testLeavingWaitingToWorkAgainIsReported() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", status: "waiting", waitingFor: "q"))
        guard case .released? = board.apply(line("changed", "A", status: "busy")) else {
            return XCTFail("an unblocked agent was not reported")
        }
    }

    /// An agent that was blocked, got its answer, and then stopped. This is the task the
    /// user was called away for, so it is the one they most want told about — reporting only
    /// `released` here let it finish in silence.
    func testAnAgentThatStopsAfterBeingUnblockedIsReportedFinished() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", status: "busy"))
        board.apply(line("changed", "A", status: "waiting", waitingFor: "may I?"))
        guard case .finishedTurn? = board.apply(line("changed", "A", status: "idle")) else {
            return XCTFail("finishing after a question was not reported")
        }
    }

    /// `busy` → `idle` must not raise ATTENTION. It is reported — as a finished turn, which
    /// is what a human wants to know — but it must never be treated as an agent blocked on
    /// them, because `idle` also covers "asked a clarifying question" and "never prompted".
    /// Escalating it as blocked would fire constantly and train the user to dismiss the one
    /// that mattered.
    func testIdleIsReportedAsFinishedNotAsAttention() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", status: "busy"))
        let change = board.apply(line("changed", "A", status: "idle"))
        guard case .finishedTurn? = change else { return XCTFail("expected a finished turn") }
        XCTAssertEqual(change?.escalation?.kind, .finishedTurn)
        XCTAssertNotEqual(change?.escalation?.kind, .blocked)
        XCTAssertEqual(change?.escalation?.deservesFocus, false,
                       "finishing must never steal the user's focus")
    }

    // MARK: - Pane reuse

    /// A new process in an old pane arrives as vanished + appeared. Carrying state across
    /// that boundary would attribute one conversation's conclusions to another.
    func testANewProcessInAnOldPaneStartsClean() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", pid: 100, status: "waiting", waitingFor: "q"))
        board.apply(line("vanished", "A", pid: 100))
        XCTAssertTrue(board.agents.isEmpty)

        guard case .appeared(let s)? = board.apply(line("appeared", "A", pid: 200, status: "busy")) else {
            return XCTFail("the new process was not reported as new")
        }
        XCTAssertEqual(s.pid, 200)
        XCTAssertNil(s.waitingFor, "the previous conversation's question survived into a new one")
    }

    /// Belt and braces for the case damson says should never happen: a `changed` line whose
    /// pid differs. Continuing the old state there would be the same misattribution.
    func testAChangedLineWithADifferentPidDoesNotContinueTheOldState() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", pid: 100, status: "waiting", waitingFor: "q"))
        board.apply(line("changed", "A", pid: 200, status: "busy"))
        XCTAssertEqual(board.agents["A"]?.pid, 200)
        XCTAssertNil(board.agents["A"]?.waitingFor)
    }

    func testVanishingAnUnknownPaneIsHarmless() {
        var board = AgentBoard()
        XCTAssertNil(board.apply(line("vanished", "Z")))
    }

    // MARK: - Snapshot and reconnect

    /// The opening burst is the present, not news — a coordinator connecting mid-run starts
    /// from what is already running.
    func testSnapshotIsMarkedSeparatelyFromLiveChanges() {
        var board = AgentBoard()
        XCTAssertFalse(board.hasSnapshot)
        board.apply(line("appeared", "A", status: "busy"))
        board.snapshotComplete()
        XCTAssertTrue(board.hasSnapshot)
        XCTAssertEqual(board.agents.count, 1)
    }

    /// A reconnect opens a new subscription with its own snapshot. Keeping the old rows
    /// would leave agents on the board that have since gone.
    func testResetClearsEverythingForAReconnect() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", status: "busy"))
        board.snapshotComplete()
        board.reset()
        XCTAssertTrue(board.agents.isEmpty)
        XCTAssertFalse(board.hasSnapshot)
    }

    // MARK: - Task join

    func testAPaneIsJoinedToItsTask() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", status: "busy")) { $0 == "A" ? "review-api" : nil }
        XCTAssertEqual(board.agents["A"]?.task, "review-api")
    }

    func testWaitingListIsStableForDisplay() {
        var board = AgentBoard()
        for pane in ["C", "A", "B"] {
            board.apply(line("appeared", pane, status: "waiting", waitingFor: "q"))
        }
        XCTAssertEqual(board.waiting.map(\.paneID), ["A", "B", "C"])
    }
}

/// The coordinator's view of damson's `starting` state.
final class StartingOnTheBoardTests: XCTestCase {
    private func line(_ event: String, _ pane: String, status: String) -> AgentEventLine {
        AgentEventLine(event: event, pane: pane, pid: 1, status: status)
    }

    /// It must reach the board — "4 running, 1 still starting" is the whole point — but it
    /// must not escalate. The agent has not asked for anything; alerting per task at launch
    /// would make a fan-out fire an alert for every task it started.
    func testStartingIsTrackedButNeverEscalates() {
        var board = AgentBoard()
        let change = board.apply(line("appeared", "A", status: "starting"))
        XCTAssertEqual(board.agents["A"]?.status, "starting")
        XCTAssertNil(change?.escalation)
        XCTAssertFalse(board.agents["A"]?.isWaiting ?? true)
    }

    func testAStartingAgentBecomingBlockedStillEscalates() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", status: "starting"))
        let change = board.apply(AgentEventLine(event: "changed", pane: "A", pid: 1,
                                                status: "waiting", waitingFor: "permission prompt"))
        XCTAssertEqual(change?.escalation?.question, "permission prompt")
    }
}

/// "It finished" for a human to read, which is not the same as a completion signal to
/// schedule on. #16 measured that a session running in a pane never publishes a terminal
/// state, so nothing here claims a task is done — what is observable is that an agent WAS
/// working and now is not, and that is worth telling someone.
///
/// The distinction that makes it honest: only an agent seen `busy` can finish. An agent that
/// merely appeared `idle` was never prompted, and announcing that as finished would fire once
/// per task at launch — exactly the noise that teaches people to ignore notifications.
final class FinishedTurnTests: XCTestCase {
    private func line(_ event: String, _ pane: String, status: String,
                      waitingFor: String? = nil) -> AgentEventLine {
        AgentEventLine(event: event, pane: pane, pid: 1, status: status, waitingFor: waitingFor)
    }

    func testAnAgentThatWorkedAndStoppedIsReportedFinished() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", status: "busy"))
        guard case .finishedTurn(let a)? = board.apply(line("changed", "A", status: "idle")) else {
            return XCTFail("an agent that finished working was not reported")
        }
        XCTAssertEqual(a.paneID, "A")
    }

    /// The case that keeps it from becoming noise.
    func testAnAgentThatWasNeverBusyIsNotReportedFinished() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", status: "idle"))
        XCTAssertNil(board.apply(line("changed", "A", status: "shell")))
        XCTAssertNil(board.apply(line("changed", "A", status: "idle")))
    }

    /// `starting` is damson's own state for a pane that has not checked in. Going from that
    /// to idle is arriving, not finishing.
    func testStartingToIdleIsNotFinished() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", status: "starting"))
        XCTAssertNil(board.apply(line("changed", "A", status: "idle")))
    }

    /// A second turn reports again — the human's attention is needed each time it stops.
    func testEachTurnIsReported() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", status: "busy"))
        guard case .finishedTurn? = board.apply(line("changed", "A", status: "idle")) else {
            return XCTFail("first turn")
        }
        board.apply(line("changed", "A", status: "busy"))
        guard case .finishedTurn? = board.apply(line("changed", "A", status: "idle")) else {
            return XCTFail("second turn was not reported")
        }
    }

    /// Being blocked is not finishing. It takes the attention path, and announcing both
    /// would tell the user twice about one thing.
    func testBusyToWaitingIsAttentionNotFinished() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", status: "busy"))
        guard case .needsAttention? =
                board.apply(line("changed", "A", status: "waiting", waitingFor: "q")) else {
            return XCTFail("expected attention")
        }
    }

    /// Answering a question and carrying on to a stop still counts as finishing that turn.
    func testWaitingThenBusyThenIdleFinishes() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", status: "waiting", waitingFor: "q"))
        board.apply(line("changed", "A", status: "busy"))
        guard case .finishedTurn? = board.apply(line("changed", "A", status: "idle")) else {
            return XCTFail("not reported after the question was answered")
        }
    }

    /// A new process in an old pane starts over: it has not worked yet.
    func testANewProcessMustWorkBeforeItCanFinish() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", status: "busy"))
        board.apply(AgentEventLine(event: "vanished", pane: "A", pid: 1))
        board.apply(AgentEventLine(event: "appeared", pane: "A", pid: 2, status: "idle"))
        XCTAssertNil(board.apply(AgentEventLine(event: "changed", pane: "A", pid: 2, status: "idle")))
    }
}

/// Noticing an agent that has stopped making progress without saying so.
///
/// Measured live: a `claude` retrying an overloaded API showed
/// `529 Overloaded · Retrying in 9s · attempt 8/10` on screen while its published status
/// stayed `busy` for minutes. From outside the pane that is indistinguishable from real
/// work, so a fan-out where several agents hit it looks like a run making progress.
///
/// Duration is the one thing that can be known for certain here — no inference about what
/// the agent is doing, just how long it has been in the same state. The stream is
/// edge-triggered, so nothing arrives while an agent is stuck; the 20s heartbeat is what
/// drives this.
final class StalledAgentTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func line(_ event: String, _ pane: String, status: String) -> AgentEventLine {
        AgentEventLine(event: event, pane: pane, pid: 1, status: status)
    }

    func testAnAgentBusyPastTheThresholdIsReportedOnce() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", status: "busy"), now: t0)
        XCTAssertEqual(board.tick(now: t0.addingTimeInterval(60), stallAfter: 300).count, 0)

        let late = board.tick(now: t0.addingTimeInterval(301), stallAfter: 300)
        guard case .stalled(let a)? = late.first else { return XCTFail("not reported: \(late)") }
        XCTAssertEqual(a.paneID, "A")
        // Once. A notice every heartbeat would be the noise this is trying to surface.
        XCTAssertEqual(board.tick(now: t0.addingTimeInterval(600), stallAfter: 300).count, 0)
    }

    /// An agent that never checks in is the other half of the same problem — #18's case,
    /// where the pane sat on a first-run prompt. `starting` for minutes is worth saying.
    func testAnAgentStuckStartingIsReported() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", status: "starting"), now: t0)
        guard case .stalled? = board.tick(now: t0.addingTimeInterval(301), stallAfter: 300).first else {
            return XCTFail("a pane that never checked in was not reported")
        }
    }

    /// Idle and waiting are not stalls. Idle is a finished turn, and waiting already has its
    /// own escalation — announcing it twice would be telling the user the same thing again.
    func testRestingStatesAreNeverStalls() {
        for status in ["idle", "waiting", "shell"] {
            var board = AgentBoard()
            board.apply(line("appeared", "A", status: status), now: t0)
            XCTAssertEqual(board.tick(now: t0.addingTimeInterval(3600), stallAfter: 300).count, 0,
                           status)
        }
    }

    /// Progress resets the clock, and makes the agent eligible to be reported again later.
    func testAStatusChangeResetsTheClock() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", status: "busy"), now: t0)
        _ = board.tick(now: t0.addingTimeInterval(301), stallAfter: 300)
        board.apply(line("changed", "A", status: "idle"), now: t0.addingTimeInterval(310))
        board.apply(line("changed", "A", status: "busy"), now: t0.addingTimeInterval(320))
        XCTAssertEqual(board.tick(now: t0.addingTimeInterval(400), stallAfter: 300).count, 0,
                       "the clock did not restart")
        guard case .stalled? = board.tick(now: t0.addingTimeInterval(700), stallAfter: 300).first else {
            return XCTFail("a second stall was not reported")
        }
    }

    func testEveryStalledAgentIsReported() {
        var board = AgentBoard()
        for p in ["A", "B", "C"] { board.apply(line("appeared", p, status: "busy"), now: t0) }
        XCTAssertEqual(board.tick(now: t0.addingTimeInterval(301), stallAfter: 300).count, 3)
    }

    /// A stall is news, not an interruption: the agent has not asked for anything.
    func testAStallDoesNotStealFocus() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", status: "busy"), now: t0)
        let change = board.tick(now: t0.addingTimeInterval(301), stallAfter: 300).first
        XCTAssertEqual(change?.escalation?.kind, .stalled)
        XCTAssertEqual(change?.escalation?.deservesFocus, false)
    }
}
