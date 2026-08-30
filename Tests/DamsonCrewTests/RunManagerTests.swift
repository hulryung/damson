import DamsonControl
import XCTest
@testable import DamsonCrew

/// A run that cannot be found again gets opened twice; a run that cannot be closed piles up
/// until the window is unusable. Both are quiet failures, which is why they are tested here
/// rather than noticed later.
final class RunManagerTests: XCTestCase {

    private final class FakeDamson: DamsonClient {
        var sent: [ControlCommandKind] = []
        var panes: [PaneInfo] = []
        var listResult: Result<ControlResponse, CrewError>?
        var closeResult: Result<ControlResponse, CrewError> = .success(.ok())

        func send(_ kind: ControlCommandKind, target: PaneTarget) -> Result<ControlResponse, CrewError> {
            sent.append(kind)
            if case .listAgents = kind { return listResult ?? .success(.panes(panes)) }
            if case .closeGroup = kind { return closeResult }
            return .success(.ok())
        }
    }

    private func pane(_ id: String, title: String, group: String? = nil,
                      agent: String? = nil) -> PaneInfo {
        PaneInfo(index: 0, cols: 80, rows: 24, active: false, id: id, tab: 0,
                 title: title, agent: agent, group: group)
    }

    private let tasks = [CrewTask(name: "review-api"),
                         CrewTask(name: "fix-parser"),
                         CrewTask(name: "write-docs")]

    // MARK: - Reattach

    func testStatusJoinsTasksToWhatIsOnScreen() throws {
        let fake = FakeDamson()
        fake.panes = [pane("A", title: "review-api", group: "run-7", agent: "busy"),
                      pane("B", title: "fix-parser", group: "run-7", agent: "waiting")]
        let status = try XCTUnwrap(try? RunManager(client: fake).status(of: tasks, group: "run-7").get())

        XCTAssertEqual(status.rows.map(\.paneID), ["A", "B", nil])
        XCTAssertEqual(status.missing, ["write-docs"])
        XCTAssertEqual(status.waiting.map(\.task), ["fix-parser"])
    }

    /// Two runs can carry the same task names. Without the group filter the second run would
    /// reattach to the first one's tabs and drive the wrong agents.
    func testAGroupedRunIgnoresIdenticallyNamedTabsElsewhere() throws {
        let fake = FakeDamson()
        fake.panes = [pane("OLD", title: "review-api", group: "run-6"),
                      pane("NEW", title: "review-api", group: "run-7")]
        let status = try XCTUnwrap(try? RunManager(client: fake).status(of: [tasks[0]], group: "run-7").get())
        XCTAssertEqual(status.rows.first?.paneID, "NEW")
    }

    /// Without a group there is nothing to filter by, so a label match is all there is.
    func testAnUngroupedRunMatchesOnLabelAlone() throws {
        let fake = FakeDamson()
        fake.panes = [pane("A", title: "review-api")]
        let status = try XCTUnwrap(try? RunManager(client: fake).status(of: [tasks[0]], group: nil).get())
        XCTAssertEqual(status.rows.first?.paneID, "A")
    }

    /// A pane whose agent exited keeps its tab and falls back to a shell. Reading "no agent"
    /// as "tab is gone" would make a coordinator re-open a tab that is already there.
    func testAPaneWithNoAgentStillCountsAsHavingATab() throws {
        let fake = FakeDamson()
        fake.panes = [pane("A", title: "review-api", group: "run-7", agent: nil)]
        let status = try XCTUnwrap(try? RunManager(client: fake).status(of: [tasks[0]], group: "run-7").get())
        XCTAssertTrue(status.rows[0].hasTab)
        XCTAssertNil(status.rows[0].agent)
        XCTAssertEqual(status.missing, [])
    }

    func testTasksNeedingTabsIsJustTheMissingOnes() {
        let fake = FakeDamson()
        fake.panes = [pane("A", title: "review-api", group: "run-7")]
        XCTAssertEqual(RunManager(client: fake).tasksNeedingTabs(tasks, group: "run-7").map(\.name),
                       ["fix-parser", "write-docs"])
    }

    /// If damson cannot be reached we do not know what is on screen. Reporting "nothing is
    /// missing" would silently skip the whole run.
    func testAnUnreachableDamsonMeansEveryTaskNeedsATab() {
        let fake = FakeDamson()
        fake.listResult = .failure(CrewError("no instance"))
        XCTAssertEqual(RunManager(client: fake).tasksNeedingTabs(tasks, group: "run-7").count, 3)
    }

    // MARK: - Teardown

    func testCloseSendsTheGroupClose() {
        let fake = FakeDamson()
        XCTAssertNoThrow(try RunManager(client: fake).close(group: "run-7").get())
        guard case .closeGroup(let name)? = fake.sent.last else { return XCTFail("no close") }
        XCTAssertEqual(name, "run-7")
    }

    /// A mistyped run name must not look like a clean teardown — the user would walk away
    /// believing a run was cleaned up that is still open.
    func testAnUnknownGroupIsAnError() {
        let fake = FakeDamson()
        fake.closeResult = .success(.err("no such group: run-9"))
        guard case .failure(let e) = RunManager(client: fake).close(group: "run-9") else {
            return XCTFail("closing an unknown group reported success")
        }
        XCTAssertEqual(e.message, "no such group: run-9")
    }
}
