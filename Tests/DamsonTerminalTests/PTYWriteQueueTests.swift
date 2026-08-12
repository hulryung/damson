import Darwin
import XCTest
@testable import DamsonTerminal

/// The PTY write side must never block the caller. Every write runs on the thread the host
/// writes from — in the app that is always the main thread — so a child that has stopped
/// reading its stdin (a paused job, a wedged TUI) must not be able to freeze the UI. The
/// read side has had a bounded, poll-driven contract for a while; these pin the same
/// contract on the write side.
///
/// Children here run in RAW mode (`stty raw -echo`) on purpose. A canonical-mode tty caps
/// one line at MAX_CANON (1 KB) and silently discards the excess in the kernel, which would
/// mask what these tests are about. Raw mode is also what the programs that actually matter
/// use — vim, less, htop, and every full-screen TUI.
final class PTYWriteQueueTests: XCTestCase {

    private func pump(until predicate: () -> Bool, timeout: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// Spawn a raw-mode child and wait until it has actually applied `stty` — writing
    /// before that races the line discipline switch.
    private func spawnRawChild(_ pty: PTYHost, command: String,
                               ready: @escaping () -> Bool) throws {
        try pty.spawn(
            argv: ["/bin/sh", "-c", "stty raw -echo; printf RDY; \(command)"],
            env: ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin"],
            cwd: nil, cols: 80, rows: 24
        )
        pump(until: ready, timeout: 10)
    }

    /// The regression test for the app-wide beachball: a raw-mode child that never reads
    /// its stdin. The kernel's tty input queue fills after a few KB, and a blocking write
    /// on the caller's thread parks there until the child drains — which never happens.
    /// In the app that thread is main, so every window stops redrawing until force-quit.
    func testWriteDoesNotBlockWhenChildIsNotReading() throws {
        let pty = PTYHost()
        var sawReady = false
        pty.onData = { if String(decoding: $0, as: UTF8.self).contains("RDY") { sawReady = true } }
        try spawnRawChild(pty, command: "sleep 30", ready: { sawReady })
        defer { pty.terminate() }
        XCTAssertTrue(sawReady, "child never reached raw mode")

        let payload = Data(repeating: 0x41, count: 1_000_000)
        let start = Date()
        pty.write(payload)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.5,
                          "write() blocked \(elapsed)s on a child that isn't reading — " +
                          "on the main thread that is the whole-app freeze")
    }

    /// Bytes queued while the child could not accept them must arrive intact and in order
    /// once it drains: the queue may defer a write, never drop or reorder one.
    func testQueuedBytesArriveInOrderOnceChildReads() throws {
        let pty = PTYHost()
        var received = Data()
        var sawReady = false
        pty.onData = {
            received.append($0)
            if String(decoding: received, as: UTF8.self).contains("RDY") { sawReady = true }
        }
        try spawnRawChild(pty, command: "cat", ready: { sawReady })
        defer { pty.terminate() }
        received.removeAll()

        // A position-dependent pattern several times the tty input queue, so a dropped or
        // reordered run shows up as a mismatch rather than a length change alone.
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var payload = [UInt8]()
        for i in 0..<64_000 { payload.append(alphabet[i % alphabet.count].asciiValue!) }
        pty.write(Data(payload))

        pump(until: { received.count >= payload.count })
        XCTAssertEqual(received.count, payload.count,
                       "queued input was truncated (\(received.count) of \(payload.count) B echoed)")
        XCTAssertEqual(Array(received), payload, "queued input was reordered or corrupted")
    }

    /// Interleaved small and large writes share one FIFO, so a terminal report (a DSR or
    /// DA reply) emitted between two paste chunks can never overtake them.
    func testInterleavedWritesPreserveOrder() throws {
        let pty = PTYHost()
        var received = Data()
        var sawReady = false
        pty.onData = {
            received.append($0)
            if String(decoding: received, as: UTF8.self).contains("RDY") { sawReady = true }
        }
        try spawnRawChild(pty, command: "cat", ready: { sawReady })
        defer { pty.terminate() }
        received.removeAll()

        let big = Data(repeating: 0x58, count: 16_000)      // "X" * 16000
        let marker = Data("MARKER".utf8)                    // the reply slipped between chunks
        pty.write(big)
        pty.write(marker)
        pty.write(big)

        let expected = big + marker + big
        pump(until: { received.count >= expected.count })
        XCTAssertEqual(received, expected, "writes did not preserve FIFO order across sizes")
    }

    /// An adopted master arrives from the keeper carrying the keeper's `O_NONBLOCK` — the
    /// flag lives on the shared open file description and survives SCM_RIGHTS. A write path
    /// that treats EAGAIN as "give up" silently truncates a paste, including its closing
    /// bracketed-paste terminator, which leaves the shell wedged. Adopting must be lossless.
    func testAdoptedNonBlockingMasterIsLossless() throws {
        // Stand in for the keeper: a pty whose master was made non-blocking before handoff.
        var master: Int32 = 0
        var ws = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        let pid = forkpty(&master, nil, nil, &ws)
        XCTAssertGreaterThanOrEqual(pid, 0)
        if pid == 0 {
            let argStrings = ["/bin/sh", "-c", "stty raw -echo; printf RDY; cat"]
            let envStrings = ["PATH=/usr/bin:/bin", "TERM=xterm-256color"]
            let argv: [UnsafeMutablePointer<CChar>?] = argStrings.map { strdup($0) } + [nil]
            let envp: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
            argv.withUnsafeBufferPointer { a in
                envp.withUnsafeBufferPointer { e in
                    _ = execve("/bin/sh",
                               UnsafeMutablePointer(mutating: a.baseAddress),
                               UnsafeMutablePointer(mutating: e.baseAddress))
                }
            }
            _exit(127)
        }
        let fl = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, fl | O_NONBLOCK)   // exactly what damson-keeper does

        let pty = PTYHost()
        var received = Data()
        var sawReady = false
        pty.onData = {
            received.append($0)
            if String(decoding: received, as: UTF8.self).contains("RDY") { sawReady = true }
        }
        pty.adopt(fd: master, pid: pid, startSec: 0, startUsec: 0, replay: Data())
        try pty.spawn(argv: ["/bin/sh"], env: [:], cwd: nil, cols: 80, rows: 24)
        defer { pty.terminate() }
        pump(until: { sawReady }, timeout: 10)
        received.removeAll()

        let payload = Data(repeating: 0x5A, count: 64_000)   // "Z" * 64000
        pty.write(payload)

        pump(until: { received.count >= payload.count })
        XCTAssertEqual(received.count, payload.count,
                       "adopted non-blocking master dropped part of the write " +
                       "(\(received.count) of \(payload.count) B echoed back)")
    }

    /// The pty master must not survive execve into the next pane's shell. Without
    /// FD_CLOEXEC every later shell holds this master open for life: the pty is never
    /// freed when its pane closes, and our close() stops being the last one — so the
    /// SIGHUP that teardown and the keeper handoff both depend on is never delivered.
    func testMasterIsCloseOnExec() throws {
        let pty = PTYHost()
        try pty.spawn(
            argv: ["/bin/sh", "-c", "sleep 5"],
            env: ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin"],
            cwd: nil, cols: 80, rows: 24
        )
        defer { pty.terminate() }

        let flags = fcntl(pty.primaryFD, F_GETFD)
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertNotEqual(flags & FD_CLOEXEC, 0,
                          "pty master lacks FD_CLOEXEC — it leaks into every pane opened later")
    }

    /// Spawning and tearing down many hosts must not accumulate descriptors. The wake pipe
    /// is the one that leaked: it was closed only through a `[weak self]` block, so once the
    /// host itself was released the two fds were never closed at all.
    func testRepeatedSpawnTerminateDoesNotLeakDescriptors() throws {
        func openDescriptorCount() -> Int {
            var n = 0
            let limit = Int32(getdtablesize())
            for fd in 0..<limit where fcntl(fd, F_GETFD) >= 0 { n += 1 }
            return n
        }

        // Warm up so lazily-created singletons aren't counted as a leak.
        for _ in 0..<3 {
            let pty = PTYHost()
            try pty.spawn(argv: ["/bin/sh", "-c", "exit 0"],
                          env: ["PATH": "/usr/bin:/bin"], cwd: nil, cols: 80, rows: 24)
            pty.terminate()
        }
        pump(until: { false }, timeout: 2.0)

        let before = openDescriptorCount()
        for _ in 0..<60 {
            let pty = PTYHost()
            try pty.spawn(argv: ["/bin/sh", "-c", "exit 0"],
                          env: ["PATH": "/usr/bin:/bin"], cwd: nil, cols: 80, rows: 24)
            pty.terminate()
        }
        // terminate() finishes its close work on a background queue; give it room.
        pump(until: { openDescriptorCount() <= before + 8 }, timeout: 15)
        let after = openDescriptorCount()
        XCTAssertLessThanOrEqual(after - before, 8,
                                 "leaked \(after - before) descriptors over 60 spawn/terminate cycles")
    }
}
