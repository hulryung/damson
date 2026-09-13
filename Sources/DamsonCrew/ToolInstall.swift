import Foundation

/// Putting damson's command-line tools where a shell can find them.
///
/// The tools ship inside the app bundle, which is not on anyone's PATH, so until now using
/// `damson-crew` at all meant knowing it lives in `Contents/Resources` — and the one script
/// that linked them wrote to `/usr/local/bin`, which needs `sudo`. This is the same job done
/// where the user already is: a symlink, so the tools follow the app across updates instead
/// of ageing into a copy that answers a protocol the app no longer speaks.
public enum ToolInstall {
    /// The tools a full install puts on PATH.
    public static let tools = ["damson-cli", "damson-crew", "damson-computer"]

    public enum State: Equatable {
        /// A symlink to this app's copy. Nothing to do.
        case installed
        /// Nothing by that name.
        case missing
        /// A symlink to something else — usually a bundle an earlier install pointed at.
        /// Left alone it runs an old CLI against a new app, silently.
        case outdated(String)
        /// A real file, not a link. Someone else's tool of the same name; not ours to replace.
        case blocked
        /// This app bundle does not carry the tool.
        case unavailable
    }

    public struct Status: Equatable {
        public let tool: String
        public let state: State
        public init(tool: String, state: State) {
            self.tool = tool
            self.state = state
        }
        public var needsInstall: Bool {
            switch state {
            case .missing, .outdated: return true
            case .installed, .blocked, .unavailable: return false
            }
        }
    }

    public struct BinChoice: Equatable {
        public let url: URL
        /// False when the shell would not find the tools there, which the caller must say
        /// out loud: an install the user cannot use looks exactly like a working one.
        public let onPath: Bool
    }

    /// Where a user's own binaries go, in the order worth trying. `/usr/local/bin` is
    /// deliberately absent: it needs `sudo`, which an app cannot ask for quietly.
    public static func defaultCandidates(home: URL = URL(fileURLWithPath: NSHomeDirectory()))
        -> [URL] {
        [home.appendingPathComponent(".local/bin"), home.appendingPathComponent("bin")]
    }

    /// The first candidate that is on PATH and writable; failing that, the first writable
    /// one; failing that, the first. A folder that does not exist yet counts as writable —
    /// `install` creates it.
    public static func chooseBinDirectory(candidates: [URL], pathEntries: [String]) -> BinChoice {
        let path = Set(pathEntries.map { ($0 as NSString).standardizingPath })
        func usable(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                return true   // not there yet; we create it
            }
            return isDir.boolValue && FileManager.default.isWritableFile(atPath: url.path)
        }
        func onPath(_ url: URL) -> Bool { path.contains((url.path as NSString).standardizingPath) }

        if let best = candidates.first(where: { usable($0) && onPath($0) }) {
            return BinChoice(url: best, onPath: true)
        }
        let fallback = candidates.first(where: usable) ?? candidates[0]
        return BinChoice(url: fallback, onPath: onPath(fallback))
    }

    /// PATH as the user's shell has it, split into entries.
    public static func pathEntries(_ path: String? = ProcessInfo.processInfo.environment["PATH"])
        -> [String] {
        (path ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    public static func status(tools: [String] = ToolInstall.tools,
                              source: URL, binDir: URL) -> [Status] {
        tools.map { tool in
            let from = source.appendingPathComponent(tool)
            guard FileManager.default.fileExists(atPath: from.path) else {
                return Status(tool: tool, state: .unavailable)
            }
            let link = binDir.appendingPathComponent(tool)
            guard let target = try? FileManager.default
                .destinationOfSymbolicLink(atPath: link.path) else {
                // No link. Either nothing is there, or something that is not ours.
                let exists = FileManager.default.fileExists(atPath: link.path)
                return Status(tool: tool, state: exists ? .blocked : .missing)
            }
            let resolved = target.hasPrefix("/")
                ? target : binDir.appendingPathComponent(target).path
            return Status(tool: tool,
                          state: (resolved as NSString).standardizingPath
                              == (from.path as NSString).standardizingPath
                              ? .installed : .outdated(target))
        }
    }

    /// The one thing to say about the whole set. `outdated` is deliberately distinct from
    /// `notInstalled`: links pointing at another copy of Damson are the case where the shell
    /// runs a CLI from a bundle that may be months older than the app, and calling that
    /// "not installed" would tell the user the opposite of what is wrong.
    public enum Overall: Equatable {
        case installed
        case notInstalled
        case outdated
        case partial(Int)
        case blocked
        case unavailable
    }

    public static func overall(_ statuses: [Status]) -> Overall {
        guard !statuses.isEmpty else { return .notInstalled }
        if statuses.contains(where: { $0.state == .blocked }) { return .blocked }
        if statuses.contains(where: { $0.state == .unavailable }) { return .unavailable }
        let pending = statuses.filter(\.needsInstall)
        if pending.isEmpty { return .installed }
        if pending.count == statuses.count {
            let allOutdated = pending.allSatisfy {
                if case .outdated = $0.state { return true } else { return false }
            }
            return allOutdated ? .outdated : (pending.allSatisfy { $0.state == .missing }
                                              ? .notInstalled : .partial(pending.count))
        }
        return .partial(pending.count)
    }

    /// Codex has no plugin system; a file in `~/.codex/prompts` becomes a slash command.
    /// Copy it there, and report whether anything changed so the UI can say "up to date"
    /// instead of claiming an install every time it is clicked.
    @discardableResult
    public static func installPrompt(from source: URL, to destination: URL) throws -> Bool {
        let text = try String(contentsOf: source, encoding: .utf8)
        if let existing = try? String(contentsOf: destination, encoding: .utf8), existing == text {
            return false
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: destination, atomically: true, encoding: .utf8)
        return true
    }

    public enum Failure: LocalizedError {
        case blocked(String, String)
        case unavailable(String)

        public var errorDescription: String? {
            switch self {
            case .blocked(let tool, let path):
                return "\(path) already exists and is not a link damson made. "
                    + "Remove it yourself if you want damson's \(tool) there."
            case .unavailable(let tool):
                return "This copy of Damson does not contain \(tool)."
            }
        }
    }

    /// Link every tool that needs it. Returns the tools actually written, so the caller can
    /// say "already up to date" rather than claiming work it did not do.
    @discardableResult
    public static func install(tools: [String] = ToolInstall.tools,
                               source: URL, binDir: URL) throws -> [String] {
        let fm = FileManager.default
        let states = status(tools: tools, source: source, binDir: binDir)
        // Refuse the whole install before writing anything: half a set of tools on PATH is
        // worse than none, because the mismatch only shows up mid-run.
        for s in states {
            if case .blocked = s.state {
                throw Failure.blocked(s.tool, binDir.appendingPathComponent(s.tool).path)
            }
            if case .unavailable = s.state { throw Failure.unavailable(s.tool) }
        }
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        var written: [String] = []
        for s in states where s.needsInstall {
            let link = binDir.appendingPathComponent(s.tool)
            if case .outdated = s.state { try fm.removeItem(at: link) }
            try fm.createSymbolicLink(atPath: link.path,
                                      withDestinationPath: source.appendingPathComponent(s.tool).path)
            written.append(s.tool)
        }
        return written
    }
}
