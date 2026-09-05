import XCTest
@testable import DamsonTerminal

/// A damson launched from the Dock inherits LaunchServices' PATH — `/usr/bin:/bin:/usr/sbin:
/// /sbin` and nothing else. An interactive pane never notices, because it runs the user's
/// login shell and that shell rebuilds PATH from its own rc files. A program exec'd directly
/// into a pane gets the minimal PATH as-is, so `spawn -- claude` failed on every task with
/// "no executable named 'claude'" — on a normally launched app, with default settings.
///
/// It went unnoticed for weeks because every test instance was launched from a shell with
/// `open -n`, which passes the shell's full PATH through.
final class LoginEnvironmentTests: XCTestCase {

    // MARK: - Merging

    /// The login shell's entries win, in order; anything the process already had and the
    /// shell did not mention is kept after them, so nothing is lost.
    func testLoginEntriesComeFirstAndInheritedOnesAreKept() {
        let merged = LoginEnvironment.mergedPATH(login: "/opt/homebrew/bin:/usr/bin:/bin",
                                                 inherited: "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(merged, "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    func testDuplicatesAreDroppedKeepingTheFirst() {
        XCTAssertEqual(LoginEnvironment.mergedPATH(login: "/a:/b:/a", inherited: "/b:/c"),
                       "/a:/b:/c")
    }

    /// No probe result means the inherited PATH must come back untouched — never emptied.
    func testNoLoginPathLeavesInheritedAlone() {
        XCTAssertEqual(LoginEnvironment.mergedPATH(login: nil, inherited: "/usr/bin:/bin"),
                       "/usr/bin:/bin")
        XCTAssertEqual(LoginEnvironment.mergedPATH(login: "", inherited: "/usr/bin:/bin"),
                       "/usr/bin:/bin")
    }

    func testNothingAtAllFallsBackToTheSystemDefault() {
        XCTAssertEqual(LoginEnvironment.mergedPATH(login: nil, inherited: nil),
                       "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    /// Empty segments (`a::b`) are a classic way to put the current directory on PATH by
    /// accident. They are dropped.
    func testEmptySegmentsAreDropped() {
        XCTAssertEqual(LoginEnvironment.mergedPATH(login: "/a::/b:", inherited: nil), "/a:/b")
    }

    // MARK: - The probe

    /// Loose on purpose — it runs the real login shell, whose contents are the user's — but
    /// it must produce a PATH, it must include the basics, and it must finish.
    func testProbeReturnsAUsablePath() {
        let start = Date()
        let path = LoginEnvironment.probeLoginPATH(timeout: 8)
        XCTAssertLessThan(Date().timeIntervalSince(start), 8.5, "the probe did not respect its timeout")
        guard let path else { return XCTFail("no PATH came back from the login shell") }
        XCTAssertTrue(path.split(separator: ":").contains("/usr/bin"), path)
        XCTAssertFalse(path.contains("\n"), "took more than the last line: \(path.debugDescription)")
    }

    /// A shell that never answers must not hang the app. This one sleeps forever.
    func testAHungShellTimesOut() {
        let start = Date()
        let path = LoginEnvironment.probeLoginPATH(shell: "/bin/sh", arguments: ["-c", "sleep 30"], timeout: 1)
        XCTAssertNil(path)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}
