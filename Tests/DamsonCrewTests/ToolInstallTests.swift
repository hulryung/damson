import XCTest
@testable import DamsonCrew

/// Putting damson's CLIs on PATH. Everything here is about not surprising the user: never
/// overwrite something that is not ours, notice a link left behind by an older install, and
/// say plainly when the chosen folder is not on PATH — a "successful" install the shell
/// cannot see is the failure this code exists to avoid.
final class ToolInstallTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tool-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func dir(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func source(_ tools: [String]) throws -> URL {
        let res = try dir("Resources")
        for t in tools {
            FileManager.default.createFile(atPath: res.appendingPathComponent(t).path,
                                           contents: Data("#!/bin/sh\n".utf8))
        }
        return res
    }

    // MARK: - Choosing where to install

    /// The first writable candidate that is already on PATH wins, so the tools work in a
    /// shell the user has open right now without touching a profile.
    func testPrefersAWritableFolderAlreadyOnPath() throws {
        let local = try dir("local-bin"), other = try dir("other-bin")
        let choice = ToolInstall.chooseBinDirectory(
            candidates: [other, local], pathEntries: [local.path])
        XCTAssertEqual(choice.url, local)
        XCTAssertTrue(choice.onPath)
    }

    /// Nothing on PATH: fall back to the first candidate and say it is not on PATH rather
    /// than reporting a clean install the shell cannot see.
    func testFallsBackAndReportsThatItIsNotOnPath() throws {
        let local = try dir("local-bin")
        let choice = ToolInstall.chooseBinDirectory(candidates: [local], pathEntries: ["/usr/bin"])
        XCTAssertEqual(choice.url, local)
        XCTAssertFalse(choice.onPath)
    }

    /// A candidate that does not exist yet is still usable — it is created on install — but
    /// one that exists and is read-only is not.
    func testSkipsAFolderItCannotWriteTo() throws {
        let readOnly = try dir("read-only")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                       ofItemAtPath: readOnly.path) }
        let fresh = root.appendingPathComponent("not-created-yet")
        let choice = ToolInstall.chooseBinDirectory(candidates: [readOnly, fresh], pathEntries: [])
        XCTAssertEqual(choice.url, fresh)
    }

    // MARK: - What is installed right now

    func testReportsMissingThenInstalled() throws {
        let src = try source(["damson-cli"]), bin = try dir("bin")
        XCTAssertEqual(ToolInstall.status(tools: ["damson-cli"], source: src, binDir: bin),
                       [.init(tool: "damson-cli", state: .missing)])

        let done = try ToolInstall.install(tools: ["damson-cli"], source: src, binDir: bin)
        XCTAssertEqual(done, ["damson-cli"])
        XCTAssertEqual(ToolInstall.status(tools: ["damson-cli"], source: src, binDir: bin),
                       [.init(tool: "damson-cli", state: .installed)])
    }

    /// The link an older app left behind points into a bundle that has moved or gone. That
    /// is the state where the user runs an ancient CLI against a new app and nothing says so.
    func testSpotsALinkLeftByAnEarlierInstall() throws {
        let src = try source(["damson-cli"]), bin = try dir("bin")
        try FileManager.default.createSymbolicLink(
            atPath: bin.appendingPathComponent("damson-cli").path,
            withDestinationPath: "/Applications/Old.app/Contents/Resources/damson-cli")

        guard case .outdated(let target) =
                ToolInstall.status(tools: ["damson-cli"], source: src, binDir: bin).first?.state else {
            return XCTFail("a stale link must not read as installed")
        }
        XCTAssertEqual(target, "/Applications/Old.app/Contents/Resources/damson-cli")

        _ = try ToolInstall.install(tools: ["damson-cli"], source: src, binDir: bin)
        XCTAssertEqual(ToolInstall.status(tools: ["damson-cli"], source: src, binDir: bin),
                       [.init(tool: "damson-cli", state: .installed)])
    }

    /// Someone else's binary of the same name is not ours to replace: report it and leave it.
    func testNeverOverwritesSomethingThatIsNotALink() throws {
        let src = try source(["damson-cli"]), bin = try dir("bin")
        let theirs = bin.appendingPathComponent("damson-cli")
        FileManager.default.createFile(atPath: theirs.path, contents: Data("not ours".utf8))

        XCTAssertEqual(ToolInstall.status(tools: ["damson-cli"], source: src, binDir: bin),
                       [.init(tool: "damson-cli", state: .blocked)])
        XCTAssertThrowsError(try ToolInstall.install(tools: ["damson-cli"], source: src, binDir: bin))
        XCTAssertEqual(try String(contentsOf: theirs, encoding: .utf8), "not ours")
    }

    /// A tool the bundle does not carry is reported, not silently linked to nothing.
    func testAToolMissingFromTheBundleIsReported() throws {
        let src = try source([]), bin = try dir("bin")
        XCTAssertEqual(ToolInstall.status(tools: ["damson-cli"], source: src, binDir: bin),
                       [.init(tool: "damson-cli", state: .unavailable)])
    }

    // MARK: - Summarising the set

    /// Links pointing at another copy of Damson must not read as "not installed": that is
    /// the state where the shell runs an old CLI against this app, and the wording is the
    /// only thing that tells the user which way to fix it.
    func testOutdatedLinksAreNotReportedAsMissing() {
        let outdated = ToolInstall.tools.map {
            ToolInstall.Status(tool: $0, state: .outdated("/Applications/Other.app/\($0)"))
        }
        XCTAssertEqual(ToolInstall.overall(outdated), .outdated)

        let missing = ToolInstall.tools.map { ToolInstall.Status(tool: $0, state: .missing) }
        XCTAssertEqual(ToolInstall.overall(missing), .notInstalled)
    }

    func testOverallCoversTheOtherStates() {
        let installed = ToolInstall.tools.map { ToolInstall.Status(tool: $0, state: .installed) }
        XCTAssertEqual(ToolInstall.overall(installed), .installed)
        XCTAssertEqual(ToolInstall.overall([]), .notInstalled)

        var mixed = installed
        mixed[0] = ToolInstall.Status(tool: mixed[0].tool, state: .missing)
        XCTAssertEqual(ToolInstall.overall(mixed), .partial(1))

        var blocked = installed
        blocked[1] = ToolInstall.Status(tool: blocked[1].tool, state: .blocked)
        XCTAssertEqual(ToolInstall.overall(blocked), .blocked, "a name we must not take wins")

        var unavailable = installed
        unavailable[2] = ToolInstall.Status(tool: unavailable[2].tool, state: .unavailable)
        XCTAssertEqual(ToolInstall.overall(unavailable), .unavailable)
    }

    // MARK: - The Codex prompt

    /// Written on first install, rewritten when the app ships a newer one, and reported as
    /// unchanged otherwise — the UI needs that difference to avoid claiming work it skipped.
    func testPromptIsWrittenOnceAndRefreshedWhenItChanges() throws {
        let src = root.appendingPathComponent("prompt.md")
        try "first".write(to: src, atomically: true, encoding: .utf8)
        let dst = root.appendingPathComponent("codex/prompts/damson-orchestration.md")

        XCTAssertTrue(try ToolInstall.installPrompt(from: src, to: dst))
        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "first")
        XCTAssertFalse(try ToolInstall.installPrompt(from: src, to: dst), "no change to write")

        try "second".write(to: src, atomically: true, encoding: .utf8)
        XCTAssertTrue(try ToolInstall.installPrompt(from: src, to: dst))
        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "second")
    }

    func testInstallCreatesTheFolder() throws {
        let src = try source(["damson-cli"])
        let bin = root.appendingPathComponent("made-on-demand")
        _ = try ToolInstall.install(tools: ["damson-cli"], source: src, binDir: bin)
        XCTAssertEqual(ToolInstall.status(tools: ["damson-cli"], source: src, binDir: bin),
                       [.init(tool: "damson-cli", state: .installed)])
    }
}
