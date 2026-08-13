import DamsonTerminal
import XCTest
@testable import DamsonAgents

/// What damson puts on the command line is the whole contract with Claude Code, so these
/// pin the parts other stages depend on — chiefly that damson mints the session id, which
/// is what makes a later `--resume` able to reattach a pane to its own transcript.
final class AgentLaunchTests: XCTestCase {

    private func base() -> DamsonConfig {
        var c = DamsonConfig()
        c.env = ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"]
        c.cwd = "/somewhere/else"
        return c
    }

    func testPassesTheSessionIDDamsonMinted() {
        let id = UUID()
        let argv = AgentLaunch.config(base: base(), cwd: "/p", sessionID: id, label: nil).argv
        guard let i = argv.firstIndex(of: "--session-id") else {
            return XCTFail("no --session-id in \(argv)")
        }
        XCTAssertEqual(argv[i + 1], id.uuidString,
                       "Claude Code must be told the id damson chose, or --resume can't find it")
    }

    func testLabelIsPassedOnlyWhenPresent() {
        let withLabel = AgentLaunch.config(base: base(), cwd: "/p", sessionID: UUID(), label: "damson").argv
        guard let i = withLabel.firstIndex(of: "--name") else { return XCTFail("no --name") }
        XCTAssertEqual(withLabel[i + 1], "damson")

        for empty in [nil, ""] as [String?] {
            let argv = AgentLaunch.config(base: base(), cwd: "/p", sessionID: UUID(), label: empty).argv
            XCTAssertFalse(argv.contains("--name"), "an empty label must not become a bare --name")
        }
    }

    func testCwdOverridesTheBaseAndNilKeepsIt() {
        XCTAssertEqual(AgentLaunch.config(base: base(), cwd: "/p", sessionID: UUID(), label: nil).cwd, "/p")
        XCTAssertEqual(AgentLaunch.config(base: base(), cwd: nil, sessionID: UUID(), label: nil).cwd,
                       "/somewhere/else")
    }

    /// The base config carries the user's font/theme/env; an agent pane is an ordinary pane
    /// in every respect except what it runs.
    func testBaseConfigIsOtherwisePreserved() {
        var b = base()
        b.scrollbackLines = 12_345
        let c = AgentLaunch.config(base: b, cwd: nil, sessionID: UUID(), label: nil)
        XCTAssertEqual(c.scrollbackLines, 12_345)
        XCTAssertEqual(c.env["TERM"], "xterm-256color")
    }

    /// argv[0] must be an absolute path: a GUI launch has a minimal PATH (LaunchServices
    /// does not run a login shell), so a bare "claude" would resolve differently — or not
    /// at all — depending on how damson was started.
    func testExecutableIsResolvedToAPathWhenOneExists() {
        let exe = AgentLaunch.claudeExecutable(env: ["PATH": "/usr/bin:/bin"])
        if exe != "claude" {
            XCTAssertTrue(exe.hasPrefix("/"), "expected an absolute path, got \(exe)")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: exe))
        }
    }

    func testExecutableFallsBackToPATHLookup() throws {
        // A directory we control, containing something executable named `claude`.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentlaunch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("claude").path
        FileManager.default.createFile(atPath: fake, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])

        // Only meaningful when there is no real install shadowing it.
        let real = AgentLaunch.claudeExecutable(env: [:])
        try XCTSkipIf(real != "claude", "a real claude install takes precedence by design")
        XCTAssertEqual(AgentLaunch.claudeExecutable(env: ["PATH": dir.path]), fake)
        XCTAssertTrue(AgentLaunch.isAvailable(env: ["PATH": dir.path]))
        XCTAssertFalse(AgentLaunch.isAvailable(env: ["PATH": "/nonexistent"]))
    }

    func testLabelIsTheDirectoryName() {
        XCTAssertEqual(AgentLaunch.label(for: "/Users/me/dev/damson"), "damson")
        XCTAssertEqual(AgentLaunch.label(for: "/Users/me/dev/damson/"), "damson")
        XCTAssertNil(AgentLaunch.label(for: nil))
        XCTAssertNil(AgentLaunch.label(for: ""))
    }
}
