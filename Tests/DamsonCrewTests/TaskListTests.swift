import XCTest
@testable import DamsonCrew

/// A task name is not decoration: it is the tab label AND the spawn's idempotency key. A
/// blank or duplicated one silently collapses two tasks into one pane — the second spawn is
/// answered with the first one's tab and that work simply never runs. Catching it at parse
/// time is the difference between an error message and a run that looks fine and isn't.
final class TaskListTests: XCTestCase {

    private func parse(_ json: String) throws -> TaskList {
        try TaskList.parse(Data(json.utf8))
    }

    func testMinimalListParses() throws {
        let list = try parse(#"[{"name":"a"},{"name":"b","cwd":"/p","prompt":"go"}]"#)
        XCTAssertEqual(list.tasks.map(\.name), ["a", "b"])
        XCTAssertEqual(list.tasks[1].cwd, "/p")
        XCTAssertEqual(list.tasks[1].prompt, "go")
    }

    func testDuplicateNamesAreRejected() {
        XCTAssertThrowsError(try parse(#"[{"name":"a"},{"name":"a"}]"#)) {
            XCTAssertEqual($0 as? TaskList.ParseError, .duplicateName("a"))
        }
    }

    func testBlankNamesAreRejected() {
        for json in [#"[{"name":""}]"#, #"[{"name":"   "}]"#] {
            XCTAssertThrowsError(try parse(json)) {
                XCTAssertEqual($0 as? TaskList.ParseError, .blankName(index: 0))
            }
        }
    }

    func testEmptyListIsRejected() {
        XCTAssertThrowsError(try parse("[]")) {
            XCTAssertEqual($0 as? TaskList.ParseError, .empty)
        }
    }

    func testMalformedJSONReportsItselfRatherThanCrashing() {
        XCTAssertThrowsError(try parse("not json at all"))
        XCTAssertThrowsError(try parse(#"{"name":"a"}"#))   // an object, not an array
    }

    // MARK: - argv

    func testArgvPutsThePromptLast() {
        XCTAssertEqual(CrewTask(name: "a", prompt: "do it").argv(defaultCommand: ["claude"]),
                       ["claude", "do it"])
    }

    func testNoPromptMeansNoExtraArgument() {
        XCTAssertEqual(CrewTask(name: "a").argv(defaultCommand: ["claude"]), ["claude"])
        XCTAssertEqual(CrewTask(name: "a", prompt: "").argv(defaultCommand: ["claude"]), ["claude"])
    }

    func testAPerTaskCommandOverridesTheDefault() {
        XCTAssertEqual(CrewTask(name: "a", prompt: "go", command: ["codex", "-q"])
                        .argv(defaultCommand: ["claude"]),
                       ["codex", "-q", "go"])
    }
}

/// A task list is written by a human, so it contains `~`. damson `chdir`s to whatever it is
/// handed and discards the failure, so an unexpanded tilde produces no error at all — the
/// pane just opens somewhere else and the agent works in the wrong directory. Silent, and
/// only noticed after the agent has done something.
final class TaskCWDTests: XCTestCase {
    func testTildeIsExpanded() {
        let home = NSHomeDirectory()
        XCTAssertEqual(CrewTask(name: "a", cwd: "~/dev/api").resolvedCWD, "\(home)/dev/api")
        XCTAssertEqual(CrewTask(name: "a", cwd: "~").resolvedCWD, home)
    }

    func testAbsoluteAndRelativePathsPassThrough() {
        XCTAssertEqual(CrewTask(name: "a", cwd: "/tmp/x").resolvedCWD, "/tmp/x")
        XCTAssertEqual(CrewTask(name: "a", cwd: "./sub").resolvedCWD, "./sub")
    }

    func testNoCWDStaysNil() {
        XCTAssertNil(CrewTask(name: "a").resolvedCWD)
        XCTAssertNil(CrewTask(name: "a", cwd: "").resolvedCWD)
    }
}
