@testable import DamsonTerminal
import XCTest

/// How each shell is launched. That the shells then behave is checked against real shells
/// on a PTY by `scripts/test-shell-integration.py`.
final class ShellIntegrationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("damson-shell-integration-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func prepare(_ argv: [String], env: [String: String] = ["PATH": "/usr/bin:/bin"],
                         bash: Int? = 5) -> (argv: [String], env: [String: String]) {
        ShellIntegration.prepare(argv: argv, env: env, root: root, bashMajorVersion: { _ in bash })
    }

    func testZshGetsZdotdirAndKeepsItsArgv() {
        let out = prepare(["/bin/zsh", "-l"])
        XCTAssertEqual(out.argv, ["/bin/zsh", "-l"])
        XCTAssertEqual(out.env["ZDOTDIR"], root.appendingPathComponent("zsh").path)
        let zshrc = root.appendingPathComponent("zsh/.zshrc")
        XCTAssertTrue((try? String(contentsOf: zshrc, encoding: .utf8))?.contains("_damson_precmd") == true)
    }

    func testModernBashKeepsLoginAndReadsTheScriptThroughEnv() {
        let out = prepare(["/opt/homebrew/bin/bash", "-l"], env: ["PATH": "/usr/bin", "ENV": "/mine"])
        XCTAssertEqual(out.argv, ["/opt/homebrew/bin/bash", "--posix", "-l"])
        XCTAssertEqual(out.env["ENV"], root.appendingPathComponent("bash/damson.bash").path)
        XCTAssertEqual(out.env["DAMSON_BASH_ENV"], "/mine", "the user's ENV must be restorable")
        XCTAssertEqual(out.env["DAMSON_BASH_INTEGRATION"], "posix")
    }

    func testModernBashWithoutEnvLeavesNothingToRestore() {
        let out = prepare(["/opt/homebrew/bin/bash", "-l"])
        XCTAssertNil(out.env["DAMSON_BASH_ENV"])
    }

    /// bash 3.2 ignores ENV in POSIX mode, so it takes --rcfile and is told it was a login.
    func testBash3UsesRcfileAndRemembersLogin() {
        let script = root.appendingPathComponent("bash/damson.bash").path
        let login = prepare(["/bin/bash", "-l"], bash: 3)
        XCTAssertEqual(login.argv, ["/bin/bash", "--rcfile", script, "-i"])
        XCTAssertEqual(login.env["DAMSON_BASH_LOGIN"], "1")
        XCTAssertEqual(login.env["DAMSON_BASH_INTEGRATION"], "rcfile")
        XCTAssertNil(login.env["ENV"])

        let interactive = prepare(["/bin/bash"], bash: 3)
        XCTAssertEqual(interactive.argv, ["/bin/bash", "--rcfile", script, "-i"])
        XCTAssertNil(interactive.env["DAMSON_BASH_LOGIN"])
    }

    func testBashWithACommandOrUnknownFlagIsLeftAlone() {
        for argv in [["/bin/bash", "-c", "echo hi"], ["/bin/bash", "script.sh"], ["/bin/bash", "--norc"]] {
            let out = prepare(argv)
            XCTAssertEqual(out.argv, argv)
            XCTAssertNil(out.env["ENV"])
            XCTAssertNil(out.env["DAMSON_BASH_INTEGRATION"])
        }
    }

    func testBashWhoseVersionCantBeReadIsLeftAlone() {
        let out = prepare(["/bin/bash", "-l"], bash: nil)
        XCTAssertEqual(out.argv, ["/bin/bash", "-l"])
        XCTAssertNil(out.env["DAMSON_BASH_INTEGRATION"])
    }

    func testABareBashNameIsResolvedOnThePanesPath() {
        var probed: String?
        let out = ShellIntegration.prepare(argv: ["bash", "-l"], env: ["PATH": "/usr/bin:/bin"], root: root,
                                           bashMajorVersion: { probed = $0; return 5 })
        XCTAssertEqual(probed, "/bin/bash")
        XCTAssertEqual(out.argv, ["bash", "--posix", "-l"], "argv[0] itself is left as given")
    }

    func testFishPutsOurDataDirFirstAndKeepsTheDefaults() {
        let unset = prepare(["/opt/homebrew/bin/fish", "-l"])
        XCTAssertEqual(unset.argv, ["/opt/homebrew/bin/fish", "-l"])
        XCTAssertEqual(unset.env["XDG_DATA_DIRS"],
                       root.appendingPathComponent("fish").path + ":/usr/local/share:/usr/share")
        XCTAssertNil(unset.env["DAMSON_FISH_XDG_DATA_DIRS"])
        let conf = root.appendingPathComponent("fish/fish/vendor_conf.d/damson-shell-integration.fish")
        XCTAssertTrue(FileManager.default.fileExists(atPath: conf.path))

        let set = prepare(["/opt/homebrew/bin/fish"], env: ["XDG_DATA_DIRS": "/a:/b"])
        XCTAssertEqual(set.env["XDG_DATA_DIRS"], root.appendingPathComponent("fish").path + ":/a:/b")
        XCTAssertEqual(set.env["DAMSON_FISH_XDG_DATA_DIRS"], "/a:/b")
    }

    func testOtherProgramsAreUntouched() {
        let env = ["PATH": "/usr/bin", "ENV": "/x"]
        let out = prepare(["/usr/local/bin/claude"], env: env)
        XCTAssertEqual(out.argv, ["/usr/local/bin/claude"])
        XCTAssertEqual(out.env, env)
    }

    func testUnwritableRootLeavesTheShellAlone() {
        let file = root.appendingPathExtension("file")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: file) }
        let out = ShellIntegration.prepare(argv: ["/bin/zsh", "-l"], env: [:], root: file,
                                           bashMajorVersion: { _ in 5 })
        XCTAssertEqual(out.argv, ["/bin/zsh", "-l"])
        XCTAssertNil(out.env["ZDOTDIR"])
    }

    func testRealBashVersionProbe() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/bin/bash"))
        XCTAssertEqual(ShellIntegration.probedBashMajorVersion("/bin/bash"), 3)
        XCTAssertNil(ShellIntegration.probedBashMajorVersion("/nonexistent/bash"))
    }
}
