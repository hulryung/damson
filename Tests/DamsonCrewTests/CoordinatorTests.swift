import DamsonControl
import XCTest
@testable import DamsonCrew

/// Fan-out. The failures worth pinning are the partial ones — three tasks of five opened —
/// because that is what actually happens and it is neither quick nor repeatable to
/// reproduce against a running app.
final class CoordinatorTests: XCTestCase {

    /// Records what was sent and answers from a script.
    private final class FakeDamson: DamsonClient {
        var sent: [ControlCommandKind] = []
        var answers: [Result<ControlResponse, CrewError>] = []
        var listAgentsResponse: ControlResponse?

        func send(_ kind: ControlCommandKind, target: PaneTarget) -> Result<ControlResponse, CrewError> {
            sent.append(kind)
            if case .listAgents = kind, let r = listAgentsResponse { return .success(r) }
            return answers.isEmpty ? .success(.ok()) : answers.removeFirst()
        }
    }

    private func pane(_ id: String, title: String? = nil) -> ControlResponse {
        .pane(PaneInfo(index: 0, cols: 80, rows: 24, active: false, id: id, title: title))
    }

    private let tasks = [
        CrewTask(name: "review-api", cwd: "/a", prompt: "review it"),
        CrewTask(name: "fix-parser", cwd: "/b", prompt: "fix it"),
    ]

    // MARK: - What gets sent

    /// The prompt must ride in argv. Typing it into the pane has no delivery acknowledgment,
    /// so a prompt that races the TUI's input box is lost and nothing can tell.
    func testPromptGoesInArgv() {
        let fake = FakeDamson()
        fake.answers = [.success(pane("A")), .success(pane("B"))]
        // Permission bypass off, so this test is only about where the prompt lands.
        _ = Coordinator(client: fake, skipPermissions: false).fanOut(tasks, group: nil)

        guard case .spawnPane(let spec) = fake.sent.first else { return XCTFail("no spawn") }
        XCTAssertEqual(spec.argv, ["claude", "review it"])
        XCTAssertEqual(spec.cwd, "/a")
    }

    /// An agent stopped on an approval prompt is the most common way a fan-out stalls, so
    /// the bypass is on unless the caller turns it off — and the prompt still ends up last,
    /// which is the one argv shape every agent CLI accepts.
    func testPermissionsAreBypassedByDefault() {
        let fake = FakeDamson()
        fake.answers = [.success(pane("A")), .success(pane("B"))]
        _ = Coordinator(client: fake).fanOut(tasks, group: nil)

        guard case .spawnPane(let spec) = fake.sent.first else { return XCTFail("no spawn") }
        XCTAssertEqual(spec.argv, ["claude", "--dangerously-skip-permissions", "review it"])
    }

    /// A task that names its own command gets it too — a stalled agent is a stalled agent
    /// however it was launched.
    func testAPerTaskCommandAlsoGetsTheBypass() {
        let fake = FakeDamson()
        fake.answers = [.success(pane("A"))]
        _ = Coordinator(client: fake).fanOut(
            [CrewTask(name: "t", prompt: "go", command: ["/opt/homebrew/bin/claude"])], group: nil)

        guard case .spawnPane(let spec) = fake.sent.first else { return XCTFail("no spawn") }
        XCTAssertEqual(spec.argv,
                       ["/opt/homebrew/bin/claude", "--dangerously-skip-permissions", "go"])
    }

    /// The task name is the spawn key, so a repeat is answered with the first pane rather
    /// than minting a second agent. damson reports a timeout at 2s while the queued work
    /// still completes, so "failed" for a tab that did open is a case that really happens.
    func testEverySpawnCarriesTheTaskNameAsItsKey() {
        let fake = FakeDamson()
        fake.answers = [.success(pane("A")), .success(pane("B"))]
        _ = Coordinator(client: fake).fanOut(tasks, group: nil)

        let keys = fake.sent.compactMap { kind -> String? in
            guard case .spawnPane(let s) = kind else { return nil }
            return s.key
        }
        XCTAssertEqual(keys, ["review-api", "fix-parser"])
    }

    func testGroupIsAppliedToEveryTask() {
        let fake = FakeDamson()
        fake.answers = [.success(pane("A")), .success(pane("B"))]
        _ = Coordinator(client: fake).fanOut(tasks, group: "run-7")

        let groups = fake.sent.compactMap { kind -> String? in
            guard case .spawnPane(let s) = kind else { return nil }
            return s.group
        }
        XCTAssertEqual(groups, ["run-7", "run-7"])
    }

    func testTitleIsTheTaskNameSoTheTabsAreTellableApart() {
        let fake = FakeDamson()
        fake.answers = [.success(pane("A")), .success(pane("B"))]
        _ = Coordinator(client: fake).fanOut(tasks, group: nil)
        let titles = fake.sent.compactMap { kind -> String? in
            guard case .spawnPane(let s) = kind else { return nil }
            return s.title
        }
        XCTAssertEqual(titles, ["review-api", "fix-parser"])
    }

    // MARK: - Partial failure

    /// A run of five where the third cannot start should leave four agents working and one
    /// thing to fix — not nothing at all.
    func testOneFailureDoesNotStopTheRest() {
        let three = tasks + [CrewTask(name: "write-docs")]
        let fake = FakeDamson()
        fake.answers = [.success(pane("A")),
                        .failure(CrewError("connection refused")),
                        .success(pane("C"))]
        let out = Coordinator(client: fake).fanOut(three, group: nil)

        XCTAssertEqual(out.map(\.opened), [true, false, true])
        XCTAssertEqual(out.map(\.paneID), ["A", nil, "C"])
        XCTAssertEqual(out[1].error, "connection refused")
        XCTAssertEqual(fake.sent.count, 3, "a failure must not abort the remaining tasks")
    }

    func testARefusedSpawnCarriesDamsonsOwnReason() {
        let fake = FakeDamson()
        fake.answers = [.success(.err("no window to spawn into")), .success(pane("B"))]
        let out = Coordinator(client: fake).fanOut(tasks, group: nil)
        XCTAssertEqual(out[0].error, "no window to spawn into")
        XCTAssertTrue(out[1].opened)
    }

    /// "ok" with no pane id leaves the task unaddressable — the coordinator can never send
    /// it anything or read its state. That is a failure whatever damson called it.
    func testSuccessWithoutAPaneIDIsAFailure() {
        let fake = FakeDamson()
        fake.answers = [.success(.ok()), .success(pane("B"))]
        let out = Coordinator(client: fake).fanOut(tasks, group: nil)
        XCTAssertFalse(out[0].opened)
        XCTAssertEqual(out[0].error, "damson opened a pane but reported no id")
    }

    // MARK: - Reattach

    /// A coordinator restarting must find the run already on screen rather than opening it
    /// a second time.
    func testReattachMatchesTabsByLabel() {
        let fake = FakeDamson()
        fake.listAgentsResponse = .panes([
            PaneInfo(index: 0, cols: 80, rows: 24, active: false, id: "A", title: "review-api"),
            PaneInfo(index: 0, cols: 80, rows: 24, active: false, id: "Z", title: "somebody's shell"),
        ])
        XCTAssertEqual(Coordinator(client: fake).reattach(tasks), ["review-api": "A"])
    }

    func testReattachIsEmptyWhenDamsonCannotBeReached() {
        let fake = FakeDamson()
        fake.answers = [.failure(CrewError("no instance"))]
        XCTAssertEqual(Coordinator(client: fake).reattach(tasks), [:])
    }
}
