import XCTest
@testable import DamsonTerminal

/// The opt-in initial-size spawn. `DamsonSession` has always spawned eagerly at 80×24 and
/// relied on the host to `resize` once real geometry is known — which guarantees every
/// child a layout-at-80×24-then-reflow on its first SIGWINCH. An embedder that knows its
/// grid up front can now pass it at init. Two contracts pinned here: the new inits hand
/// the size to both the grid and the PTY spawn, and the historical inits still mean
/// exactly 80×24 (downstream consumers size their first reflow around that).
final class SessionSpawnSizeTests: XCTestCase {
    private final class SpawnRecordingBackend: SessionIOBackend {
        var onData: ((Data) -> Void)?
        var onExit: ((Int32) -> Void)?
        var spawnedSize: (cols: Int, rows: Int)?
        func spawn(argv: [String], env: [String: String], cwd: String?, cols: Int, rows: Int) throws {
            spawnedSize = (cols, rows)
        }
        func write(_ data: Data) {}
        func resize(cols: Int, rows: Int) {}
        func terminate() {}
        var childWorkingDirectory: String? { nil }
        var isRunningForegroundJob: Bool { false }
    }

    /// The historical contract must not move: the size-less init spawns at exactly 80×24.
    func testDefaultInitStillSpawnsAt80x24() {
        let backend = SpawnRecordingBackend()
        let session = DamsonSession(config: DamsonConfig(), backend: backend)
        XCTAssertEqual(backend.spawnedSize?.cols, 80)
        XCTAssertEqual(backend.spawnedSize?.rows, 24)
        XCTAssertEqual(session.grid.cols, 80)
        XCTAssertEqual(session.grid.rows, 24)
    }

    /// The point of the feature: the child is spawned at the embedder's size, and the grid
    /// matches it from the first byte — no 80×24 intermediate state exists to reflow away.
    func testInitialSizeReachesBothGridAndSpawn() {
        let backend = SpawnRecordingBackend()
        let session = DamsonSession(config: DamsonConfig(), backend: backend,
                                    initialCols: 132, initialRows: 43)
        XCTAssertEqual(backend.spawnedSize?.cols, 132)
        XCTAssertEqual(backend.spawnedSize?.rows, 43)
        XCTAssertEqual(session.grid.cols, 132)
        XCTAssertEqual(session.grid.rows, 43)
    }

    /// Nonsense sizes are clamped, not crashed on or passed through: a 0-column PTY would
    /// break resize/rendering the same way a 0×0 resize-window would (which the wire layer
    /// already rejects for the same reason).
    func testNonPositiveInitialSizeIsClamped() {
        let backend = SpawnRecordingBackend()
        let session = DamsonSession(config: DamsonConfig(), backend: backend,
                                    initialCols: 0, initialRows: -3)
        XCTAssertEqual(backend.spawnedSize?.cols, 1)
        XCTAssertEqual(backend.spawnedSize?.rows, 1)
        XCTAssertEqual(session.grid.cols, 1)
        XCTAssertEqual(session.grid.rows, 1)
    }

    /// The forkpty convenience form exists too — pinned by spawning a real child at the
    /// requested size and asking it what the tty reports. This is the end-to-end claim:
    /// the child's very first `ioctl(TIOCGWINSZ)` sees the embedder's size.
    func testForkptyConvenienceSpawnsChildAtRequestedSize() {
        var config = DamsonConfig()
        config.argv = ["/bin/sh", "-c", "stty size; sleep 30"]
        config.env = ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin"]
        var out = ""
        let session = DamsonSession(config: config, initialCols: 100, initialRows: 30)
        session.onOutput = { out += String(decoding: $0, as: UTF8.self) }
        defer { session.terminate() }

        let deadline = Date().addingTimeInterval(10)
        while !out.contains("100") && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        // `stty size` prints "rows cols".
        XCTAssertTrue(out.contains("30 100"),
                      "child should see 30 rows × 100 cols at spawn (got \(out.debugDescription))")
    }
}
