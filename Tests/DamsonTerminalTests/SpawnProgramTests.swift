import Darwin
import XCTest
@testable import DamsonTerminal

/// `execve` does not search `PATH` — only `execvp` does, and it takes the caller's own
/// environment rather than the one being handed to the child. So a bare program name used to
/// fail in the child, which `_exit(127)`s, which closes the pane. The tab opened and vanished
/// with nothing reported anywhere.
///
/// Found by dogfooding: `damson-crew`'s default agent is `claude`, so every fan-out with
/// default settings silently opened and closed a tab per task while `spawn` answered ok.
final class SpawnProgramTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("damson-prog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeProgram(_ name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try "#!/bin/sh\nprintf RAN\nsleep 5\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: - Resolution

    func testAPathIsUsedAsGiven() {
        XCTAssertEqual(PTYHost.resolveProgram("/bin/sh", env: [:]), "/bin/sh")
        XCTAssertEqual(PTYHost.resolveProgram("./thing", env: [:]), "./thing")
    }

    /// The whole point: a bare name is looked up in the PATH the CHILD will be given, not the
    /// one this process happens to have.
    func testABareNameIsResolvedAgainstTheChildsPath() throws {
        _ = try makeProgram("mytool")
        XCTAssertEqual(PTYHost.resolveProgram("mytool", env: ["PATH": scratch.path]),
                       scratch.appendingPathComponent("mytool").path)
    }

    func testAnUnresolvableNameIsReported() {
        XCTAssertNil(PTYHost.resolveProgram("definitely-not-a-program", env: ["PATH": "/usr/bin"]))
        XCTAssertNil(PTYHost.resolveProgram("mytool", env: [:]), "no PATH means nothing to search")
    }

    /// A name that matches a directory, or a file without the execute bit, is not a program.
    func testANonExecutableMatchIsSkipped() throws {
        let plain = scratch.appendingPathComponent("plain")
        try Data("x".utf8).write(to: plain)
        XCTAssertNil(PTYHost.resolveProgram("plain", env: ["PATH": scratch.path]))
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("adir"),
                                                withIntermediateDirectories: true)
        XCTAssertNil(PTYHost.resolveProgram("adir", env: ["PATH": scratch.path]))
    }

    /// Earlier entries win, as a shell would do.
    func testTheFirstMatchOnThePathWins() throws {
        let second = scratch.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let dup = second.appendingPathComponent("mytool")
        try "#!/bin/sh\nexit 0\n".write(to: dup, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dup.path)
        _ = try makeProgram("mytool")
        XCTAssertEqual(PTYHost.resolveProgram("mytool", env: ["PATH": "\(scratch.path):\(second.path)"]),
                       scratch.appendingPathComponent("mytool").path)
    }

    // MARK: - Spawning

    /// Reported before the fork, so the caller gets an error instead of a tab that vanishes.
    func testSpawnRefusesAnUnresolvableProgram() {
        let pty = PTYHost()
        XCTAssertThrowsError(try pty.spawn(argv: ["definitely-not-a-program"],
                                           env: ["PATH": "/usr/bin:/bin"],
                                           cwd: nil, cols: 80, rows: 24)) { error in
            guard case PTYHost.SpawnError.programNotFound(let name)? =
                    error as? PTYHost.SpawnError else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(name, "definitely-not-a-program")
        }
        XCTAssertEqual(pty.childPID, -1, "a pane was opened for a program that cannot run")
        pty.terminate()
    }

    /// And the case that was broken: a bare name that IS on the child's PATH must run.
    func testABareNameOnThePathActuallyRuns() throws {
        _ = try makeProgram("mytool")
        let pty = PTYHost()
        var received = Data()
        pty.onData = { received.append($0) }
        try pty.spawn(argv: ["mytool"], env: ["PATH": scratch.path], cwd: nil, cols: 80, rows: 24)
        defer { pty.terminate() }

        let deadline = Date().addingTimeInterval(10)
        while !String(decoding: received, as: UTF8.self).contains("RAN") && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(String(decoding: received, as: UTF8.self).contains("RAN"),
                      "a bare program name on the child's PATH did not run")
    }
}
