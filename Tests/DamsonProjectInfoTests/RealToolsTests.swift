import XCTest
@testable import DamsonProjectInfo

/// Against the machine's own git and lsof, so a change in their output is caught here
/// rather than in the panel. Skipped where git is not usable.
final class RealToolsTests: XCTestCase {
    private var root: URL!
    private let runner = ProbeRunner()

    override func setUpWithError() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("damson-summary-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        // git reports the physical path (/private/var/...), so compare against that.
        root = URL(fileURLWithPath: made.path.withCString { String(cString: realpath($0, nil)) })
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func gitPath() throws -> String {
        guard let git = ProjectSnapshot.gitExecutable(
            isExecutable: FileManager.default.isExecutableFile(atPath:),
            developerToolsInstalled: { ProjectSnapshot.developerToolsInstalled(runner: runner) }) else {
            throw XCTSkip("no usable git")
        }
        return git
    }

    @discardableResult
    private func sh(_ script: String) throws -> String {
        let result = runner.run("/bin/sh", ["-c", script])
        guard result.succeeded else { throw XCTSkip("fixture failed: \(result.stderr)") }
        return result.output
    }

    private func snapshot(_ folder: URL, git: String) -> ProjectSnapshot.Git {
        ProjectSnapshot.collect(folder: folder.path, processGroup: nil, git: git,
                                run: runner.run, groupExists: { _ in true }).git
    }

    func testRepositoryDetachedHeadWorktreeAndPlainFolder() throws {
        let git = try gitPath()
        let repo = root.appendingPathComponent("repo")
        let plain = root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try sh("""
        set -e; export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
        '\(git)' init -q -b audit '\(repo.path)'; cd '\(repo.path)'
        '\(git)' -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
        echo a > a; echo b > 'b c'; mkdir d; echo x > d/x
        '\(git)' add a; '\(git)' -c user.name=t -c user.email=t@t commit -q -m two
        echo changed >> a; '\(git)' mv a renamed
        '\(git)' worktree add -q --detach '\(root.path)/wt' HEAD
        """)
        guard case let .repository(top, branch, changes) = snapshot(repo, git: git) else {
            return XCTFail("\(snapshot(repo, git: git))")
        }
        XCTAssertEqual(top, repo.path)
        XCTAssertEqual(branch, .named("audit"))
        // renamed (staged rename, plus its worktree edit: one record), 'b c', d/
        XCTAssertEqual(changes, .count(3))

        guard case let .repository(wtTop, wtBranch, wtChanges) = snapshot(root.appendingPathComponent("wt"), git: git) else {
            return XCTFail("worktree")
        }
        XCTAssertEqual(wtTop, root.appendingPathComponent("wt").path)
        guard case .detached(let commit?) = wtBranch else { return XCTFail("\(wtBranch)") }
        XCTAssertFalse(commit.isEmpty)
        XCTAssertEqual(wtChanges, .count(0))

        XCTAssertEqual(snapshot(plain, git: git), .notRepository)
        XCTAssertEqual(snapshot(repo.appendingPathComponent(".git"), git: git), .notWorkTree)
    }

    /// The tty reports a process group; the listener belongs to a child of its leader,
    /// the `npm run dev` shape. `-p <group>` would find nothing here.
    func testListenerOfAChildInTheForegroundGroupIsFound() throws {
        let script = root.appendingPathComponent("serve.py")
        try """
        import os, socket, subprocess, sys, time
        os.setpgid(0, 0)
        child = subprocess.Popen([sys.executable, "-c",
            "import socket,time;s=socket.socket();s.bind(('127.0.0.1',0));s.listen();print(s.getsockname()[1],flush=True);time.sleep(30)"],
            stdout=subprocess.PIPE, text=True)
        print(os.getpgrp(), child.pid, child.stdout.readline().strip(), flush=True)
        time.sleep(30)
        """.write(to: script, atomically: true, encoding: .utf8)
        let leader = Process()
        leader.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        leader.arguments = [script.path]
        let pipe = Pipe()
        leader.standardOutput = pipe
        try leader.run()
        defer { kill(-leader.processIdentifier, SIGKILL); leader.terminate() }
        var line = Data()
        while !line.contains(UInt8(ascii: "\n")) {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { throw XCTSkip("fixture produced nothing") }
            line.append(chunk)
        }
        let fields = String(decoding: line, as: UTF8.self).split(separator: " ").map { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines))! }
        let (group, child, port) = (fields[0], fields[1], fields[2])

        let state = ProjectSnapshot.collect(folder: root.path, processGroup: group).listeners
        guard case let .listed(listedGroup, listeners) = state else { return XCTFail("\(state)") }
        XCTAssertEqual(listedGroup, group)
        XCTAssertEqual(listeners.map(\.address), ["127.0.0.1:\(port)"])
        XCTAssertEqual(listeners.first?.pid, child)
        XCTAssertEqual(ProjectSnapshot.browserCandidatePorts(listeners), [Int(port)])
    }
}
