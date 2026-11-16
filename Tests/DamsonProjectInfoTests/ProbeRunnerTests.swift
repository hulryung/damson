import XCTest
@testable import DamsonProjectInfo

/// Real processes: the runner's whole job is surviving the ones that misbehave.
final class ProbeRunnerTests: XCTestCase {
    func testSeparatesStdoutFromStderr() {
        let result = ProbeRunner().run("/bin/sh", ["-c", "printf 'out'; printf 'warning: x\\n' >&2; exit 3"])
        XCTAssertEqual(result.outcome, .exited(3))
        XCTAssertEqual(result.output, "out")
        XCTAssertEqual(result.stderr, "warning: x\n")
        XCTAssertEqual(result.failureReason, "warning: x")
    }

    func testDeadlineKillsAHungChild() {
        let started = Date()
        let result = ProbeRunner(timeout: 0.5).run("/bin/sleep", ["30"])
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    /// A child that ignores SIGTERM is killed; a grandchild still holding the pipe does not
    /// hold the caller hostage waiting for EOF.
    func testDeadlineDoesNotWaitForEOFHeldByAGrandchild() {
        let started = Date()
        let result = ProbeRunner(timeout: 0.5).run("/bin/sh", ["-c", "trap '' TERM; /bin/sleep 5 & /bin/sleep 30"])
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testOutputCapStopsTheChild() {
        let started = Date()
        let result = ProbeRunner(timeout: 10, outputCap: 10_000).run("/usr/bin/yes", [])
        XCTAssertEqual(result.outcome, .truncated)
        XCTAssertEqual(result.stdout.count, 10_000)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testLargeOutputBelowTheCapIsComplete() {
        let result = ProbeRunner().run("/bin/sh", ["-c", "/usr/bin/yes | /usr/bin/head -c 500000"])
        XCTAssertEqual(result.outcome, .exited(0))
        XCTAssertEqual(result.stdout.count, 500_000)
    }

    func testMissingExecutableIsALaunchFailure() {
        let result = ProbeRunner().run("/nonexistent/git", ["status"])
        guard case .launchFailed = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertTrue(result.failureReason.hasPrefix("could not run"))
    }
}
