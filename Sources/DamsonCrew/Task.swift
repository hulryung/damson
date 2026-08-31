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
    ///
    /// The prompt is appended as the last argument, which is what `claude`, `codex`, `grok`
    /// and `cursor-agent` all take. For a tool that wants it behind a flag, put `{prompt}`
    /// in the command and it is substituted in place instead.
    public let command: [String]?
    /// Git repository to make a worktree in. When set, the worktree's path is used as the
    /// working directory and `cwd` is ignored.
    public let repo: String?
    /// Branch for the worktree. Defaults to the task name.
    public let branch: String?
    /// What to branch from. Defaults to whatever the repo currently has checked out.
    public let base: String?

    public init(name: String, cwd: String? = nil, prompt: String? = nil,
                command: [String]? = nil, repo: String? = nil,
                branch: String? = nil, base: String? = nil) {
        self.name = name
        self.cwd = cwd
        self.prompt = prompt
        self.command = command
        self.repo = repo
        self.branch = branch
        self.base = base
    }

    /// The branch this task wants, when it wants a worktree at all.
    public var worktreeBranch: String? {
        guard repo != nil else { return nil }
        let b = (branch ?? name).trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? name : b
    }

    /// Where the agent should run, as a path the OS will accept.
    ///
    /// A task list is written by a human, so it contains `~`. damson `chdir`s to whatever it
    /// is given and **discards the failure**, so an unexpanded tilde does not error — the
    /// pane just opens somewhere else, and an agent quietly works in the wrong directory.
    public var resolvedCWD: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return cwd.hasPrefix("~") ? (cwd as NSString).expandingTildeInPath : cwd
    }

    /// What to run in the pane.
    ///
    /// `{prompt}` is substituted where it appears; otherwise the prompt is appended last,
    /// which is the shape `claude`, `codex`, `grok` and `cursor-agent` all accept. Keeping
    /// append as the default is what makes a task list portable across them without a
    /// per-tool table that would go stale.
    public func argv(defaultCommand: [String]) -> [String] {
        let base = (command?.isEmpty == false) ? command! : defaultCommand
        let text = prompt ?? ""
        if base.contains(where: { $0.contains("{prompt}") }) {
            return base.map { $0.replacingOccurrences(of: "{prompt}", with: text) }
        }
        return text.isEmpty ? base : base + [text]
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
        case placeholderWithoutPrompt(String)

        public var description: String {
            switch self {
            case .notJSON(let why):      return "could not read the task list: \(why)"
            case .empty:                 return "the task list is empty"
            case .blankName(let i):      return "task \(i) has no name"
            case .duplicateName(let n):  return "two tasks are both named '\(n)'"
            case .placeholderWithoutPrompt(let n):
                return "task '\(n)' uses {prompt} in its command but has no prompt"
            }
        }
    }

    /// Parse and validate. A name is not decoration: it is the tab label AND the spawn key,
    /// so a blank or duplicated one would silently collapse two tasks into one pane — the
    /// second spawn would be answered with the first one's tab and the work would never run.
    /// Reject a `{prompt}` placeholder on a task that has no prompt: it would expand to an
    /// empty argument, which most CLIs read as "an empty first prompt" rather than "none".
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
            // A placeholder with nothing to put in it expands to an empty argument, which
            // most CLIs read as "an empty prompt" rather than "no prompt" — a run that looks
            // fine and does nothing.
            if task.command?.contains(where: { $0.contains("{prompt}") }) == true,
               (task.prompt ?? "").isEmpty {
                throw ParseError.placeholderWithoutPrompt(name)
            }
        }
        return TaskList(tasks: tasks)
    }
}
