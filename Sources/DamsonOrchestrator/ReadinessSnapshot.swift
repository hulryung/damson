import Foundation

/// An immutable view of an agent session at one instant, fed to `ReadinessDetector`
/// and to each `AgentEngine.classify`. Deliberately decoupled from `DamsonSession`
/// so the detector is unit-testable with synthetic snapshots and recorded replays.
public struct ReadinessSnapshot: Sendable {
    /// Visible grid rows as plain text, top to bottom (trailing blanks trimmed per row).
    public let lines: [String]
    public let cursorRow: Int
    public let cursorCol: Int
    public let cols: Int
    public let rows: Int
    public let isAltScreen: Bool

    /// Seconds since the last output byte arrived (output quiescence).
    public let timeSinceLastData: TimeInterval
    /// Seconds since the last DECSET-2026 synchronized-output frame edge.
    /// `.infinity` if no sync frame has ever been seen (engine isn't using sync output).
    public let timeSinceLastSyncFrame: TimeInterval
    /// Seconds since the session process was spawned.
    public let timeSinceSpawn: TimeInterval

    public let processExited: Bool
    public let exitCode: Int32?

    /// Whether a foreground job other than the shell is running (PTY `tcgetpgrp`).
    public let isRunningForegroundJob: Bool
    /// Whether a new OSC 133 prompt mark appeared since the current task was delivered.
    public let newPromptMarkSinceTaskStart: Bool

    public init(
        lines: [String],
        cursorRow: Int,
        cursorCol: Int,
        cols: Int,
        rows: Int,
        isAltScreen: Bool,
        timeSinceLastData: TimeInterval,
        timeSinceLastSyncFrame: TimeInterval,
        timeSinceSpawn: TimeInterval,
        processExited: Bool,
        exitCode: Int32?,
        isRunningForegroundJob: Bool,
        newPromptMarkSinceTaskStart: Bool
    ) {
        self.lines = lines
        self.cursorRow = cursorRow
        self.cursorCol = cursorCol
        self.cols = cols
        self.rows = rows
        self.isAltScreen = isAltScreen
        self.timeSinceLastData = timeSinceLastData
        self.timeSinceLastSyncFrame = timeSinceLastSyncFrame
        self.timeSinceSpawn = timeSinceSpawn
        self.processExited = processExited
        self.exitCode = exitCode
        self.isRunningForegroundJob = isRunningForegroundJob
        self.newPromptMarkSinceTaskStart = newPromptMarkSinceTaskStart
    }

    /// The bottom `n` non-empty lines (where agent TUIs draw their input/approval region).
    public func bottomLines(_ n: Int) -> [String] {
        let nonBlank = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return Array(nonBlank.suffix(n))
    }
}
