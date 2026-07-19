import XCTest
@testable import DamsonTerminal

/// Replay harness for `DAMSON_DUMP_OUTPUT` captures (docs/TMUX-INTEGRATION.md §15.2):
/// feeds a captured raw output stream through the same DamsonSession → VTParser → Grid
/// path the app uses, then prints the final visible grid and scans for corruption
/// (U+FFFD cells). Point it at a capture with:
///
///   DAMSON_REPLAY_DUMP=/tmp/damson-dump/session-XXX.bin swift test --filter OutputDumpReplay
///
/// Optional: DAMSON_REPLAY_SIZE=colsxrows (default 130x42), DAMSON_REPLAY_CHUNK=N to
/// replay in fixed N-byte chunks (default: a deterministic mix of sizes to exercise
/// chunk-boundary handling the way PTY reads + the drain cap produce them).
final class OutputDumpReplayTests: XCTestCase {
    final class FakeBackend: SessionIOBackend {
        var onData: ((Data) -> Void)?
        var onExit: ((Int32) -> Void)?
        func spawn(argv: [String], env: [String: String], cwd: String?, cols: Int, rows: Int) throws {}
        func write(_ data: Data) {}
        func resize(cols: Int, rows: Int) {}
        func terminate() {}
        var childWorkingDirectory: String? { nil }
        var isRunningForegroundJob: Bool { false }
    }

    func testReplayCapturedDump() throws {
        guard let path = ProcessInfo.processInfo.environment["DAMSON_REPLAY_DUMP"],
              !path.isEmpty else {
            throw XCTSkip("set DAMSON_REPLAY_DUMP=<capture.bin> to replay a session dump")
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))

        var cols = 130, rows = 42
        if let size = ProcessInfo.processInfo.environment["DAMSON_REPLAY_SIZE"] {
            let p = size.lowercased().split(separator: "x")
            if p.count == 2, let c = Int(p[0]), let r = Int(p[1]) { cols = c; rows = r }
        }

        let backend = FakeBackend()
        let session = DamsonSession(config: DamsonConfig(), backend: backend)
        session.resize(cols: cols, rows: rows)

        // Chunking: fixed size if requested, else a deterministic varied pattern (prime
        // strides) so codepoint/escape splits at boundaries are exercised like real reads.
        let fixed = ProcessInfo.processInfo.environment["DAMSON_REPLAY_CHUNK"].flatMap(Int.init)
        let strides = fixed.map { [$0] } ?? [4096, 7, 65536, 1, 131072, 3, 1024]
        var i = 0, s = 0
        while i < bytes.count {
            let n = min(strides[s % strides.count], bytes.count - i)
            backend.onData?(bytes.subdata(in: i..<(i + n)))
            i += n
            s += 1
        }

        // Final visible grid.
        let g = session.grid
        var screen: [String] = []
        for r in 0..<g.rows {
            var line = ""
            for c in g.row(r) where !c.isContinuation && !c.isWideSpacer { line.append(c.char) }
            screen.append(line)
        }
        print("==== REPLAY: \(path) (\(bytes.count) bytes @ \(cols)x\(rows)) ====")
        for (n, line) in screen.enumerated() { print(String(format: "%3d|%@", n, line)) }
        print("==== scrollback: \(g.scrollback.count) lines ====")

        // Corruption scan: replacement characters anywhere (visible + scrollback).
        let fffd = Character("\u{FFFD}")
        var hits: [String] = []
        for (n, line) in screen.enumerated() where line.contains(fffd) {
            hits.append("row \(n): \(line)")
        }
        for (n, sbLine) in g.scrollback.enumerated() {
            let text = String(sbLine.cells.filter { !$0.isContinuation && !$0.isWideSpacer }
                .map(\.char))
            if text.contains(fffd) { hits.append("scrollback \(n): \(text)") }
        }
        XCTAssertTrue(hits.isEmpty, "U+FFFD cells found:\n" + hits.joined(separator: "\n"))
    }

    /// Replay a capture WITH its .events side-channel: each `<offset> resize <cols> <rows>`
    /// line applies a resize before the byte at that offset — reproducing resize races
    /// (window drags over a live TUI) deterministically. Writes the visible grid after
    /// every resize (plus the seam: the last scrollback rows) into DAMSON_REPLAY_OUT.
    ///
    ///   DAMSON_REPLAY_DUMP=…/session-X.bin DAMSON_REPLAY_EVENTS=…/session-X.events \
    ///   DAMSON_REPLAY_OUT=/tmp/replay-out swift test --filter testReplayCapturedDumpWithEvents
    func testReplayCapturedDumpWithEvents() throws {
        guard let path = ProcessInfo.processInfo.environment["DAMSON_REPLAY_DUMP"],
              let evPath = ProcessInfo.processInfo.environment["DAMSON_REPLAY_EVENTS"],
              !path.isEmpty, !evPath.isEmpty else {
            throw XCTSkip("set DAMSON_REPLAY_DUMP + DAMSON_REPLAY_EVENTS to replay with resizes")
        }
        let outDir = ProcessInfo.processInfo.environment["DAMSON_REPLAY_OUT"] ?? "/tmp/replay-out"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        // Parse events: "<offset> resize <cols> <rows>"
        var events: [(off: Int, cols: Int, rows: Int)] = []
        for line in try String(contentsOfFile: evPath, encoding: .utf8).split(separator: "\n") {
            let p = line.split(separator: " ")
            if p.count == 4, p[1] == "resize",
               let o = Int(p[0]), let c = Int(p[2]), let r = Int(p[3]) {
                events.append((o, c, r))
            }
        }
        let backend = FakeBackend()
        let session = DamsonSession(config: DamsonConfig(), backend: backend)

        func gridText(_ g: Grid) -> [String] {
            (0..<g.rows).map { r in
                var line = ""
                for c in g.row(r) where !c.isContinuation && !c.isWideSpacer { line.append(c.char) }
                while line.hasSuffix(" ") { line.removeLast() }
                return line
            }
        }
        func snapshot(_ step: Int, _ label: String) {
            let g = session.grid
            var out = "== \(label) | grid \(g.cols)x\(g.rows) sb=\(g.scrollback.count) cursor=\(g.cursorRow) ==\n"
            let seam = g.scrollback.suffix(6)
            for (i, l) in seam.enumerated() {
                var text = ""
                for c in l.cells where !c.isContinuation && !c.isWideSpacer { text.append(c.char) }
                while text.hasSuffix(" ") { text.removeLast() }
                out += String(format: "sb%+d|%@\n", i - seam.count, text)
            }
            for (n, line) in gridText(g).enumerated() { out += String(format: "%3d|%@\n", n, line) }
            try? out.write(toFile: String(format: "%@/replay-%03d-%@.txt", outDir, step, label),
                           atomically: true, encoding: .utf8)
        }

        var i = 0, s = 0, step = 0
        var evIdx = 0
        // Apply any offset-0 events (initial size) before feeding.
        while evIdx < events.count, events[evIdx].off == 0 {
            session.resize(cols: events[evIdx].cols, rows: events[evIdx].rows)
            evIdx += 1
        }
        let strides = [4096, 7, 65536, 1, 131072, 3, 1024]
        while i < bytes.count {
            var n = min(strides[s % strides.count], bytes.count - i)
            if evIdx < events.count { n = min(n, events[evIdx].off - i) }
            if n > 0 {
                backend.onData?(bytes.subdata(in: i..<(i + n)))
                i += n
                s += 1
            }
            while evIdx < events.count, events[evIdx].off == i {
                step += 1
                session.resize(cols: events[evIdx].cols, rows: events[evIdx].rows)
                snapshot(step, "r\(events[evIdx].cols)x\(events[evIdx].rows)")
                evIdx += 1
            }
        }
        snapshot(step + 1, "final")
        print("replayed \(bytes.count) bytes, \(events.count) resizes → \(outDir)")
    }
}
