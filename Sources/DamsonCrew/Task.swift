import Foundation

/// One unit of work the coordinator opens a tab for.
///
/// The prompt is carried here and handed to the agent **in argv**. It is never typed into a
/// pane: `session.write` into a live TUI has no delivery acknowledgment of any kind, so a
/// prompt sent before the TUI reaches its input box lands nowhere and nothing can tell.
public struct CrewTask: Codable, Equatable, Sendable {
    /// Identifies the task. Doubles as the tab label and as the spawn's idempotency key, so
    /// re-running a list reattaches to the tabs it already opened instead of duplicating them.
    public let name: String
    public let cwd: String?
    public let prompt: String?
    /// Overrides the agent command for this task. Defaults to `claude`.
    public let command: [String]?

    public init(name: String, cwd: String? = nil, prompt: String? = nil, command: [String]? = nil) {
        self.name = name
        self.cwd = cwd
        self.prompt = prompt
        self.command = command
    }

    /// What to run in the pane. The prompt goes last, as an argument.
    public func argv(defaultCommand: [String]) -> [String] {
        var out = (command?.isEmpty == false) ? command! : defaultCommand
        if let prompt, !prompt.isEmpty { out.append(prompt) }
        return out
    }
}

/// A parsed task list, with the problems that would have produced a broken run reported
/// rather than silently tolerated.
public struct TaskList: Equatable {
    public let tasks: [CrewTask]

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case notJSON(String)
        case empty
        case blankName(index: Int)
        case duplicateName(String)

        public var description: String {
            switch self {
            case .notJSON(let why):      return "could not read the task list: \(why)"
            case .empty:                 return "the task list is empty"
            case .blankName(let i):      return "task \(i) has no name"
            case .duplicateName(let n):  return "two tasks are both named '\(n)'"
            }
        }
    }

    /// Parse and validate. A name is not decoration: it is the tab label AND the spawn key,
    /// so a blank or duplicated one would silently collapse two tasks into one pane — the
    /// second spawn would be answered with the first one's tab and the work would never run.
    public static func parse(_ data: Data) throws -> TaskList {
        let tasks: [CrewTask]
        do {
            tasks = try JSONDecoder().decode([CrewTask].self, from: data)
        } catch {
            throw ParseError.notJSON(String(describing: error))
        }
        guard !tasks.isEmpty else { throw ParseError.empty }
        var seen = Set<String>()
        for (i, task) in tasks.enumerated() {
            let name = task.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw ParseError.blankName(index: i) }
            guard seen.insert(name).inserted else { throw ParseError.duplicateName(name) }
        }
        return TaskList(tasks: tasks)
    }
}
