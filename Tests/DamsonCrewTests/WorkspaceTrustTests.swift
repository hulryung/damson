import DamsonControl
import XCTest
@testable import DamsonCrew

/// Pre-accepting Claude Code's workspace-trust prompt for a worktree damson-crew just made.
///
/// This writes another product's config file, which is the reason for every guard below. The
/// file holds a user's whole Claude Code state — dozens of projects and more — so the bar is
/// not "usually works": a bad write here costs them something damson has no way to restore.
///
/// It is defensible at all only because the directory is a checkout of a repository the user
/// named, created seconds earlier by damson-crew itself. It is not an unknown folder.
final class WorkspaceTrustTests: XCTestCase {

    private var dir: URL!
    private var config: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("damson-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        config = dir.appendingPathComponent("claude.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ json: String) throws {
        try json.write(to: config, atomically: true, encoding: .utf8)
    }

    private func read() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any] ?? [:]
    }

    // MARK: - The happy path

    func testItAcceptsTrustForThePath() throws {
        try write(#"{"projects":{}}"#)
        let changed = try WorkspaceTrust.accept(path: "/w/tree", configPath: config.path).get()
        XCTAssertTrue(changed)
        let projects = try XCTUnwrap(read()["projects"] as? [String: Any])
        let entry = try XCTUnwrap(projects["/w/tree"] as? [String: Any])
        XCTAssertEqual(entry["hasTrustDialogAccepted"] as? Bool, true)
    }

    /// Everything else in the file must come back untouched — other projects, their settings,
    /// and any top-level state this code knows nothing about.
    func testEverythingElseIsPreserved() throws {
        try write("""
        {"numStartups":41,"userID":"abc",
         "projects":{"/other":{"hasTrustDialogAccepted":false,"allowedTools":["Bash"],"lastCost":1.5}},
         "someFutureKey":{"nested":[1,2,3]}}
        """)
        _ = try WorkspaceTrust.accept(path: "/w/tree", configPath: config.path).get()
        let d = try read()
        XCTAssertEqual(d["numStartups"] as? Int, 41)
        XCTAssertEqual(d["userID"] as? String, "abc")
        XCTAssertNotNil(d["someFutureKey"])
        let other = try XCTUnwrap((d["projects"] as? [String: Any])?["/other"] as? [String: Any])
        XCTAssertEqual(other["hasTrustDialogAccepted"] as? Bool, false,
                       "another project's trust decision was changed")
        XCTAssertEqual(other["allowedTools"] as? [String], ["Bash"])
        XCTAssertEqual(other["lastCost"] as? Double, 1.5)
    }

    /// An existing entry keeps its other settings; only the one flag is set.
    func testAnExistingEntryKeepsItsOtherSettings() throws {
        try write(#"{"projects":{"/w/tree":{"allowedTools":["Read"],"hasTrustDialogAccepted":false}}}"#)
        _ = try WorkspaceTrust.accept(path: "/w/tree", configPath: config.path).get()
        let entry = try XCTUnwrap((read()["projects"] as? [String: Any])?["/w/tree"] as? [String: Any])
        XCTAssertEqual(entry["hasTrustDialogAccepted"] as? Bool, true)
        XCTAssertEqual(entry["allowedTools"] as? [String], ["Read"])
    }

    func testItIsIdempotentAndReportsNoChange() throws {
        try write(#"{"projects":{"/w/tree":{"hasTrustDialogAccepted":true}}}"#)
        XCTAssertFalse(try WorkspaceTrust.accept(path: "/w/tree", configPath: config.path).get())
    }

    // MARK: - Refusing to make things worse

    /// No config means Claude Code has never run here. Creating one would be damson
    /// inventing another product's state file from scratch.
    func testAMissingConfigIsLeftAlone() throws {
        let missing = dir.appendingPathComponent("nope.json").path
        guard case .failure = WorkspaceTrust.accept(path: "/w/tree", configPath: missing) else {
            return XCTFail("it wrote a config that did not exist")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing))
    }

    /// If the file cannot be parsed, something is already wrong or the format has moved.
    /// Rewriting it from a partial understanding is how a config gets destroyed.
    func testAnUnparseableConfigIsLeftByteForByteAlone() throws {
        let original = "{ this is not json"
        try write(original)
        guard case .failure = WorkspaceTrust.accept(path: "/w/tree", configPath: config.path) else {
            return XCTFail("it rewrote a file it could not read")
        }
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), original)
    }

    /// A file whose shape is not what this expects — `projects` not an object — is equally
    /// off limits.
    func testAnUnexpectedShapeIsLeftAlone() throws {
        let original = #"{"projects":[1,2,3]}"#
        try write(original)
        guard case .failure = WorkspaceTrust.accept(path: "/w/tree", configPath: config.path) else {
            return XCTFail("it wrote over a shape it did not understand")
        }
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), original)
    }

    /// A backup is kept, because the alternative to a bad write is otherwise nothing.
    func testABackupIsWrittenBeforeTheFirstChange() throws {
        try write(#"{"projects":{},"userID":"abc"}"#)
        _ = try WorkspaceTrust.accept(path: "/w/tree", configPath: config.path).get()
        let backup = config.path + WorkspaceTrust.backupSuffix
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup), "no backup was kept")
        let restored = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: backup))) as? [String: Any]
        XCTAssertEqual(restored?["userID"] as? String, "abc")
        XCTAssertTrue((restored?["projects"] as? [String: Any])?.isEmpty ?? false,
                      "the backup should be the state from BEFORE the change")
    }

    /// An empty or relative path is not a workspace. Writing one would put a junk entry in
    /// the user's config that nothing ever cleans up.
    func testOnlyAbsolutePathsAreAccepted() throws {
        try write(#"{"projects":{}}"#)
        for bad in ["", "   ", "relative/path"] {
            guard case .failure = WorkspaceTrust.accept(path: bad, configPath: config.path) else {
                return XCTFail("accepted \(bad.debugDescription)")
            }
        }
        XCTAssertTrue((try read()["projects"] as? [String: Any])?.isEmpty ?? false)
    }
}

/// When the coordinator does and does not pre-accept trust.
final class TrustOnlyNewWorktreesTests: XCTestCase {
    private final class FakeGit: GitRunner {
        var worktreeList = "worktree /repo\nHEAD abc\nbranch refs/heads/main\n\n"
        var commands: [[String]] = []
        func run(_ args: [String]) -> Result<String, CrewError> {
            commands.append(args)
            if args.contains("list") { return .success(worktreeList) }
            return .success("")
        }
    }
    private final class FakeDamson: DamsonClient {
        func send(_ kind: ControlCommandKind, target: PaneTarget) -> Result<ControlResponse, CrewError> {
            .success(.pane(PaneInfo(index: 0, cols: 80, rows: 24, active: false, id: "A")))
        }
    }

    /// `ensureWorktree` checks the repo really exists before running git, so the fake needs
    /// a real directory to stand on.
    private func run(existingBranch: Bool, trustEnabled: Bool) throws -> [String] {
        let repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("damson-trustco-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        // The manager reports realpath'd paths (Foundation leaves /var/folders alone), so
        // the assertions below match on shape rather than on an exact string.
        let root = repo.path + "-worktrees"

        let git = FakeGit()
        if existingBranch {
            git.worktreeList += "worktree \(root)/feat\nHEAD abc\nbranch refs/heads/feat\n\n"
        }
        var trusted: [String] = []
        let coordinator = Coordinator(
            client: FakeDamson(), skipPermissions: false, trustNewWorktrees: trustEnabled,
            worktrees: WorktreeManager(git: git, rootFor: { $0 + "-worktrees" }),
            acceptTrust: { trusted.append($0); return .success(true) })
        _ = coordinator.fanOut([CrewTask(name: "t", repo: repo.path, branch: "feat")], group: nil)
        try? FileManager.default.removeItem(atPath: root)
        return trusted
    }

    func testANewWorktreeIsTrusted() throws {
        let trusted = try run(existingBranch: false, trustEnabled: true)
        XCTAssertEqual(trusted.count, 1)
        XCTAssertTrue(trusted[0].hasSuffix("-worktrees/feat"), trusted[0])
        XCTAssertTrue(trusted[0].hasPrefix("/"), "an absolute path is required")
    }

    /// A reused worktree was either trusted already or declined once. Deciding again would
    /// silently overturn the user's answer.
    func testAReusedWorktreeIsNotTouched() throws {
        XCTAssertEqual(try run(existingBranch: true, trustEnabled: true), [])
    }

    func testNothingHappensWhenTheSettingIsOff() throws {
        XCTAssertEqual(try run(existingBranch: false, trustEnabled: false), [])
    }
}
