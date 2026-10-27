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

public enum ReportedAgentState: String, CaseIterable {
    case running, waiting, completed, failed, unknown
}
