import Darwin
import XCTest
@testable import DamsonTerminal

/// A spawn whose working directory cannot be entered used to succeed. `chdir` runs in the
/// child after `forkpty` and its result was discarded, so the program ran in whatever the
/// app inherited — `/` in practice — while `spawn` answered ok and echoed back the path that
/// had been asked for. Nothing anywhere said otherwise.
///
/// That is the worst shape a failure can take for the thing a cwd is actually for: a
/// coordinator opening an agent per worktree gets an agent working against the wrong tree,
/// and reading the value back confirms the placement that never happened.
final class SpawnCWDTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("damson-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Restore permissions first: a 0o000 directory cannot be removed by its own contents.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch.path)
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - The check itself

    func testAnOrdinaryDirectoryHasNoProblem() {
        XCTAssertNil(PTYHost.cwdProblem(scratch.path))
        XCTAssertNil(PTYHost.cwdProblem("/"))
    }

    func testAMissingPathIsReported() {
        let problem = PTYHost.cwdProblem(scratch.appendingPathComponent("nope").path)
        XCTAssertNotNil(problem)
    }

    /// `stat` succeeds on a file, so a check that only asked "does this exist" would pass it
    /// and then `chdir` would fail in the child, which is exactly the case being fixed.
    func testAFileIsReportedAsNotADirectory() throws {
        let file = scratch.appendingPathComponent("a-file")
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(PTYHost.cwdProblem(file.path), "not a directory")
    }

    /// Entering a directory needs execute permission, not read permission.
    func testADirectoryWithoutExecutePermissionIsReported() throws {
        let locked = scratch.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        // Running as root would make this pass regardless; skip rather than assert a lie.
        try XCTSkipIf(getuid() == 0, "root can enter any directory")
        XCTAssertNotNil(PTYHost.cwdProblem(locked.path))
    }

    // MARK: - Spawning

    func testSpawnRefusesAnUnusableCWDAndStartsNothing() {
        let pty = PTYHost()
        let missing = scratch.appendingPathComponent("nope").path
        XCTAssertThrowsError(try pty.spawn(argv: ["/bin/sh", "-c", "sleep 5"],
                                           env: ["PATH": "/usr/bin:/bin"],
                                           cwd: missing, cols: 80, rows: 24)) { error in
            guard case PTYHost.SpawnError.cwdUnusable(let path, _)? =
                    error as? PTYHost.SpawnError else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(path, missing)
        }
        // Nothing was forked, so there is no child to reap and no pty to leak.
        XCTAssertEqual(pty.childPID, -1)
        XCTAssertEqual(pty.primaryFD, -1)
        pty.terminate()
    }

    func testSpawnRefusesAFileAsCWD() throws {
        let file = scratch.appendingPathComponent("a-file")
        try Data("x".utf8).write(to: file)
        let pty = PTYHost()
        XCTAssertThrowsError(try pty.spawn(argv: ["/bin/sh", "-c", "sleep 5"],
                                           env: ["PATH": "/usr/bin:/bin"],
                                           cwd: file.path, cols: 80, rows: 24))
        pty.terminate()
    }

    /// The whole point: a good cwd must still be honoured, and the child must really be in it.
    func testAGoodCWDStillWorksAndTheChildIsActuallyThere() throws {
        let pty = PTYHost()
        var received = Data()
        pty.onData = { received.append($0) }
        try pty.spawn(argv: ["/bin/sh", "-c", "pwd; sleep 5"],
                      env: ["PATH": "/usr/bin:/bin"],
                      cwd: scratch.path, cols: 80, rows: 24)
        defer { pty.terminate() }

        let deadline = Date().addingTimeInterval(10)
        while received.isEmpty && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        let printed = String(decoding: received, as: UTF8.self)
        // /var and /private/var are the same place; compare what the child resolved.
        let resolved = URL(fileURLWithPath: scratch.path).resolvingSymlinksInPath().path
        XCTAssertTrue(printed.contains(resolved) || printed.contains(scratch.path),
                      "child ran somewhere else: \(printed)")
    }

    /// No cwd means inherit, exactly as before — the overwhelmingly common case.
    func testNoCWDStillInherits() throws {
        let pty = PTYHost()
        try pty.spawn(argv: ["/bin/sh", "-c", "sleep 5"],
                      env: ["PATH": "/usr/bin:/bin"], cwd: nil, cols: 80, rows: 24)
        XCTAssertGreaterThan(pty.childPID, 0)
        pty.terminate()
    }

    /// A directory deleted between the parent's check and the child's `chdir` cannot be
    /// prevented, so the child refuses to exec rather than running somewhere else. The pane
    /// visibly fails to open, which is far better than an agent editing the wrong tree.
    func testTheChildRefusesToExecIfCHDIRFailsAnyway() throws {
        let doomed = scratch.appendingPathComponent("doomed")
        try FileManager.default.createDirectory(at: doomed, withIntermediateDirectories: true)

        let pty = PTYHost()
        var exitCode: Int32?
        pty.onExit = { exitCode = $0 }
        // Passes the parent check…
        XCTAssertNil(PTYHost.cwdProblem(doomed.path))
        // …then loses the directory before the child gets there. This races the fork, so it
        // is asserted loosely: whatever happens, the child must not end up running elsewhere.
        try FileManager.default.removeItem(at: doomed)
        do {
            try pty.spawn(argv: ["/bin/sh", "-c", "sleep 5"],
                          env: ["PATH": "/usr/bin:/bin"],
                          cwd: doomed.path, cols: 80, rows: 24)
        } catch {
            return   // the parent noticed first; equally correct
        }
        defer { pty.terminate() }
        let deadline = Date().addingTimeInterval(10)
        while exitCode == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(exitCode, 126, "the child exec'd despite chdir failing")
    }
}
