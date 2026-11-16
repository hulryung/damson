import Foundation

/// One on-demand snapshot of a pane's folder: Git state and the TCP listeners owned by
/// the pane's foreground job. Every "could not tell" is its own case, so the panel never
/// renders a failure as "not a repository" or "no services".
public struct ProjectSnapshot: Equatable {
    public enum Git: Equatable {
        case folderMissing
        case gitMissing
        case notRepository
        /// Inside a `.git` directory or a bare repository: Git, but no work tree to count.
        case notWorkTree
        case failed(String)
        case repository(root: String, branch: Branch, changes: Changes)
    }
    public enum Branch: Equatable {
        case named(String)
        case detached(commit: String?)
        case unavailable(String)
    }
    public enum Changes: Equatable {
        case count(Int)
        /// Status output passed the cap; at least this many paths were seen.
        case atLeast(Int)
        case unavailable(String)
    }
    public struct Listener: Equatable {
        public let pid: Int32
        public let command: String
        public let address: String
        public init(pid: Int32, command: String, address: String) {
            self.pid = pid
            self.command = command
            self.address = address
        }
    }
    public enum Listeners: Equatable {
        /// The session has no tty to ask, so ownership is unknown and nothing is listed.
        case ownershipUnknown
        case processGone(group: Int32)
        case listed(group: Int32, [Listener])
        case unavailable(group: Int32, String)
    }

    public let folder: String
    public let git: Git
    public let listeners: Listeners

    public init(folder: String, git: Git, listeners: Listeners) {
        self.folder = folder
        self.git = git
        self.listeners = listeners
    }

    // MARK: - Collection

    /// Blocking: runs git and lsof. Call off the main thread.
    public static func collect(folder: String, processGroup: Int32?,
                               runner: ProbeRunner = ProbeRunner()) -> ProjectSnapshot {
        let git = gitExecutable(isExecutable: FileManager.default.isExecutableFile(atPath:),
                                developerToolsInstalled: { developerToolsInstalled(runner: runner) })
        return collect(folder: folder, processGroup: processGroup, git: git,
                       run: runner.run, groupExists: processGroupExists)
    }

    /// The testable core: every process and liveness question goes through the closures.
    public static func collect(folder: String, processGroup: Int32?, git: String?,
                               run: (String, [String]) -> ProbeResult,
                               groupExists: (Int32) -> Bool) -> ProjectSnapshot {
        ProjectSnapshot(folder: folder,
                        git: gitState(folder: folder, git: git, run: run),
                        listeners: listenerState(group: processGroup, run: run, groupExists: groupExists))
    }

    /// `/usr/bin/git` is an xcrun shim: without developer tools it pops the "install
    /// command line developer tools" dialog instead of answering. Use it only when the
    /// tools are present, and fall back to a Homebrew git otherwise.
    public static func gitExecutable(isExecutable: (String) -> Bool,
                                     developerToolsInstalled: () -> Bool) -> String? {
        if isExecutable("/usr/bin/git"), developerToolsInstalled() { return "/usr/bin/git" }
        return ["/opt/homebrew/bin/git", "/usr/local/bin/git"].first(where: isExecutable)
    }

    static func developerToolsInstalled(runner: ProbeRunner) -> Bool {
        let result = runner.run("/usr/bin/xcode-select", ["-p"])
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        var isDirectory: ObjCBool = false
        return result.succeeded && !path.isEmpty
            && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public static func processGroupExists(_ group: Int32) -> Bool {
        group > 0 && (kill(-group, 0) == 0 || errno == EPERM)
    }

    static func gitState(folder: String, git: String?, run: (String, [String]) -> ProbeResult) -> Git {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .folderMissing
        }
        guard let git else { return .gitMissing }
        let top = run(git, ["-C", folder, "rev-parse", "--show-toplevel"])
        guard top.succeeded else {
            if case .exited = top.outcome {
                if top.stderr.contains("not a git repository") { return .notRepository }
                if top.stderr.contains("must be run in a work tree") { return .notWorkTree }
            }
            return .failed(top.failureReason)
        }
        let root = top.output.trimmingCharacters(in: .whitespacesAndNewlines)

        let current = run(git, ["-C", folder, "branch", "--show-current"])
        let name = current.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch: Branch
        if !current.succeeded {
            branch = .unavailable(current.failureReason)
        } else if !name.isEmpty {
            branch = .named(name)
        } else {
            let head = run(git, ["-C", folder, "rev-parse", "--short", "HEAD"])
            let commit = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
            branch = .detached(commit: head.succeeded && !commit.isEmpty ? commit : nil)
        }

        let status = run(git, ["-C", folder, "status", "--porcelain=v1", "-z"])
        let changes: Changes
        switch status.outcome {
        case .exited(0): changes = .count(changedPathCount(porcelainZ: status.stdout, complete: true))
        case .truncated: changes = .atLeast(changedPathCount(porcelainZ: status.stdout, complete: false))
        default: changes = .unavailable(status.failureReason)
        }
        return .repository(root: root, branch: branch, changes: changes)
    }

    /// Paths in `git status --porcelain=v1 -z`. A rename or copy is one change carried in
    /// two records (`XY new\0old\0`). When `complete` is false the last record may be cut
    /// off, so it is not counted.
    public static func changedPathCount(porcelainZ data: Data, complete: Bool) -> Int {
        var records = data.split(separator: 0, omittingEmptySubsequences: false)
        if records.last?.isEmpty == true { records.removeLast() }   // trailing NUL
        else if !complete, !records.isEmpty { records.removeLast() }
        var count = 0, index = 0
        while index < records.count {
            let code = records[index].prefix(2)
            count += 1
            index += code.contains(UInt8(ascii: "R")) || code.contains(UInt8(ascii: "C")) ? 2 : 1
        }
        return count
    }

    static func listenerState(group: Int32?, run: (String, [String]) -> ProbeResult,
                              groupExists: (Int32) -> Bool) -> Listeners {
        guard let group, group > 0 else { return .ownershipUnknown }
        guard groupExists(group) else { return .processGone(group: group) }
        // `-g`, not `-p`: the tty reports a process GROUP. `npm run dev` leads the group
        // while the node child it starts owns the socket; `-p` would miss it.
        let result = run("/usr/sbin/lsof", ["-nP", "-a", "-g", String(group), "-iTCP", "-sTCP:LISTEN", "-Fpcn"])
        // lsof exits 1 with no output when nothing matched; a real error says so on
        // stderr. Its WARNING lines (an unreachable mount, say) are not errors.
        let errors = result.stderr.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("lsof: WARNING") }
        if result.succeeded || (result.outcome == .exited(1) && result.stdout.isEmpty && errors.isEmpty) {
            return .listed(group: group, parseLsof(result.output))
        }
        return .unavailable(group: group, result.failureReason)
    }

    /// `lsof -F pcn` field output: `p<pid>`, `c<command>`, then `f`/`n` per descriptor.
    public static func parseLsof(_ output: String) -> [Listener] {
        var listeners: [Listener] = []
        var pid: Int32?, command = ""
        for line in output.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value); command = ""
            case "c": command = value
            case "n":
                guard let pid, !value.isEmpty else { continue }
                let listener = Listener(pid: pid, command: command, address: value)
                if !listeners.contains(listener) { listeners.append(listener) }
            default: continue
            }
        }
        return listeners
    }

    /// Ports a local browser could reach: only loopback or wildcard binds, and only from
    /// listeners whose owner is known. A port says nothing about the protocol.
    public static func browserCandidatePorts(_ listeners: [Listener]) -> [Int] {
        let local: Set<String> = ["*", "127.0.0.1", "0.0.0.0", "[::1]", "[::]", "localhost"]
        let ports = listeners.compactMap { listener -> Int? in
            guard let colon = listener.address.lastIndex(of: ":"),
                  local.contains(String(listener.address[..<colon])),
                  let port = Int(listener.address[listener.address.index(after: colon)...]),
                  (1...65535).contains(port) else { return nil }
            return port
        }
        return Array(Set(ports)).sorted()
    }

    // MARK: - Rendering

    public func render() -> String {
        var lines = ["Folder: \(folder)", ""]
        switch git {
        case .folderMissing: lines.append("Git: folder no longer exists")
        case .gitMissing: lines.append("Git: not installed (install the command line developer tools or Homebrew git)")
        case .notRepository: lines.append("Git: this folder is not a repository")
        case .notWorkTree: lines.append("Git: inside a Git directory or bare repository, no work tree")
        case .failed(let reason): lines.append("Git: unavailable (\(reason))")
        case let .repository(root, branch, changes):
            lines.append("Repository: \(root)")
            switch branch {
            case .named(let name): lines.append("Branch: \(name)")
            case .detached(let commit): lines.append("Branch: detached HEAD\(commit.map { " at \($0)" } ?? "")")
            case .unavailable(let reason): lines.append("Branch: unavailable (\(reason))")
            }
            switch changes {
            case .count(let count): lines.append("Changed files: \(count)")
            case .atLeast(let count): lines.append("Changed files: more than \(count) (status output too large to count)")
            case .unavailable(let reason): lines.append("Changed files: unavailable (\(reason))")
            }
        }
        lines.append("")
        switch listeners {
        case .ownershipUnknown:
            lines.append("Listening services: process ownership unavailable for this session")
        case .processGone(let group):
            lines.append("Listening services: foreground process group \(group) has exited")
        case let .unavailable(group, reason):
            lines.append("Listening services of foreground process group \(group): unavailable (\(reason))")
        case let .listed(group, found):
            lines.append("TCP listeners of this pane's foreground job (process group \(group)):")
            if found.isEmpty { lines.append("None found") }
            lines += found.map { "• \($0.address)  \($0.command.isEmpty ? "pid" : $0.command) \($0.pid)" }
            let ports = Self.browserCandidatePorts(found)
            if !ports.isEmpty {
                lines += ["", "Try in browser (HTTP protocol not verified):"]
                lines += ports.map { "http://localhost:\($0)" }
            }
            if !found.isEmpty { lines.append("TCP listeners are not necessarily HTTP services.") }
        }
        lines += ["", "Snapshot only; Refresh checks this same folder again."]
        return lines.joined(separator: "\n")
    }
}
