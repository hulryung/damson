import Darwin
import XCTest
@testable import DamsonTerminal

/// SIGPIPE policy. 0.7.1 ran 7.6 hours and then exited "due to SIGPIPE | sent by damson"
/// — the whole app, every pane with it, no crash report — because a write reached a pipe or
/// socket whose reader had gone. The app now ignores the signal, and gives every program it
/// starts in a pane the default behaviour back.
final class BrokenPipeTests: XCTestCase {
    private var saved = sigaction()

    override func setUp() {
        super.setUp()
        sigaction(SIGPIPE, nil, &saved)
    }

    override func tearDown() {
        sigaction(SIGPIPE, &saved, nil)
        super.tearDown()
    }

    private func pump(until predicate: () -> Bool, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// The app side. Without the policy this test does not fail — it takes the whole test
    /// process down, which is exactly what the signal did to damson.
    func testABrokenPipeBecomesAnErrorInsteadOfKillingTheProcess() {
        BrokenPipes.ignoreInThisProcess()

        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        close(fds[0])                       // the reader goes away
        var byte: UInt8 = 1
        let n = write(fds[1], &byte, 1)
        let err = errno
        close(fds[1])

        XCTAssertEqual(n, -1)
        XCTAssertEqual(err, EPIPE, "a peer that hung up must come back as EPIPE")
    }

    /// The pane side. An ignored signal stays ignored across execve, so a shell started by a
    /// process that ignores SIGPIPE would ignore it too. The shell here signals itself: with
    /// the default restored it dies on the spot, and SURVIVED is never printed.
    func testAProgramInAPaneStillDiesOnSIGPIPE() throws {
        BrokenPipes.ignoreInThisProcess()   // as the app does at launch

        let pty = PTYHost()
        var out = ""
        var exited = false
        pty.onData = { out += String(decoding: $0, as: UTF8.self) }
        pty.onExit = { _ in exited = true }
        try pty.spawn(
            argv: ["/bin/sh", "-c", "printf START; kill -PIPE $$; printf SURVIVED"],
            env: ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin"],
            cwd: nil, cols: 80, rows: 24
        )
        defer { pty.terminate() }
        pump(until: { exited })

        XCTAssertTrue(out.contains("START"), "the child never ran (got \(out.debugDescription))")
        XCTAssertFalse(out.contains("SURVIVED"),
                       "the pane's shell inherited SIGPIPE as ignored")
    }

    /// What a user would actually see if the restore were missing: `yes | head` ends with
    /// "yes: stdout: Broken pipe" instead of `yes` quietly stopping.
    func testAPipelineInAPaneEndsQuietly() throws {
        BrokenPipes.ignoreInThisProcess()

        let pty = PTYHost()
        var out = ""
        var exited = false
        pty.onData = { out += String(decoding: $0, as: UTF8.self) }
        pty.onExit = { _ in exited = true }
        try pty.spawn(
            argv: ["/bin/sh", "-c", "yes | head -n 1; printf DONE"],
            env: ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin"],
            cwd: nil, cols: 80, rows: 24
        )
        defer { pty.terminate() }
        pump(until: { exited })

        XCTAssertTrue(out.contains("DONE"), "the pipeline never finished (got \(out.debugDescription))")
        XCTAssertFalse(out.contains("Broken pipe"),
                       "yes saw EPIPE instead of SIGPIPE: \(out.debugDescription)")
    }
}
