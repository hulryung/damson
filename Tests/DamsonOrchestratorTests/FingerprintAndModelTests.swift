import XCTest
@testable import DamsonOrchestrator

final class FingerprintAndModelTests: XCTestCase {

    func testInputBoxDetection() {
        XCTAssertTrue(ClaudeFingerprints.hasInputBox(["│ > Try something │"]))
        XCTAssertTrue(ClaudeFingerprints.hasInputBox(["  ? for shortcuts"]))
        XCTAssertFalse(ClaudeFingerprints.hasInputBox(["just some output text"]))
    }

    func testWorkingDetection() {
        XCTAssertTrue(ClaudeFingerprints.isWorking(["✻ Thinking… (12s · esc to interrupt)"]))
        XCTAssertTrue(ClaudeFingerprints.isWorking(["✶ Forging… (3s)"]))
        XCTAssertTrue(ClaudeFingerprints.isWorking(["Working (esc to interrupt)"]))
        XCTAssertFalse(ClaudeFingerprints.isWorking(["│ > ready for input │"]))
    }

    func testApprovalDetection() {
        XCTAssertTrue(ClaudeFingerprints.isApprovalPrompt([
            "❯ 1. Yes", "  2. No, and tell Claude what to do",
        ]))
        XCTAssertTrue(ClaudeFingerprints.isApprovalPrompt(["Do you want to proceed?"]))
        // A single numbered line is not enough.
        XCTAssertFalse(ClaudeFingerprints.isApprovalPrompt(["1. just a list item"]))
    }

    func testElapsedTimerParsing() {
        XCTAssertTrue(ClaudeFingerprints.containsElapsedTimer("Thinking (12s"))
        XCTAssertTrue(ClaudeFingerprints.containsElapsedTimer("(3s · esc)"))
        XCTAssertFalse(ClaudeFingerprints.containsElapsedTimer("(abc)"))
        XCTAssertFalse(ClaudeFingerprints.containsElapsedTimer("no parens"))
    }

    func testNumberedOptionMatcher() {
        XCTAssertTrue(ClaudeFingerprints.matchesNumberedOption("❯ 1. Yes"))
        XCTAssertTrue(ClaudeFingerprints.matchesNumberedOption("2. No"))
        XCTAssertTrue(ClaudeFingerprints.matchesNumberedOption("3) maybe"))
        XCTAssertFalse(ClaudeFingerprints.matchesNumberedOption("hello world"))
    }

    func testTaskSlug() {
        XCTAssertEqual(AgentTask(title: "Fix the Parser Bug!", prompt: "", engineID: "x", baseRepoPath: "/").slug,
                       "fix-the-parser-bug")
        XCTAssertEqual(AgentTask(title: "  ", prompt: "", engineID: "x", baseRepoPath: "/").slug, "task")
        XCTAssertEqual(AgentTask(title: "한글 제목", prompt: "", engineID: "x", baseRepoPath: "/", branchHint: "my-branch").slug,
                       "my-branch")
    }

    func testEngineRegistry() {
        XCTAssertNotNil(AgentEngineRegistry.engine(id: "claude-code"))
        XCTAssertNotNil(AgentEngineRegistry.engine(id: "shell"))
        XCTAssertNil(AgentEngineRegistry.engine(id: "nonexistent"))
    }
}
