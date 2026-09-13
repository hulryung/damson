import Darwin

/// SIGPIPE policy for the damson process and the programs it starts in panes.
///
/// A write to a pipe or socket whose reader has gone away raises SIGPIPE, and its default
/// action is to terminate the writer — silently, with no crash report. For a terminal the
/// writer is the whole app: every window, every pane, every program running in them. 0.7.1
/// did exactly that after 7.6 hours, overnight with the display asleep: launchd recorded
/// "exited due to SIGPIPE | sent by damson". Sockets were already guarded one at a time with
/// SO_NOSIGPIPE, but that option does not exist for pipes, and one missed socket is enough.
public enum BrokenPipes {
    /// Ignore SIGPIPE in this process, so a broken pipe comes back from `write()` as EPIPE —
    /// an error every write path here already treats as "peer gone". Call once, first thing.
    public static func ignoreInThisProcess() {
        signal(SIGPIPE, SIG_IGN)
    }

    /// Put the default back in a freshly forked child, before it execs. An ignored signal
    /// stays ignored across `execve`, so without this every shell in a pane would start
    /// with SIGPIPE ignored, and `yes | head` would end in "yes: stdout: Broken pipe"
    /// instead of `yes` quietly stopping. `signal` is async-signal-safe, so this is safe
    /// between fork and exec.
    @inline(__always)
    public static func restoreDefaultInChild() {
        signal(SIGPIPE, SIG_DFL)
    }
}
