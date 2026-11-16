import Foundation

public struct CommandCompletion: Equatable {
    public let exitCode: Int?
    public let duration: TimeInterval
    public let outputStartLine: UInt64
    public let outputEndLine: UInt64
}

/// OSC 133 C/D are explicit lifecycle events; inactivity is never completion.
public struct CommandLifecycle {
    private var start: (time: TimeInterval, line: UInt64)?
    public private(set) var lastCompletion: CommandCompletion?
    public init() {}
    public var isRunning: Bool { start != nil }

    @discardableResult
    public mutating func receive(_ marker: String, status: String? = nil,
                                 line: UInt64, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> CommandCompletion? {
        switch marker {
        case "C":
            if start == nil { start = (now, line) }
        case "D":
            guard let begin = start else { return nil }
            start = nil
            let code = status.flatMap(Int.init).flatMap { (0...255).contains($0) ? $0 : nil }
            let result = CommandCompletion(exitCode: code, duration: max(0, now - begin.time),
                                           outputStartLine: begin.line, outputEndLine: max(begin.line, line))
            lastCompletion = result
            return result
        case "A":
            // If completion was lost, a fresh prompt cancels the pending command,
            // without inventing a successful exit or a completion notification.
            start = nil
        default: break
        }
        return nil
    }
}

/// When a finished command deserves a macOS notification. The app target only wires this
/// to `UNUserNotificationCenter`, so the decision itself is testable here.
public enum CommandNotificationPolicy {
    public static let enabledKey = "damson.commandNotifications"
    public static let thresholdKey = "damson.commandNotificationSeconds"
    public static let defaultThreshold = 10
    public static let thresholdRange = 1...86_400

    /// Seconds a command must run before it notifies; unset or out-of-range values fall
    /// back to (or clamp into) the supported range.
    public static func threshold(_ defaults: UserDefaults = .standard) -> TimeInterval {
        guard defaults.object(forKey: thresholdKey) != nil else { return TimeInterval(defaultThreshold) }
        let value = defaults.integer(forKey: thresholdKey)
        return TimeInterval(min(max(value, thresholdRange.lowerBound), thresholdRange.upperBound))
    }

    /// A pane the user is looking at — focused in the frontmost app — never notifies.
    public static func shouldNotify(_ completion: CommandCompletion, enabled: Bool, threshold: TimeInterval,
                                    appActive: Bool, paneFocused: Bool) -> Bool {
        enabled && completion.duration >= threshold && !(appActive && paneFocused)
    }

    public static func title(for completion: CommandCompletion) -> String {
        let status = completion.exitCode.map { $0 == 0 ? "Succeeded" : "Failed (exit \($0))" } ?? "Finished (status unknown)"
        return "\(status) · \(formatDuration(completion.duration))"
    }

    /// `9s`, `2m 05s`, `1h 03m`.
    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return String(format: "%dm %02ds", total / 60, total % 60) }
        return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60)
    }
}

public enum ReportedAgentState: String, CaseIterable {
    case running, waiting, completed, failed, unknown
}

/// An explicit OSC 777 agent report, tied to the process group that owned the terminal's
/// foreground when it arrived. Hooks run inside the agent's job, so that group is the
/// agent. Once it no longer exists the report speaks for nobody: an agent that crashed
/// after `running` must read as unreported, not as working forever.
public struct AgentReport: Equatable {
    public let state: ReportedAgentState
    public let receivedAt: Date
    /// nil when the backend has no tty to ask (tmux -CC panes, tests); such a report
    /// lasts until `clear`, as before.
    public let ownerProcessGroup: pid_t?

    public init(state: ReportedAgentState, receivedAt: Date, ownerProcessGroup: pid_t?) {
        self.state = state
        self.receivedAt = receivedAt
        self.ownerProcessGroup = ownerProcessGroup
    }

    /// Whether the owning group still exists. EPERM means it exists but is not ours.
    public func isCurrent(groupExists: (pid_t) -> Bool = AgentReport.processGroupExists) -> Bool {
        guard let owner = ownerProcessGroup else { return true }
        return groupExists(owner)
    }

    public static func processGroupExists(_ group: pid_t) -> Bool {
        guard group > 0 else { return false }
        return kill(-group, 0) == 0 || errno == EPERM
    }
}
