import XCTest
@testable import DamsonAgents

/// An agent blocked before Claude Code has published its session record used to be invisible:
/// no badge, no `appeared` event, nothing for a coordinator to escalate. Measured on 0.6.0 —
/// a `claude` sitting on a first-run consent screen reported nothing for a full minute while
/// it waited for a keypress.
///
/// damson spawned those panes, so it knows their argv. That is the difference between "no
/// agent here" and "an agent that has not checked in yet", and it is the only thing this adds.
final class AgentPresenceTests: XCTestCase {

    private func row(_ status: String) -> ClaudeSessionRow {
        ClaudeSessionRow(pid: 1, sessionId: "s", cwd: "/tmp", name: nil,
                         status: status, waitingFor: nil, version: nil)
    }

    // MARK: - A record wins, always

    /// Whatever damson believes about the argv, a published record is the truth.
    func testAReportedStatusAlwaysWins() {
        XCTAssertEqual(AgentPresence.of(row: row("busy"), argv: ["claude"]), .reported("busy"))
        XCTAssertEqual(AgentPresence.of(row: row("waiting"), argv: ["/bin/zsh"]), .reported("waiting"))
    }

    // MARK: - No record

    func testAKnownAgentWithNoRecordIsStarting() {
        XCTAssertEqual(AgentPresence.of(row: nil, argv: ["claude"]), .starting)
        XCTAssertEqual(AgentPresence.of(row: nil, argv: ["/opt/homebrew/bin/claude"]), .starting)
        XCTAssertEqual(AgentPresence.of(row: nil, argv: ["claude", "--permission-mode", "default", "do it"]),
                       .starting)
    }

    /// A shell is not a late agent. Reporting one would put a badge on every ordinary tab.
    func testAShellIsNotStarting() {
        for argv in [["/bin/zsh"], ["/bin/zsh", "-i"], ["/bin/bash", "-lc", "claude"], ["fish"]] {
            XCTAssertEqual(AgentPresence.of(row: nil, argv: argv), .none, "\(argv)")
        }
    }

    /// Only programs that will publish a record may be `starting`. codex, grok and
    /// cursor-agent run happily in damson but publish nothing, so a pane on one of them would
    /// sit in `starting` for its whole life — a permanent wrong badge, which is exactly what
    /// AgentBadge's fail-quiet rule exists to prevent.
    func testOtherAgentsThatPublishNothingAreNotStarting() {
        for argv in [["codex"], ["grok"], ["cursor-agent"], ["/Users/x/.local/bin/cursor-agent"]] {
            XCTAssertEqual(AgentPresence.of(row: nil, argv: argv), .none, "\(argv)")
        }
    }

    func testAnEmptyArgvIsNotStarting() {
        XCTAssertEqual(AgentPresence.of(row: nil, argv: []), .none)
    }

    /// `claude` must be matched as a whole program name, not as a substring — otherwise
    /// anything from `claude-helper` to a script called `myclaude` would claim to be an agent.
    func testOnlyTheExactProgramNameCounts() {
        for argv in [["claude-helper"], ["myclaude"], ["/usr/bin/claudette"], ["not-claude"]] {
            XCTAssertEqual(AgentPresence.of(row: nil, argv: argv), .none, "\(argv)")
        }
    }

    // MARK: - What it renders as

    /// `starting` is ambient, not attention. The agent has not asked for anything yet; if it
    /// escalated, every fan-out would fire an alert per task at launch.
    func testStartingIsNotAttention() {
        XCTAssertEqual(AgentBadge.starting.isAttention, false)
    }

    /// The parser stays closed to Claude Code's own vocabulary. `starting` is damson's word,
    /// constructed directly — so a future CLI release that happens to publish "starting"
    /// cannot silently inherit damson's meaning for it.
    func testTheStatusParserNeverProducesStarting() {
        XCTAssertNil(AgentBadge(status: "starting"))
        XCTAssertEqual(AgentBadge(status: "busy"), .busy)
        XCTAssertNil(AgentBadge(status: "teleporting"))
    }
}
