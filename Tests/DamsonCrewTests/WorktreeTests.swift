import XCTest
@testable import DamsonCrew

/// Worktrees are made by the coordinator rather than left to the agent, because support for
/// them is per-tool and inconsistent — `claude -w`, `grok --worktree=<name>`, nothing at all
/// in `codex` or `cursor-agent`. All any of them needs is to start in the right directory.
///
/// These run against a **real repository**: the interesting behaviour is git's, and a fake
/// that agreed with my idea of git would prove nothing.
final class WorktreeIntegrationTests: XCTestCase {

    private var repo: URL!
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("damson-wt-\(UUID().uuidString)")
        repo = scratch.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = SystemGit()
        for args in [["-C", repo.path, "init", "-b", "main"],
                     ["-C", repo.path, "config", "user.email", "t@example.com"],
                     ["-C", repo.path, "config", "user.name", "T"]] {
            _ = try git.run(args).get()
        }
        try Data("hello\n".utf8).write(to: repo.appendingPathComponent("README"))
        _ = try git.run(["-C", repo.path, "add", "."]).get()
        _ = try git.run(["-C", repo.path, "commit", "-m", "init"]).get()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func manager() -> WorktreeManager { WorktreeManager() }

    func testEnsureCreatesAWorktreeOnANewBranch() throws {
        let path = try manager().ensure(repo: repo.path, branch: "agent/review", base: nil).get()
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        // A branch with a slash must not become a nested directory.
        XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, "agent-review")
        // …and it lives beside the repo, not inside it, so it stays out of the repo's own
        // status and file searches.
        XCTAssertFalse(path.hasPrefix(repo.path + "/"))
    }

    /// Re-running a task list must reattach to the worktree it made last time, not fail and
    /// not make a second one under a mangled name.
    func testEnsureIsIdempotent() throws {
        let m = manager()
        let first = try m.ensure(repo: repo.path, branch: "agent/review", base: nil).get()
        let second = try m.ensure(repo: repo.path, branch: "agent/review", base: nil).get()
        XCTAssertEqual(first, second)
        let listed = try m.list(repo: repo.path).get()
        XCTAssertEqual(listed.filter { $0.branch == "agent/review" }.count, 1)
    }

    /// A branch someone already made by hand is checked out rather than rejected.
    func testEnsureChecksOutAnExistingBranch() throws {
        _ = try SystemGit().run(["-C", repo.path, "branch", "existing"]).get()
        let path = try manager().ensure(repo: repo.path, branch: "existing", base: nil).get()
        let listed = try manager().list(repo: repo.path).get()
        XCTAssertTrue(listed.contains { $0.path == path && $0.branch == "existing" })
    }

    func testEnsureBranchesFromTheGivenBase() throws {
        let git = SystemGit()
        _ = try git.run(["-C", repo.path, "checkout", "-b", "other"]).get()
        try Data("2\n".utf8).write(to: repo.appendingPathComponent("SECOND"))
        _ = try git.run(["-C", repo.path, "add", "."]).get()
        _ = try git.run(["-C", repo.path, "commit", "-m", "second"]).get()
        _ = try git.run(["-C", repo.path, "checkout", "main"]).get()

        let path = try manager().ensure(repo: repo.path, branch: "from-other", base: "other").get()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: path).appendingPathComponent("SECOND").path),
            "the worktree was not branched from `base`")
    }

    func testAMissingRepoIsReported() {
        guard case .failure(let e) = manager().ensure(
            repo: scratch.appendingPathComponent("nope").path, branch: "b", base: nil) else {
            return XCTFail("a missing repo was accepted")
        }
        XCTAssertTrue(e.message.contains("no such repository"), e.message)
    }

    func testADirectoryThatIsNotARepoIsReported() throws {
        let plain = scratch.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        guard case .failure(let e) = manager().ensure(repo: plain.path, branch: "b", base: nil) else {
            return XCTFail("a non-repo was accepted")
        }
        XCTAssertTrue(e.message.contains("not a git repository"), e.message)
    }

    // MARK: - Removal

    func testRemoveTakesAwayACleanWorktree() throws {
        let m = manager()
        let path = try m.ensure(repo: repo.path, branch: "temp", base: nil).get()
        XCTAssertNoThrow(try m.remove(repo: repo.path, path: path).get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// The safety property this whole design rests on: the contents are an agent's work, and
    /// it is uncommitted exactly when losing it would matter most. `git worktree remove`
    /// refuses a dirty tree and we never pass `--force`, so teardown cannot destroy it.
    func testRemoveRefusesToDestroyUncommittedWork() throws {
        let m = manager()
        let path = try m.ensure(repo: repo.path, branch: "dirty", base: nil).get()
        try Data("work in progress\n".utf8)
            .write(to: URL(fileURLWithPath: path).appendingPathComponent("NOTES"))

        guard case .failure = m.remove(repo: repo.path, path: path) else {
            return XCTFail("teardown destroyed uncommitted work")
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: path).appendingPathComponent("NOTES").path))
    }
}

/// Parsing `git worktree list --porcelain`, against real output shapes.
final class WorktreeParseTests: XCTestCase {
    func testParsesPathsAndBranches() {
        let text = """
        worktree /Users/x/dev/proj
        HEAD abc123
        branch refs/heads/main

        worktree /Users/x/dev/proj-worktrees/agent-review
        HEAD def456
        branch refs/heads/agent/review

        """
        let out = WorktreeManager.parseList(text)
        XCTAssertEqual(out.map(\.branch), ["main", "agent/review"])
        XCTAssertEqual(out.last?.path, "/Users/x/dev/proj-worktrees/agent-review")
    }

    /// A detached worktree has no `branch` line at all; it must still be listed, or the
    /// idempotency check would think its path is free and try to reuse it.
    func testADetachedWorktreeIsListedWithNoBranch() {
        let out = WorktreeManager.parseList("""
        worktree /Users/x/dev/proj
        HEAD abc123
        detached

        """)
        XCTAssertEqual(out.count, 1)
        XCTAssertNil(out[0].branch)
    }

    func testSlugKeepsBranchesToOneDirectoryComponent() {
        XCTAssertEqual(WorktreeManager.slug("agent/review-api"), "agent-review-api")
        XCTAssertEqual(WorktreeManager.slug("feat/a/b"), "feat-a-b")
        XCTAssertEqual(WorktreeManager.slug("plain"), "plain")
        XCTAssertFalse(WorktreeManager.slug("/").contains("/"))
    }

    func testDefaultRootSitsBesideTheRepo() {
        XCTAssertEqual(WorktreeManager.defaultRoot(repo: "/Users/x/dev/proj"),
                       "/Users/x/dev/proj-worktrees")
    }
}
