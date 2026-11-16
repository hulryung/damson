import XCTest
import DamsonTerminal
@testable import DamsonAgents

final class AgentActivityTests: XCTestCase {
    private func classify(_ report: ReportedAgentState? = nil, badge: AgentBadge? = nil,
                          argv: [String] = ["/bin/zsh", "-l"]) -> AgentActivity? {
        AgentActivity.classify(report: report, reportedAt: nil, badge: badge, argv: argv)
    }

    func testExplicitReportWinsOverObservationAndLauncher() {
        XCTAssertEqual(classify(.completed, badge: .waiting, argv: ["claude"])?.source,
                       .explicitReport(.completed, at: nil))
        XCTAssertEqual(classify(badge: .idle, argv: ["claude"])?.source, .claudeObservation(.idle))
    }

    /// A silent launcher is listed as unknown, never as done; a plain shell is not listed.
    func testUnreportedLauncherIsUnknownAndShellIsAbsent() {
        let codex = classify(argv: ["/opt/homebrew/bin/codex", "--full-auto"])
        XCTAssertEqual(codex?.source, .unreported(program: "codex"))
        XCTAssertEqual(codex?.detail(cwd: "/w") { _ in "" }, "State unknown · no report from codex · /w")
        XCTAssertNil(classify())
        XCTAssertNil(classify(argv: []))
        XCTAssertNil(classify(argv: ["myclaude"]))
    }

    /// The attention order comes from the state, not from how a detail line happens to
    /// start: every state and badge is ranked, and only `waiting` is first.
    func testAttentionRankCoversEveryState() {
        for state in ReportedAgentState.allCases {
            let rank = classify(state)!.attentionRank
            XCTAssertEqual(rank, state == .waiting ? 0 : state == .failed ? 1 : 2, state.rawValue)
        }
        for badge in [AgentBadge.busy, .shell, .idle, .waiting, .starting] {
            XCTAssertEqual(classify(badge: badge)!.attentionRank, badge == .waiting ? 0 : 2, badge.rawValue)
        }
        XCTAssertEqual(classify(argv: ["gemini"])!.attentionRank, 2)
    }

    func testDetailNamesStateSourceAndFolder() {
        let at = Date(timeIntervalSince1970: 0)
        let report = AgentActivity.classify(report: .waiting, reportedAt: at, badge: nil, argv: [])!
        XCTAssertEqual(report.detail(cwd: "/repo") { _ in "12:00" }, "waiting · explicit report at 12:00 · /repo")
        XCTAssertEqual(classify(badge: .waiting)!.detail(cwd: "/r") { _ in "" },
                       "waiting for you · Claude observation · /r")
    }

    func testSortPutsAttentionFirstThenTitleStably() {
        let rows: [(Int, String)] = [(2, "b"), (0, "z"), (2, "a 10"), (1, "c"), (2, "a 9"), (0, "y"), (2, "b")]
        let sorted = AgentActivity.sorted(rows.enumerated().map { $0 }, rank: { $0.element.0 }, title: { $0.element.1 })
        XCTAssertEqual(sorted.map(\.element.1), ["y", "z", "c", "a 9", "a 10", "b", "b"])
        XCTAssertEqual(sorted.suffix(2).map(\.offset), [0, 6])
    }
}
