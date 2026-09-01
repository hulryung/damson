import XCTest
@testable import DamsonCrew

/// Agents that stop on a permission prompt are the most common way a fan-out stalls: the run
/// looks alive, several tabs are idle, and every one of them is waiting for a keypress. So
/// damson-crew passes `--dangerously-skip-permissions` by default.
///
/// The name is the warning. It removes every confirmation an agent would otherwise ask for,
/// so it is only reasonable because the caller deliberately opened a terminal to run agents
/// in and can watch them — and it is a setting, not a law.
final class AgentFlagsTests: XCTestCase {

    func testClaudeGetsTheFlag() {
        XCTAssertEqual(AgentFlags.apply(skipPermissions: true, to: ["claude"]),
                       ["claude", "--dangerously-skip-permissions"])
        XCTAssertEqual(AgentFlags.apply(skipPermissions: true, to: ["/opt/homebrew/bin/claude", "do it"]),
                       ["/opt/homebrew/bin/claude", "--dangerously-skip-permissions", "do it"])
    }

    /// The prompt has to stay the last positional argument — that is the shape every agent
    /// CLI takes — so the flag goes in before it, not on the end.
    func testTheFlagGoesBeforeThePrompt() {
        let out = AgentFlags.apply(skipPermissions: true, to: ["claude", "review the auth changes"])
        XCTAssertEqual(out.last, "review the auth changes")
    }

    func testTheSettingTurnsItOff() {
        XCTAssertEqual(AgentFlags.apply(skipPermissions: false, to: ["claude", "go"]),
                       ["claude", "go"])
    }

    /// Only claude. `codex`, `grok` and `cursor-agent` each have their own spelling for this,
    /// and inventing a flag for a CLI that does not have it turns a working spawn into a pane
    /// that exits instantly on an unknown argument.
    func testOtherAgentsAreLeftAlone() {
        for program in ["codex", "grok", "cursor-agent", "/bin/zsh"] {
            XCTAssertEqual(AgentFlags.apply(skipPermissions: true, to: [program, "go"]),
                           [program, "go"], program)
        }
    }

    func testItIsNotAddedTwice() {
        let already = ["claude", "--dangerously-skip-permissions", "go"]
        XCTAssertEqual(AgentFlags.apply(skipPermissions: true, to: already), already)
    }

    /// A caller who spelled out what they wanted means it. Adding a bypass on top of an
    /// explicit `--permission-mode plan` would silently do the opposite of what they asked —
    /// and this flag's whole risk is that it cannot be undone once the agent has acted.
    func testAnExplicitPermissionChoiceIsNeverOverridden() {
        for given in [["claude", "--permission-mode", "plan", "go"],
                      ["claude", "--permission-mode=acceptEdits"],
                      ["claude", "--allow-dangerously-skip-permissions"]] {
            XCTAssertEqual(AgentFlags.apply(skipPermissions: true, to: given), given,
                           "\(given) was overridden")
        }
    }

    func testAnEmptyArgvIsUntouched() {
        XCTAssertEqual(AgentFlags.apply(skipPermissions: true, to: []), [])
    }
}
