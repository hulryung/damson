import DamsonTerminal
import XCTest
@testable import DamsonAgents

/// When a pane's process did not survive a restart — no keeper, or the child died while
/// held — damson re-runs what the pane WAS running instead of silently restoring a login
/// shell. For Claude Code the session-identity flags are stripped so it starts clean.
///
/// That retreat is measured, not assumed: rewriting `--session-id` to `--resume` was tried
/// and it LOSES the pane. `claude --resume <id>` exits when there is no conversation ("No
/// conversation found") and can exit even when there is one ("No deferred tool marker found
/// in the resumed session…"). A process that exits on startup closes its pane, leaving the
/// user with nothing where a working terminal used to be.
final class RestartArgvTests: XCTestCase {

    func testSessionIdentityFlagsAreStrippedForClaude() {
        let id = "048AAA79-3109-4ABA-8D87-FAE2FE5A8702"
        XCTAssertEqual(
            AgentLaunch.restartArgv(["/opt/homebrew/bin/claude", "--session-id", id, "--name", "damson"]),
            ["/opt/homebrew/bin/claude", "--name", "damson"])
        XCTAssertEqual(
            AgentLaunch.restartArgv(["claude", "--resume", id]), ["claude"])
        XCTAssertEqual(
            AgentLaunch.restartArgv(["claude", "-r", id, "--name", "x"]), ["claude", "--name", "x"])
    }

    /// Everything else about the pane survives — the point is a working pane that is still
    /// recognizably the same thing, in the same directory, with the same label.
    func testEverythingElseIsPreserved() {
        let argv = ["/opt/homebrew/bin/claude", "--session-id", "X", "--name", "proj",
                    "--permission-mode", "acceptEdits"]
        XCTAssertEqual(AgentLaunch.restartArgv(argv),
                       ["/opt/homebrew/bin/claude", "--name", "proj",
                        "--permission-mode", "acceptEdits"])
    }

    /// Anything that is not Claude Code is re-run verbatim: damson does not know what those
    /// flags mean to another program, and stripping them would be a guess.
    func testOtherProgramsAreReRunUnchanged() {
        for argv in [["/usr/bin/vim", "--session-id", "X"],
                     ["/bin/zsh", "-l"],
                     ["npm", "run", "dev"]] {
            XCTAssertEqual(AgentLaunch.restartArgv(argv), argv)
        }
    }

    /// Matched on the executable's NAME, so it holds for any install path — and a program
    /// that merely lives under a directory called "claude" is not Claude Code.
    func testClaudeIsMatchedByExecutableNameNotPath() {
        XCTAssertEqual(AgentLaunch.restartArgv(["/Users/me/.claude/local/claude", "--session-id", "X"]),
                       ["/Users/me/.claude/local/claude"])
        XCTAssertEqual(AgentLaunch.restartArgv(["/Users/claude/bin/vim", "--session-id", "X"]),
                       ["/Users/claude/bin/vim", "--session-id", "X"])
    }

    /// A trailing flag with no value must not produce a dangling argument.
    func testMalformedArgvDoesNotProduceGarbage() {
        XCTAssertEqual(AgentLaunch.restartArgv(["claude", "--session-id"]), ["claude"])
        XCTAssertEqual(AgentLaunch.restartArgv([]), [])
        XCTAssertEqual(AgentLaunch.restartArgv(["claude"]), ["claude"])
    }

    /// The round trip that matters: what the launcher produces must restart into something
    /// that still runs. These two drifting apart is the failure this pins.
    func testLaunchArgvRestartsIntoARunnableCommand() {
        var base = DamsonConfig()
        base.env = ["PATH": "/usr/bin:/bin"]
        let argv = AgentLaunch.config(base: base, cwd: "/p", sessionID: UUID(), label: "proj").argv
        let restarted = AgentLaunch.restartArgv(argv)
        XCTAssertFalse(restarted.contains("--session-id"))
        XCTAssertFalse(restarted.contains("--resume"))
        XCTAssertEqual(restarted.first, argv.first, "still the same executable")
        XCTAssertTrue(restarted.contains("--name"), "the label identifies the pane; keep it")
        // No flag may be left without its value.
        XCTAssertEqual(restarted.count % 2, 1, "executable + flag/value pairs")
    }
}
