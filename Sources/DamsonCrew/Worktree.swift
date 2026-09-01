import Darwin
import Foundation

/// Runs git. A protocol so the worktree logic — which is where the destructive operations
/// live — can be tested against a script instead of a real repository.
public protocol GitRunner {
    /// Run `git <args>`. Returns stdout on success, or the combined output on failure.
    func run(_ args: [String]) -> Result<String, CrewError>
}

/// Runs the real thing.
public struct SystemGit: GitRunner {
    public init() {}

    public func run(_ args: [String]) -> Result<String, CrewError> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git"] + args
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do { try proc.run() } catch {
            return .failure(CrewError("could not run git: \(error)"))
        }
        // Read before waiting: a pipe that fills while we wait deadlocks the child.
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let message = (stderr.isEmpty ? stdout : stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(CrewError(message.isEmpty ? "git \(args.joined(separator: " ")) failed" : message))
        }
        return .success(stdout)
    }
}

/// One worktree as git reports it.
public struct Worktree: Equatable {
    public let path: String
    /// The checked-out branch, without `refs/heads/`. nil for a detached HEAD.
    public let branch: String?
}

/// Creates and removes git worktrees so a coordinator can put **any** agent CLI in one.
///
/// This exists because worktree support is per-tool and inconsistent: `claude -w`,
/// `grok --worktree=<name>`, and nothing at all in `codex` or `cursor-agent`. Doing it here
/// once means a task list can name a repo and a branch and every one of them works, because
/// all any of them needs is to be started in the right directory.
public struct WorktreeManager {
    private let git: GitRunner
    /// Where a repo's worktrees are kept. Default: a sibling of the repo named
    /// `<repo>-worktrees`, so they are obviously related, visible, and — importantly — not
    /// inside the repo, where they would show up in its own status and file searches.
    private let rootFor: (String) -> String

    public init(git: GitRunner = SystemGit(),
                rootFor: @escaping (String) -> String = WorktreeManager.defaultRoot) {
        self.git = git
        self.rootFor = rootFor
    }

    /// `realpath(3)`, not Foundation. `resolvingSymlinksInPath` and `standardizingPath`
    /// both deliberately leave `/var/folders/…` alone — measured — so neither agrees with
    /// what git reports for a worktree under the temporary directory.
    static func realpath(_ path: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard Darwin.realpath(path, &buf) != nil else { return path }
        return String(cString: buf)
    }

    public static func defaultRoot(repo: String) -> String {
        let url = URL(fileURLWithPath: repo)
        return url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + "-worktrees").path
    }

    /// A branch name made safe to use as one directory component. Branches routinely contain
    /// `/` (`agent/review-api`), which would otherwise silently create a nested directory.
    public static func slug(_ branch: String) -> String {
        let mapped = branch.map { ch -> Character in
            ch == "/" || ch == ":" || ch == " " ? "-" : ch
        }
        let s = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return s.isEmpty ? "worktree" : s
    }

    public func list(repo: String) -> Result<[Worktree], CrewError> {
        git.run(["-C", repo, "worktree", "list", "--porcelain"]).map(Self.parseList)
    }

    static func parseList(_ text: String) -> [Worktree] {
        var out: [Worktree] = []
        var path: String?
        var branch: String?
        func flush() {
            if let path { out.append(Worktree(path: path, branch: branch)) }
            path = nil; branch = nil
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                flush()
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            }
        }
        flush()
        return out
    }

    /// The worktree for `branch`, creating it if it is not there yet. Returns its path.
    ///
    /// Idempotent on purpose, like every other step a coordinator takes: re-running a task
    /// list must reattach to the worktree it made last time rather than failing, or making a
    /// second one under a mangled name.
    /// A worktree, and whether this call is what brought it into being.
    public struct Ensured: Equatable {
        public let path: String
        /// False when an existing worktree was reused. Callers that act on a worktree's
        /// newness — pre-accepting a trust prompt, say — must only act on ones they made.
        public let created: Bool
    }

    public func ensure(repo: String, branch: String, base: String?) -> Result<String, CrewError> {
        ensureWorktree(repo: repo, branch: branch, base: base).map(\.path)
    }

    public func ensureWorktree(repo: String, branch: String, base: String?) -> Result<Ensured, CrewError> {
        let expanded = (repo as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
            return .failure(CrewError("no such repository: \(repo)"))
        }
        // Resolved, because `git worktree list` reports resolved paths. Without this the
        // path returned when the worktree is CREATED (computed from the caller's string,
        // `/var/…`) differs from the one returned when it is REUSED (git's, `/private/var/…`)
        // — the same worktree under two names, which breaks every comparison downstream.
        let repoPath = Self.realpath(expanded)
        guard case .success = git.run(["-C", repoPath, "rev-parse", "--git-dir"]) else {
            return .failure(CrewError("not a git repository: \(repo)"))
        }

        switch list(repo: repoPath) {
        case .failure(let e): return .failure(e)
        case .success(let existing):
            if let match = existing.first(where: { $0.branch == branch }) {
                return .success(Ensured(path: match.path, created: false))   // reuse it
            }
        }

        let root = rootFor(repoPath)
        let path = URL(fileURLWithPath: root).appendingPathComponent(Self.slug(branch)).path
        do {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        } catch {
            return .failure(CrewError("could not create \(root): \(error.localizedDescription)"))
        }

        // A branch that already exists is checked out; otherwise it is created off `base`
        // (or whatever the repo has checked out now). Never `--force`: forcing here would
        // move a branch that another worktree — possibly another agent — is sitting on.
        let branchExists = (try? git.run(["-C", repoPath, "rev-parse", "--verify",
                                          "refs/heads/\(branch)"]).get()) != nil
        var args = ["-C", repoPath, "worktree", "add"]
        if branchExists {
            args += [path, branch]
        } else {
            args += ["-b", branch, path]
            if let base, !base.isEmpty { args.append(base) }
        }
        return git.run(args).map { _ in Ensured(path: path, created: true) }
    }

    /// Remove a worktree. **Never forces.**
    ///
    /// `git worktree remove` refuses when the tree is dirty or has untracked files, and that
    /// refusal is the entire safety property here: the contents are an agent's work, and it
    /// is uncommitted precisely when losing it would matter most. A caller that wants the
    /// directory gone anyway can say so to git itself.
    public func remove(repo: String, path: String) -> Result<Void, CrewError> {
        let repoPath = (repo as NSString).expandingTildeInPath
        return git.run(["-C", repoPath, "worktree", "remove", path]).map { _ in () }
    }
}
