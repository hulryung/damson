import XCTest
@testable import DamsonOrchestrator

final class WorktreeManagerTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("damson-wt-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Run a git command directly to build the fixture repo.
    @discardableResult
    private func git(_ args: [String], cwd: URL) throws -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        proc.currentDirectoryURL = cwd
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    private func makeRepo() throws -> URL {
        let repo = tmp.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try XCTSkipIf(FileManager.default.isExecutableFile(atPath: "/usr/bin/git") == false, "git unavailable")
        XCTAssertEqual(try git(["init", "-q"], cwd: repo), 0)
        try git(["config", "user.email", "test@damson.app"], cwd: repo)
        try git(["config", "user.name", "Test"], cwd: repo)
        try "hello".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try git(["add", "."], cwd: repo), 0)
        XCTAssertEqual(try git(["commit", "-q", "-m", "init"], cwd: repo), 0)
        return repo
    }

    func testFullLifecycle() throws {
        let repo = try makeRepo()
        let mgr = WorktreeManager(root: tmp.appendingPathComponent("worktrees"))

        let base = try mgr.detectBaseRepo(from: repo)
        XCTAssertEqual(base.resolvingSymlinksInPath(), repo.resolvingSymlinksInPath())

        try mgr.validateReady(base)
        let ref = try mgr.resolveRef("HEAD", in: base)
        XCTAssertEqual(ref.count, 40)

        let wt = try mgr.create(base: base, branch: "orchestrator/test/fix-bug", from: ref)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.path.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.path.appendingPathComponent("README.md").path))

        let listed = try mgr.list(base: base)
        XCTAssertTrue(listed.contains { $0.contains(wt.path.lastPathComponent) })

        XCTAssertTrue(try mgr.remove(wt))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt.path.path))
    }

    func testDirtyWorktreePreservedWithoutForce() throws {
        let repo = try makeRepo()
        let mgr = WorktreeManager(root: tmp.appendingPathComponent("worktrees"))
        let base = try mgr.detectBaseRepo(from: repo)
        let ref = try mgr.resolveRef("HEAD", in: base)
        let wt = try mgr.create(base: base, branch: "orchestrator/test/dirty", from: ref)

        // Make it dirty.
        try "uncommitted".write(to: wt.path.appendingPathComponent("scratch.txt"),
                                atomically: true, encoding: .utf8)

        // Non-force remove should refuse (return false) and keep the worktree.
        XCTAssertFalse(try mgr.remove(wt, force: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.path.path))

        // Force removes it.
        XCTAssertTrue(try mgr.remove(wt, force: true))
    }

    func testDetectBaseRepoFailsOutsideRepo() throws {
        let mgr = WorktreeManager(root: tmp.appendingPathComponent("worktrees"))
        let notRepo = tmp.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: notRepo, withIntermediateDirectories: true)
        XCTAssertThrowsError(try mgr.detectBaseRepo(from: notRepo))
    }
}
