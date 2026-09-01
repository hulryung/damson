import Combine
import XCTest
@testable import DamsonTerminal

/// `outputBytes` — the multi-subscriber raw-output stream. `onOutput` is a single
/// clobberable closure: the app claims it, and any second observer (an embedder's logger,
/// an out-of-process mirror) silently steals it from the first. The subject fixes that
/// without touching the closure's contract, so what these tests pin is the equivalence:
/// every chunk, both channels, all subscribers, same bytes, same order.
final class OutputBytesTests: XCTestCase {
    private final class FakeBackend: SessionIOBackend {
        var onData: ((Data) -> Void)?
        var onExit: ((Int32) -> Void)?
        func spawn(argv: [String], env: [String: String], cwd: String?, cols: Int, rows: Int) throws {}
        func write(_ data: Data) {}
        func resize(cols: Int, rows: Int) {}
        func terminate() {}
        var childWorkingDirectory: String? { nil }
        var isRunningForegroundJob: Bool { false }
    }

    func testEverySubscriberSeesEveryChunkAlongsideOnOutput() {
        let backend = FakeBackend()
        let session = DamsonSession(config: DamsonConfig(), backend: backend)

        var closureChunks: [Data] = []
        var subscriberA: [Data] = []
        var subscriberB: [Data] = []
        session.onOutput = { closureChunks.append($0) }
        var cancellables: Set<AnyCancellable> = []
        session.outputBytes.sink { subscriberA.append($0) }.store(in: &cancellables)
        session.outputBytes.sink { subscriberB.append($0) }.store(in: &cancellables)

        let chunks = [Data("hello ".utf8), Data("\u{1B}[31mred\u{1B}[0m".utf8), Data([0xFF, 0x00])]
        for chunk in chunks { backend.onData?(chunk) }

        XCTAssertEqual(closureChunks, chunks, "the existing closure's contract must not move")
        XCTAssertEqual(subscriberA, chunks, "a subscriber gets the raw pre-parse bytes")
        XCTAssertEqual(subscriberB, chunks, "…and a second subscriber does not steal them")
    }

    /// A session nobody subscribes to must behave exactly as before — the subject is
    /// fire-and-forget, never a required hookup.
    func testUnobservedSessionStillParses() {
        let backend = FakeBackend()
        let session = DamsonSession(config: DamsonConfig(), backend: backend)
        backend.onData?(Data("ok".utf8))
        XCTAssertEqual(session.grid.cell(row: 0, col: 0).char, "o")
        XCTAssertEqual(session.grid.cell(row: 0, col: 1).char, "k")
    }
}

/// `launchArgv` records what a session was actually started on, and must not move.
///
/// It is separate from `config.argv` because `updateConfig` replaces the whole config on a
/// settings hot-reload — font, colours, palette — and the replacement carries the configured
/// shell's argv. Reading argv off the live config meant an agent pane began describing itself
/// as a shell the moment the user changed any preference, which also lost it across a restart:
/// the restore blob saves argv, and a shell argv saves as "nothing worth restoring".
final class LaunchArgvTests: XCTestCase {
    private final class FakeBackend: SessionIOBackend {
        var onData: ((Data) -> Void)?
        var onExit: ((Int32) -> Void)?
        func spawn(argv: [String], env: [String: String], cwd: String?, cols: Int, rows: Int) throws {}
        func write(_ data: Data) {}
        func resize(cols: Int, rows: Int) {}
        func terminate() {}
        var childWorkingDirectory: String? { nil }
        var isRunningForegroundJob: Bool { false }
    }

    func testLaunchArgvIsWhatTheSessionStartedOn() {
        var config = DamsonConfig()
        config.argv = ["/opt/homebrew/bin/claude", "--permission-mode", "default"]
        let session = DamsonSession(config: config, backend: FakeBackend())
        XCTAssertEqual(session.launchArgv, ["/opt/homebrew/bin/claude", "--permission-mode", "default"])
    }

    func testASettingsReloadDoesNotRewriteLaunchArgv() {
        var config = DamsonConfig()
        config.argv = ["/opt/homebrew/bin/claude"]
        let session = DamsonSession(config: config, backend: FakeBackend())

        var reloaded = DamsonConfig()          // what a preferences change hands back
        reloaded.argv = ["/bin/zsh", "-l"]
        session.updateConfig(reloaded)

        XCTAssertEqual(session.config.argv, ["/bin/zsh", "-l"], "the live config still updates")
        XCTAssertEqual(session.launchArgv, ["/opt/homebrew/bin/claude"],
                       "an agent pane started describing itself as a shell")
    }
}
