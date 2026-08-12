import Foundation

/// The byte source/sink for a `DamsonSession`, abstracted so the terminal state
/// (Grid + VTParser) doesn't care where bytes originate.
///
/// Local sessions use `PTYHost` (forkpty). A future tmux control-mode backend
/// (`tmux -CC`) will feed bytes from `%output` notifications and route input via
/// `send-keys`, conforming to this same protocol — see `docs/TMUX-INTEGRATION.md`.
///
/// This is the P0 seam: it captures exactly the surface `DamsonSession` already
/// uses on `PTYHost`, with zero behavioral change.
public protocol SessionIOBackend: AnyObject {
    /// Called (on the main queue) with each chunk of output bytes.
    var onData: ((Data) -> Void)? { get set }
    /// Called (on the main queue) when the underlying process exits, with its exit code.
    var onExit: ((Int32) -> Void)? { get set }

    /// Start the backend's process. For a local PTY this forkpty+execve's the shell;
    /// a tmux pane backend treats this as a no-op (tmux already spawned the pane).
    func spawn(argv: [String], env: [String: String], cwd: String?, cols: Int, rows: Int) throws

    /// Send input bytes to the backend (PTY master write / tmux `send-keys`).
    func write(_ data: Data)

    /// Inform the backend of a new size (PTY `TIOCSWINSZ` / tmux `refresh-client -C`).
    func resize(cols: Int, rows: Int)

    /// Tear down the backend.
    func terminate()

    /// The child process's current working directory, if queryable. nil otherwise.
    var childWorkingDirectory: String? { get }

    /// Whether a command other than the shell itself is running in the foreground.
    var isRunningForegroundJob: Bool { get }

    /// The process group owning the backend's terminal, when the backend has one. Lets a
    /// host identify *which program* is running in a pane — the join key between a pane and
    /// an external tool's own process registry. Defaulted to nil, so a backend with no tty
    /// (tmux panes, tests) needs no change; see the extension below.
    var foregroundPID: pid_t? { get }
}

public extension SessionIOBackend {
    /// Default for backends that have no controlling terminal to ask. Declared in the
    /// protocol body as well as here on purpose: that keeps dispatch dynamic (a conformer's
    /// own implementation always wins) while leaving existing conformers — including any
    /// downstream of this library product — source-compatible.
    var foregroundPID: pid_t? { nil }
}
