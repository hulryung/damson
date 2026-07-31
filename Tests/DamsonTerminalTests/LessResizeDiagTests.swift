import XCTest
@testable import DamsonTerminal

/// Diagnostic: what does `less -FRX` (git's default pager) actually WRITE when the window
/// is resized? Decides whether the duplicated line seen after a resize is the pager
/// reprinting itself or the terminal inventing content. Prints; skipped unless
/// DAMSON_PTY_DIAG=1.
final class LessResizeDiagTests: XCTestCase {

    private func settle(_ t: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(t)) }

    func testWhatLessWritesOnResize() throws {
        guard ProcessInfo.processInfo.environment["DAMSON_PTY_DIAG"] == "1" else {
            throw XCTSkip("diagnostic — set DAMSON_PTY_DIAG=1")
        }
        // A file whose lines are individually identifiable.
        let path = NSTemporaryDirectory() + "less-resize-probe.txt"
        let body = (1...60).map { String(format: "LINE%03d", $0) }.joined(separator: "\n") + "\n"
        try body.write(toFile: path, atomically: true, encoding: .utf8)

        let pty = PTYHost()
        var buf = Data()
        pty.onData = { buf.append($0) }
        var env = DamsonConfig.defaultEnv()
        env["TERM"] = "xterm-256color"
        env["LESS"] = "FRX"          // exactly what git sets
        try pty.spawn(argv: ["/usr/bin/less", path], env: env,
                      cwd: NSTemporaryDirectory(), cols: 40, rows: 10)
        defer { pty.terminate() }

        func dump(_ label: String) {
            let s = String(decoding: buf, as: UTF8.self)
            let esc = s.replacingOccurrences(of: "\u{1b}", with: "\\e")
                       .replacingOccurrences(of: "\r", with: "\\r")
                       .replacingOccurrences(of: "\u{07}", with: "\\a")
                       .replacingOccurrences(of: "\n", with: "\\n\n")
            print("==== \(label) ====\n\(esc)\n==== end \(label) (\(buf.count) bytes) ====")
            buf.removeAll()
        }

        settle(1.0)
        dump("initial paint at 40x10")

        pty.resize(cols: 40, rows: 11)      // grow one row
        settle(0.8)
        dump("after GROW to 11 rows")

        pty.resize(cols: 40, rows: 10)      // shrink back
        settle(0.8)
        dump("after SHRINK back to 10 rows")
    }
}
