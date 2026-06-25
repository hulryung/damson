import Foundation

/// A git worktree allocated for an agent's task.
public struct Worktree: Equatable, Sendable {
    public let id: UUID
    public let baseRepo: URL   // main repo root
    public let path: URL       // worktree directory
    public let branch: String

    public init(id: UUID = UUID(), baseRepo: URL, path: URL, branch: String) {
        self.id = id
        self.baseRepo = baseRepo
        self.path = path
        self.branch = branch
    }
}

public struct GitError: Error, CustomStringConvertible {
    public let message: String
    public init(_ m: String) { self.message = m }
    public var description: String { message }
}

/// Creates and tears down git worktrees so each agent works in isolation. This is the
/// only component that shells out to `git`. All mutations of a base repo's
/// `.git/worktrees` are serialized to avoid index-lock races between parallel agents.
public final class WorktreeManager {
    /// Where worktrees are created (outside the user's repo to avoid watcher/ignore noise).
    public let root: URL
    private let queue = DispatchQueue(label: "damson.orchestrator.worktree")
    private let gitPath: String

    public init(root: URL) {
        self.root = root
        self.gitPath = Self.resolveGit()
    }

    /// Resolve `git` absolutely — a GUI-launched app has a minimal PATH.
    private static func resolveGit() -> String {
        for path in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/usr/bin/git"
    }

    // MARK: - Public API

    /// Resolve the repo root containing `cwd` (`git rev-parse --show-toplevel`).
    public func detectBaseRepo(from cwd: URL) throws -> URL {
        let out = try run(["-C", cwd.path, "rev-parse", "--show-toplevel"], cwd: nil)
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitError("not a git repository: \(cwd.path)") }
        return URL(fileURLWithPath: trimmed)
    }

    /// Resolve a ref (e.g. "HEAD") to a commit SHA, so all agents fork from one pinned base.
    public func resolveRef(_ ref: String, in repo: URL) throws -> String {
        let out = try run(["-C", repo.path, "rev-parse", ref], cwd: nil)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Refuse to proceed if the repo is mid-rebase/merge or otherwise not in a clean state
    /// to fork from. Surfaces a clear error rather than half-creating worktrees.
    public func validateReady(_ repo: URL) throws {
        let gitDir = try run(["-C", repo.path, "rev-parse", "--git-dir"], cwd: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = URL(fileURLWithPath: gitDir, relativeTo: repo)
        let fm = FileManager.default
        for marker in ["rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD"] {
            if fm.fileExists(atPath: base.appendingPathComponent(marker).path) {
                throw GitError("repo is mid-operation (\(marker)); resolve it before orchestrating")
            }
        }
    }

    /// Create a worktree on a new branch forked from `ref`.
    public func create(base: URL, branch: String, from ref: String) throws -> Worktree {
        try queue.sync {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let id = UUID()
            let dir = root.appendingPathComponent("\(branch.replacingOccurrences(of: "/", with: "_"))-\(id.uuidString.prefix(8))")
            _ = try run(["-C", base.path, "worktree", "add", "-b", branch, dir.path, ref], cwd: nil)
            return Worktree(id: id, baseRepo: base, path: dir, branch: branch)
        }
    }

    /// Remove a worktree. By default a dirty worktree is preserved (returns false) so the
    /// user can inspect/merge; pass `force: true` to discard uncommitted work.
    @discardableResult
    public func remove(_ wt: Worktree, force: Bool = false) throws -> Bool {
        try queue.sync {
            var args = ["-C", wt.baseRepo.path, "worktree", "remove", wt.path.path]
            if force { args.append("--force") }
            do {
                _ = try run(args, cwd: nil)
                return true
            } catch {
                if !force { return false } // likely dirty; keep it
                throw error
            }
        }
    }

    /// Ensure `pattern` is in the repo's local `.git/info/exclude` (no commit, no change to
    /// the tracked `.gitignore`) so in-repo worktrees never show up in `git status`.
    public func ensureExcluded(_ pattern: String, in repo: URL) {
        guard let gitDir = try? run(["-C", repo.path, "rev-parse", "--git-dir"], cwd: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines), !gitDir.isEmpty else { return }
        let infoDir = URL(fileURLWithPath: gitDir, relativeTo: repo).appendingPathComponent("info")
        try? FileManager.default.createDirectory(at: infoDir, withIntermediateDirectories: true)
        let excludeFile = infoDir.appendingPathComponent("exclude")
        let existing = (try? String(contentsOf: excludeFile, encoding: .utf8)) ?? ""
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.contains(pattern) { return }
        let appended = existing.isEmpty ? "\(pattern)\n" : (existing.hasSuffix("\n") ? "\(existing)\(pattern)\n" : "\(existing)\n\(pattern)\n")
        try? appended.write(to: excludeFile, atomically: true, encoding: .utf8)
    }

    /// Drop stale worktree administrative entries left by crashes.
    public func prune(base: URL) {
        _ = try? queue.sync { try run(["-C", base.path, "worktree", "prune"], cwd: nil) }
    }

    /// List worktree paths currently registered for `base`.
    public func list(base: URL) throws -> [String] {
        let out = try run(["-C", base.path, "worktree", "list", "--porcelain"], cwd: nil)
        return out.split(separator: "\n").compactMap { line in
            line.hasPrefix("worktree ") ? String(line.dropFirst("worktree ".count)) : nil
        }
    }

    // MARK: - Process

    @discardableResult
    private func run(_ args: [String], cwd: URL?) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: gitPath)
        proc.arguments = args
        if let cwd { proc.currentDirectoryURL = cwd }
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            throw GitError("failed to launch git: \(error.localizedDescription)")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw GitError("git \(args.joined(separator: " ")) failed (\(proc.terminationStatus)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return stdout
    }
}
