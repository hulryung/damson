import Darwin
import XCTest
@testable import DamsonTerminal

/// `foregroundPID` exposes the process group owning a pane's tty — the identifier a host
/// uses to tell *what* is running in a pane. `isRunningForegroundJob` was refactored to be
/// derived from it, so these pin both: the new accessor's contract, and the fact that the
/// old predicate's behaviour is unchanged.
final class ForegroundPIDTests: XCTestCase {

    private func pump(until predicate: () -> Bool, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// A shell sitting at its prompt owns the terminal itself, so the foreground group is
    /// the shell — present, but not a "job". This is the case that must NOT regress: the
    /// quit-confirmation dialog uses it to avoid prompting when only a shell is up.
    func testShellAtPromptIsForegroundGroupButNotAJob() throws {
        let pty = PTYHost()
        var sawPrompt = false
        pty.onData = { if String(decoding: $0, as: UTF8.self).contains("READY") { sawPrompt = true } }
        try pty.spawn(
            argv: ["/bin/sh", "-c", "printf READY; read -r _"],   // idles reading stdin
            env: ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin"],
            cwd: nil, cols: 80, rows: 24
        )
        defer { pty.terminate() }
        pump(until: { sawPrompt })

        let fg = pty.foregroundPID
        XCTAssertNotNil(fg, "a live child must report a foreground process group")
        XCTAssertGreaterThan(fg ?? 0, 0)
        XCTAssertFalse(pty.isRunningForegroundJob,
                       "the shell itself is not a foreground *job*")
    }

    /// THE JOIN. `foregroundPID` must be the pid of the process actually running in the
    /// pane, because that is the key a host looks up in an external tool's own registry
    /// (Claude Code publishes one record per session keyed by pid). Verified end to end by
    /// making the child report its own pid and comparing.
    func testForegroundPIDIsThePIDOfTheProcessInThePane() throws {
        let pty = PTYHost()
        var out = ""
        pty.onData = { out += String(decoding: $0, as: UTF8.self) }
        try pty.spawn(
            // `$$` is the shell's own pid. Two commands, so `sh` does not exec-optimize
            // itself away and stays the process that owns the tty.
            argv: ["/bin/sh", "-c", "printf 'PID:%s.' $$; sleep 30"],
            env: ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin"],
            cwd: nil, cols: 80, rows: 24
        )
        defer { pty.terminate() }

        pump(until: { out.contains(".") })
        let reported = out.split(separator: ":").last.flatMap { $0.split(separator: ".").first }
            .flatMap { pid_t($0) }
        XCTAssertNotNil(reported, "child did not report its pid (got \(out.debugDescription))")
        XCTAssertEqual(pty.foregroundPID, reported,
                       "foregroundPID must name the process running in the pane")
    }

    /// Non-interactive `sh -c` runs without job control, so the tty's foreground group
    /// stays the shell's even while it waits on a child. `isRunningForegroundJob` is
    /// therefore false here — and that is correct, not a regression: the predicate asks
    /// "has the tty been handed to something other than the shell", which nothing did.
    /// Pinned because it is surprising, and because the accessor still resolves the pane's
    /// process correctly in exactly this case (see the join test above).
    func testShellWithoutJobControlKeepsTheTerminalItself() throws {
        let pty = PTYHost()
        var sawStart = false
        pty.onData = { if String(decoding: $0, as: UTF8.self).contains("GO") { sawStart = true } }
        try pty.spawn(
            argv: ["/bin/sh", "-c", "printf GO; sleep 30"],
            env: ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin"],
            cwd: nil, cols: 80, rows: 24
        )
        defer { pty.terminate() }
        pump(until: { sawStart })

        XCTAssertNotNil(pty.foregroundPID, "the tty still has a foreground group")
        XCTAssertFalse(pty.isRunningForegroundJob,
                       "no job control means the shell never handed the tty over")
    }

    /// The invariant the refactor rests on, stated directly: the predicate is exactly
    /// "there is a foreground group and it isn't the shell".
    func testPredicateAgreesWithAccessorAcrossStates() throws {
        let pty = PTYHost()
        var sawStart = false
        pty.onData = { if String(decoding: $0, as: UTF8.self).contains("GO") { sawStart = true } }
        try pty.spawn(
            argv: ["/bin/sh", "-c", "printf GO; sleep 30"],
            env: ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin"],
            cwd: nil, cols: 80, rows: 24
        )
        defer { pty.terminate() }
        pump(until: { sawStart })

        for _ in 0..<20 {
            let fg = pty.foregroundPID
            let expected = (fg != nil) && (fg != pty.childPID)
            XCTAssertEqual(pty.isRunningForegroundJob, expected)
            pump(until: { false }, timeout: 0.02)
        }
    }

    /// Before spawn and after terminate there is no tty to ask, so the accessor is nil and
    /// the predicate is false — never a stale or invented pid.
    func testNoChildReportsNoForegroundGroup() throws {
        let pty = PTYHost()
        XCTAssertNil(pty.foregroundPID, "an unspawned host has no foreground group")
        XCTAssertFalse(pty.isRunningForegroundJob)

        var started = false
        pty.onData = { if !String(decoding: $0, as: UTF8.self).isEmpty { started = true } }
        try pty.spawn(argv: ["/bin/sh", "-c", "printf GO; sleep 5"],
                      env: ["PATH": "/usr/bin:/bin"], cwd: nil, cols: 80, rows: 24)
        // `spawn` returns as soon as forkpty does; the child claims the tty a moment later
        // (login_tty in the child), so there is a brief window with no foreground group.
        pump(until: { started })
        XCTAssertNotNil(pty.foregroundPID)

        pty.terminate()
        XCTAssertNil(pty.foregroundPID, "a terminated host must not report a group")
        XCTAssertFalse(pty.isRunningForegroundJob)
    }

    /// A backend with no controlling terminal inherits the protocol's default rather than
    /// being forced to implement the accessor — this is what keeps existing conformers
    /// (tmux backends, and any downstream of the DamsonTerminal library product) compiling.
    func testBackendsWithoutATTYGetTheDefault() {
        final class TTYlessBackend: SessionIOBackend {
            var onData: ((Data) -> Void)?
            var onExit: ((Int32) -> Void)?
            func spawn(argv: [String], env: [String: String], cwd: String?, cols: Int, rows: Int) throws {}
            func write(_ data: Data) {}
            func resize(cols: Int, rows: Int) {}
            func terminate() {}
            var childWorkingDirectory: String? { nil }
            var isRunningForegroundJob: Bool { false }
        }
        let backend: SessionIOBackend = TTYlessBackend()
        XCTAssertNil(backend.foregroundPID)
    }
}
