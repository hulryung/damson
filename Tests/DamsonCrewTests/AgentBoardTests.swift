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

    func testLeavingWaitingIsReported() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", status: "waiting", waitingFor: "q"))
        guard case .released? = board.apply(line("changed", "A", status: "busy")) else {
            return XCTFail("an unblocked agent was not reported")
        }
    }

    /// `busy` → `idle` must not escalate. `idle` also means "asked a clarifying question"
    /// and "spawned but never prompted", so notifying on it would fire constantly and train
    /// the user to dismiss the one that mattered.
    func testIdleDoesNotRaiseAttention() {
        var board = AgentBoard()
        board.apply(line("appeared", "A", status: "busy"))
        XCTAssertNil(board.apply(line("changed", "A", status: "idle")))
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
