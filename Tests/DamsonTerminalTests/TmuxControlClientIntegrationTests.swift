import XCTest
@testable import DamsonTerminal

/// Integration tests that drive a REAL `tmux -C` control client. `TmuxControlClient`
/// forkpty's tmux itself, so these run headlessly (no display). They are GUARDED: if tmux
/// isn't on PATH, each test `throw`s `XCTSkip(...)` so CI without tmux stays green.
///
/// Isolation: every test points tmux at a private `TMUX_TMPDIR` socket dir so it never
/// touches a real user tmux server, and kills that server on teardown.
final class TmuxControlClientIntegrationTests: XCTestCase {

    // MARK: - tmux discovery / isolation

    /// Absolute path to a `tmux` binary on PATH (incl. the common Homebrew prefix), or nil.
    private static func findTmux() -> String? {
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        dirs.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"])
        for d in dirs {
            let p = d + "/tmux"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    private var tmuxDir: String!

    override func setUpWithError() throws {
        guard Self.findTmux() != nil else {
            throw XCTSkip("tmux not found on PATH — skipping real-tmux integration test")
        }
        // Private socket dir so we never touch the user's tmux server. Keep the path SHORT:
        // tmux's socket is `<TMUX_TMPDIR>/tmux-<uid>/default`, and a Unix-domain socket path
        // can't exceed ~104 bytes on macOS, so the long `/private/var/folders/...` temp dir
        // overflows. Use a short `/tmp` path with a small random suffix.
        tmuxDir = "/tmp/dtmux\(UInt16.random(in: 0...65535))"
        try? FileManager.default.removeItem(atPath: tmuxDir)
        try FileManager.default.createDirectory(atPath: tmuxDir, withIntermediateDirectories: true)
        setenv("TMUX_TMPDIR", tmuxDir, 1)
        // Make sure the Homebrew prefix is on PATH for the spawned `/usr/bin/env tmux`.
        if let tmux = Self.findTmux() {
            let binDir = (tmux as NSString).deletingLastPathComponent
            let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
            if !path.split(separator: ":").map(String.init).contains(binDir) {
                setenv("PATH", binDir + ":" + path, 1)
            }
        }
    }

    override func tearDownWithError() throws {
        // Best-effort: kill the isolated server so nothing lingers.
        if let dir = tmuxDir {
            let task = Process()
            task.launchPath = "/usr/bin/env"
            task.arguments = ["tmux", "kill-server"]
            var env = ProcessInfo.processInfo.environment
            env["TMUX_TMPDIR"] = dir
            task.environment = env
            try? task.run()
            task.waitUntilExit()
            try? FileManager.default.removeItem(atPath: dir)
        }
        unsetenv("TMUX_TMPDIR")
    }

    // MARK: - runloop pump

    private func pump(until predicate: () -> Bool, timeout: TimeInterval = 8) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - Tests

    /// Attaching a fresh `tmux -C new-session` must yield well-formed `%begin/%end` frames
    /// (the first one is NOT `.unhandled`, which was BUG 1) and deliver real `%output` for
    /// the pane, octal-decoded.
    func testAttachReceivesFramedReplyAndPaneOutput() throws {
        let client = TmuxControlClient()
        defer { client.terminate() }

        var replies: [TmuxCommandReply] = []
        var unhandled: [String] = []
        var outputByPane: [TmuxPaneID: Data] = [:]
        var firstPane: TmuxPaneID?

        client.onCommandReply = { replies.append($0) }
        client.onUnhandled = { unhandled.append($0) }
        client.onPaneOutput = { pane, data in
            if firstPane == nil { firstPane = pane }
            outputByPane[pane, default: Data()].append(data)
        }

        try client.attach(target: nil, cols: 80, rows: 24)

        // Wait until we've seen at least one framed reply (the startup %begin/%end block).
        pump(until: { !replies.isEmpty })
        XCTAssertFalse(replies.isEmpty, "expected at least one %begin/%end reply on attach")

        // BUG 1 regression: the startup reply block must NOT have leaked into .unhandled.
        // (With -CC the first line was `\u{1B}P1000p%begin …` → unhandled; with -C + the
        // defensive strip, it frames correctly.)
        XCTAssertFalse(unhandled.contains { $0.contains("%begin") || $0.contains("%end") },
                       "startup %begin/%end leaked into .unhandled: \(unhandled)")

        // Drive output: send a marker through the active pane and assert it round-trips as
        // octal-decoded %output. We learn the pane id from the first %output (the shell
        // prompt) or by issuing a layout/list — simplest is to wait for ANY output, capture
        // its pane, then echo a unique marker into that pane and look for it.
        pump(until: { firstPane != nil }, timeout: 8)
        let pane = try XCTUnwrap(firstPane, "no %output (and thus no pane id) seen on attach")

        let marker = "TMUXMARK_\(UUID().uuidString.prefix(8))"
        outputByPane[pane] = Data()  // reset so we only match new output
        client.sendKeys(to: pane, data: Data("printf '\(marker)\\n'\n".utf8))

        pump(until: {
            guard let d = outputByPane[pane] else { return false }
            return String(decoding: d, as: UTF8.self).contains(marker)
        })

        let seen = String(decoding: outputByPane[pane] ?? Data(), as: UTF8.self)
        XCTAssertTrue(seen.contains(marker),
                      "expected pane %\(pane.raw) output to contain \(marker); got: \(seen.debugDescription)")
        // The output must be octal-DECODED bytes (e.g. a real newline 0x0A, not literal \012).
        XCTAssertTrue((outputByPane[pane] ?? Data()).contains(0x0A),
                      "expected a decoded LF (0x0A) in pane output, not a literal \\012 escape")
    }

    /// BUG 2 data-path proof (headless): bytes arriving as `%output` from a REAL tmux client
    /// reach a `DamsonSession`'s Grid through the SAME path a local PTY uses — i.e. via
    /// `TmuxPaneBackend.deliver` → `DamsonSession.onData` → `VTParser` → `Grid`. This mirrors
    /// what `TmuxIntegrationController` wires up, but stays in the testable DamsonTerminal
    /// module. The on-SCREEN render still needs a GUI re-test; this proves the data path.
    func testPaneOutputReachesDamsonSessionGrid() throws {
        let client = TmuxControlClient()
        defer { client.terminate() }

        // Per-pane backend + session, created lazily on first sighting of a pane — exactly
        // like TmuxIntegrationController.ensureTab.
        var backends: [TmuxPaneID: TmuxPaneBackend] = [:]
        var sessions: [TmuxPaneID: DamsonSession] = [:]

        func ensureSession(_ pane: TmuxPaneID) {
            guard sessions[pane] == nil else { return }
            let backend = TmuxPaneBackend(client: client, pane: pane)
            let session = DamsonSession(config: DamsonConfig(), backend: backend)
            backends[pane] = backend
            sessions[pane] = session
        }

        client.onPaneOutput = { pane, data in
            ensureSession(pane)        // lazy create (BUG 2 #2: don't drop first output)
            backends[pane]?.deliver(data)   // BUG 2 #3: feed the SAME onData path as local PTY
        }

        try client.attach(target: nil, cols: 80, rows: 24)

        // Wait for a pane/session to materialize from the prompt output.
        pump(until: { !sessions.isEmpty })
        let pane = try XCTUnwrap(sessions.keys.first, "no pane/session created from %output")
        let session = try XCTUnwrap(sessions[pane])

        // Echo a unique marker and assert it lands in the session's GRID (not just the raw
        // callback) — i.e. it went through VTParser into Grid cells.
        let marker = "GRIDMARK\(Int.random(in: 1000...9999))"
        client.sendKeys(to: pane, data: Data("printf '\(marker)\\n'\n".utf8))

        func gridText(_ g: Grid) -> String {
            var phys: [[Cell]] = g.scrollback.map { $0.cells }
            for r in 0..<g.rows { phys.append(g.row(r)) }
            var s = ""
            for cells in phys {
                for c in cells where !c.isContinuation && !c.isWideSpacer { s.append(c.char) }
                s.append("\n")
            }
            return s
        }

        pump(until: { gridText(session.grid).contains(marker) })
        XCTAssertTrue(gridText(session.grid).contains(marker),
                      "tmux %output did not reach the DamsonSession Grid via TmuxPaneBackend; grid was:\n" +
                      gridText(session.grid))
    }
}
