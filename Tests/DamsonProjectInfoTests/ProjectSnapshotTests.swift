import XCTest
@testable import DamsonProjectInfo

final class ProjectSnapshotTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("damson-summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func exited(_ code: Int32, _ out: String = "", err: String = "") -> ProbeResult {
        ProbeResult(outcome: .exited(code), stdout: Data(out.utf8), stderr: err)
    }

    /// Answers by argument list; anything unexpected fails the test.
    private func fake(_ answers: [String: ProbeResult]) -> (String, [String]) -> ProbeResult {
        { executable, arguments in
            let key = arguments.filter { $0 != "-C" && $0 != self.folder.path }.joined(separator: " ")
            guard let answer = answers[key] else {
                XCTFail("unexpected \(executable) \(key)")
                return self.exited(128)
            }
            return answer
        }
    }

    private func git(_ answers: [String: ProbeResult], git: String? = "/usr/bin/git") -> ProjectSnapshot.Git {
        ProjectSnapshot.collect(folder: folder.path, processGroup: nil, git: git,
                                run: fake(answers), groupExists: { _ in true }).git
    }

    // MARK: Git

    func testNonRepositoryIsDistinguishedFromFailure() {
        XCTAssertEqual(git(["rev-parse --show-toplevel": exited(128, err: "fatal: not a git repository (or any of the parent directories): .git\n")]),
                       .notRepository)
        XCTAssertEqual(git(["rev-parse --show-toplevel": exited(128, err: "fatal: detected dubious ownership in repository at '/x'\nmore\n")]),
                       .failed("fatal: detected dubious ownership in repository at '/x'"))
        XCTAssertEqual(git(["rev-parse --show-toplevel": exited(128, err: "fatal: this operation must be run in a work tree\n")]),
                       .notWorkTree)
        XCTAssertEqual(git(["rev-parse --show-toplevel": ProbeResult(outcome: .timedOut)]), .failed("timed out"))
        // A timeout whose partial stderr happens to say "not a git repository" is still a failure.
        XCTAssertEqual(git(["rev-parse --show-toplevel": ProbeResult(outcome: .timedOut, stderr: "not a git repository")]),
                       .failed("timed out"))
    }

    func testMissingGitAndMissingFolder() {
        XCTAssertEqual(git([:], git: nil), .gitMissing)
        let gone = ProjectSnapshot.collect(folder: folder.appendingPathComponent("nope").path, processGroup: nil,
                                           git: "/usr/bin/git", run: fake([:]), groupExists: { _ in true })
        XCTAssertEqual(gone.git, .folderMissing)
        XCTAssertTrue(gone.render().contains("folder no longer exists"))
    }

    func testGitLocatorNeverUsesTheShimWithoutDeveloperTools() {
        var asked = false
        let none = ProjectSnapshot.gitExecutable(isExecutable: { $0 == "/usr/bin/git" },
                                                 developerToolsInstalled: { asked = true; return false })
        XCTAssertNil(none)
        XCTAssertTrue(asked)
        XCTAssertEqual(ProjectSnapshot.gitExecutable(isExecutable: { _ in true }, developerToolsInstalled: { false }),
                       "/opt/homebrew/bin/git")
        XCTAssertEqual(ProjectSnapshot.gitExecutable(isExecutable: { _ in true }, developerToolsInstalled: { true }),
                       "/usr/bin/git")
    }

    func testDetachedHeadAndStatusFailures() {
        let state = git([
            "rev-parse --show-toplevel": exited(0, "/repo\n"),
            "branch --show-current": exited(0, "\n"),
            "rev-parse --short HEAD": exited(0, "abc1234\n"),
            "status --porcelain=v1 -z": ProbeResult(outcome: .timedOut),
        ])
        XCTAssertEqual(state, .repository(root: "/repo", branch: .detached(commit: "abc1234"), changes: .unavailable("timed out")))
        let text = ProjectSnapshot(folder: "/repo", git: state, listeners: .ownershipUnknown).render()
        XCTAssertTrue(text.contains("Branch: detached HEAD at abc1234"))
        XCTAssertTrue(text.contains("Changed files: unavailable (timed out)"))
    }

    func testPorcelainCountsRenamesOnceAndIgnoresStderr() {
        let z = "R  new name\0old name\0 M a.swift\0?? dir/\0C  copy\0orig\0"
        XCTAssertEqual(ProjectSnapshot.changedPathCount(porcelainZ: Data(z.utf8), complete: true), 4)
        XCTAssertEqual(ProjectSnapshot.changedPathCount(porcelainZ: Data(), complete: true), 0)
        // Cut mid-record: the partial record is not counted.
        XCTAssertEqual(ProjectSnapshot.changedPathCount(porcelainZ: Data(" M a\0 M b\0 M c".utf8), complete: false), 2)
        let state = git([
            "rev-parse --show-toplevel": exited(0, "/repo\n"),
            "branch --show-current": exited(0, "main\n"),
            "status --porcelain=v1 -z": exited(0, " M a\0", err: "warning: could not open directory 'x/': Permission denied\n"),
        ])
        XCTAssertEqual(state, .repository(root: "/repo", branch: .named("main"), changes: .count(1)))
        let truncated = git([
            "rev-parse --show-toplevel": exited(0, "/repo\n"),
            "branch --show-current": exited(0, "main\n"),
            "status --porcelain=v1 -z": ProbeResult(outcome: .truncated, stdout: Data("?? a\0?? b\0?? c".utf8)),
        ])
        XCTAssertEqual(truncated, .repository(root: "/repo", branch: .named("main"), changes: .atLeast(2)))
    }

    // MARK: Listeners

    func testLsofFieldParsingKeepsOwnerPerSocket() {
        let output = "p100\ncnpm\np101\ncnode\nf23\nn*:3000\nf24\nn127.0.0.1:9229\nf25\nn*:3000\nf26\nn192.168.1.5:8080\nf27\nn[::1]:5173\n"
        let listeners = ProjectSnapshot.parseLsof(output)
        XCTAssertEqual(listeners, [
            .init(pid: 101, command: "node", address: "*:3000"),
            .init(pid: 101, command: "node", address: "127.0.0.1:9229"),
            .init(pid: 101, command: "node", address: "192.168.1.5:8080"),
            .init(pid: 101, command: "node", address: "[::1]:5173"),
        ])
        // A LAN-only bind is listed but not offered as a localhost link.
        XCTAssertEqual(ProjectSnapshot.browserCandidatePorts(listeners), [3000, 5173, 9229])
    }

    func testListenersOnlyWithKnownOwnership() {
        func listeners(_ group: Int32?, alive: Bool = true, _ answer: ProbeResult? = nil) -> ProjectSnapshot.Listeners {
            ProjectSnapshot.collect(folder: folder.path, processGroup: group, git: nil, run: { executable, arguments in
                XCTAssertEqual(executable, "/usr/sbin/lsof")
                XCTAssertEqual(Array(arguments.prefix(4)), ["-nP", "-a", "-g", String(group ?? 0)])
                return answer ?? self.exited(1)
            }, groupExists: { _ in alive }).listeners
        }
        XCTAssertEqual(listeners(nil), .ownershipUnknown)
        XCTAssertEqual(listeners(0), .ownershipUnknown)
        XCTAssertEqual(listeners(7, alive: false), .processGone(group: 7))
        XCTAssertEqual(listeners(7, exited(1)), .listed(group: 7, []))
        XCTAssertEqual(listeners(7, exited(1, err: "lsof: illegal option")), .unavailable(group: 7, "lsof: illegal option"))
        XCTAssertEqual(listeners(7, ProbeResult(outcome: .timedOut)), .unavailable(group: 7, "timed out"))
        XCTAssertEqual(listeners(7, exited(1, err: "lsof: WARNING: can't stat() smbfs file system /Volumes/x\n")),
                       .listed(group: 7, []))

        let unknown = ProjectSnapshot(folder: "/f", git: .notRepository, listeners: .ownershipUnknown).render()
        XCTAssertFalse(unknown.contains("http://"))
        let gone = ProjectSnapshot(folder: "/f", git: .notRepository, listeners: .processGone(group: 7)).render()
        XCTAssertFalse(gone.contains("http://"))
        let listed = ProjectSnapshot(folder: "/f", git: .notRepository,
                                     listeners: .listed(group: 7, [.init(pid: 8, command: "node", address: "*:3000")])).render()
        XCTAssertTrue(listed.contains("http://localhost:3000"))
        XCTAssertTrue(listed.contains("node 8"))
    }
}
