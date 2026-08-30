import DamsonControl
import XCTest
@testable import DamsonCrew

/// The subscription loop. What matters here is what happens across a drop — awkward to
/// provoke against a real server, and exactly where a coordinator quietly stops noticing
/// that an agent is blocked.
final class AgentWatcherTests: XCTestCase {

    private func line(_ event: String, _ pane: String, status: String? = nil,
                      waitingFor: String? = nil) -> AgentEventLine {
        AgentEventLine(event: event, pane: pane, pid: 1, status: status, waitingFor: waitingFor)
    }

    /// Drive `run()` with a scripted sequence of subscriptions.
    private func watcher(_ episodes: [Result<[AgentEventLine], CrewError>],
                         onChange: @escaping (AgentBoard.Change, AgentBoard) -> Void = { _, _ in })
        -> (AgentWatcher, () -> [TimeInterval]) {
        var remaining = episodes
        var slept: [TimeInterval] = []
        let lock = NSLock()
        let w = AgentWatcher(
            stream: { open, emit in
                lock.lock(); let next = remaining.isEmpty ? nil : remaining.removeFirst(); lock.unlock()
                guard let next else { return .failure(CrewError("exhausted")) }
                switch next {
                case .success(let lines): open(); lines.forEach(emit); return .success(())
                case .failure(let e):     return .failure(e)
                }
            },
            backoff: { Double($0) },
            sleeper: { lock.lock(); slept.append($0); lock.unlock() },
            onChange: onChange)
        return (w, { lock.lock(); defer { lock.unlock() }; return slept })
    }

    /// Waiting for the delivery queue to drain, since delivery deliberately runs off the
    /// reading thread.
    private func drainDelivery() {
        let done = expectation(description: "delivery drained")
        DispatchQueue(label: "damson-crew.delivery").async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    /// A reconnect opens a new subscription that starts with its own snapshot. Carrying the
    /// old rows over would leave agents on the board that have since gone — and a
    /// coordinator would report a run as still working when it had ended.
    func testReconnectStartsFromTheNewSnapshot() {
        let (w, _) = watcher([
            .success([line("appeared", "A", status: "busy"),
                      line("appeared", "B", status: "busy")]),
            .success([line("appeared", "C", status: "busy")]),
        ])
        w.run(maxAttempts: 1)
        XCTAssertEqual(Set(w.snapshot.agents.keys), ["C"],
                       "rows from the previous subscription survived a reconnect")
    }

    /// A clean close is damson going away, not an error; failures are what should back off.
    func testConsecutiveFailuresStopTheLoop() {
        let (w, slept) = watcher([
            .failure(CrewError("refused")),
            .failure(CrewError("refused")),
            .failure(CrewError("refused")),
        ])
        w.run(maxAttempts: 3)
        XCTAssertEqual(slept().count, 2, "should have backed off between attempts, then given up")
    }

    func testBackoffGrowsWithConsecutiveFailures() {
        let (w, slept) = watcher([
            .failure(CrewError("x")), .failure(CrewError("x")), .failure(CrewError("x")),
        ])
        w.run(maxAttempts: 3)
        XCTAssertEqual(slept(), [1, 2], "backoff did not grow")
    }

    /// A successful episode between failures resets the count, so a link that flaps once an
    /// hour never creeps up to a 30s reconnect delay.
    func testASuccessfulSubscriptionResetsTheBackoff() {
        let (w, slept) = watcher([
            .failure(CrewError("x")),
            .success([]),
            .failure(CrewError("x")),
            .failure(CrewError("x")),
        ])
        w.run(maxAttempts: 2)
        XCTAssertEqual(slept(), [1, 0, 1])
    }

    func testStopEndsTheLoop() {
        var count = 0
        let w = AgentWatcher(stream: { _, _ in count += 1; return .success(()) },
                             backoff: { _ in 0 }, sleeper: { _ in },
                             onChange: { _, _ in })
        w.stop()
        w.run()
        XCTAssertEqual(count, 0, "run() continued after stop()")
    }

    /// The point of the whole thing: a blocked agent reaches the caller.
    func testABlockedAgentIsDeliveredToTheCaller() {
        var seen: [AgentBoard.Change] = []
        let lock = NSLock()
        let (w, _) = watcher([
            .success([line("appeared", "A", status: "busy"),
                      line("changed", "A", status: "waiting", waitingFor: "which auth flow?")]),
        ]) { change, _ in lock.lock(); seen.append(change); lock.unlock() }
        w.run(maxAttempts: 1)
        drainDelivery()
        lock.lock(); let got = seen; lock.unlock()
        guard case .needsAttention(let s)? = got.last else {
            return XCTFail("a blocked agent never reached the caller: \(got)")
        }
        XCTAssertEqual(s.waitingFor, "which auth flow?")
    }

    /// Panes are joined to tasks so a notification can name the work, not a UUID.
    func testPanesAreJoinedToTasks() {
        var remaining: [Result<[AgentEventLine], CrewError>] = [
            .success([line("appeared", "A", status: "busy")]),
        ]
        let w = AgentWatcher(
            stream: { open, emit in
                guard !remaining.isEmpty else { return .failure(CrewError("done")) }
                guard case .success(let lines) = remaining.removeFirst() else { return .success(()) }
                open()
                lines.forEach(emit)
                return .success(())
            },
            taskFor: { $0 == "A" ? "review-api" : nil },
            backoff: { _ in 0 }, sleeper: { _ in }, onChange: { _, _ in })
        w.run(maxAttempts: 1)
        XCTAssertEqual(w.snapshot.agents["A"]?.task, "review-api")
    }
}
