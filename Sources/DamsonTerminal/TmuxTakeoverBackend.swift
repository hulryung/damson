import Foundation

/// A `SessionIOBackend` that bridges an EXISTING session's PTY into a `TmuxControlClient`,
/// for the DCS auto-detect path: the user typed `tmux -CC …` in a normal Damson pane, the
/// VT parser spotted the control-mode introducer, and from then on that pane's byte stream
/// IS the tmux control protocol.
///
/// - reads: the session forwards raw post-DCS bytes via `onTmuxControlData` → `onData`.
/// - writes: control commands go to `session.write` — the same PTY, reaching the tmux
///   client's stdin.
/// - `spawn` is a no-op (the tmux client is already running inside the session's shell).
/// - `terminate` is a no-op: the PTY hosts the USER'S shell underneath the tmux client;
///   killing it on tmux teardown would kill the shell. Detaching is done in-protocol
///   (`detach-client`), after which `%exit` ends control mode and the shell prompt returns.
public final class TmuxTakeoverBackend: SessionIOBackend {
    public var onData: ((Data) -> Void)?
    public var onExit: ((Int32) -> Void)?

    private weak var session: DamsonSession?

    /// Install over `session` — MUST be created inside (or before) the takeover
    /// notification so the first control bytes after the DCS introducer land here.
    public init(session: DamsonSession) {
        self.session = session
        session.onTmuxControlData = { [weak self] data in
            self?.onData?(data)
        }
    }

    public func spawn(argv: [String], env: [String: String], cwd: String?, cols: Int, rows: Int) throws {
        // no-op — the tmux -CC client is already running in the session's shell.
    }

    public func write(_ data: Data) {
        session?.write(data)
    }

    /// Control-mode size is negotiated via `refresh-client -C`, never the PTY winsize.
    public func resize(cols: Int, rows: Int) {}

    /// Never kill the underlying PTY — it's the user's shell. See the type comment.
    public func terminate() {}

    public var childWorkingDirectory: String? { nil }
    public var isRunningForegroundJob: Bool { false }
}
