import Darwin
import Foundation

/// Ownership lives in git's per-worktree administrative directory, not the checkout.
/// Git removes this record with the worktree, so a replacement at the same path is not
/// accidentally treated as crew-owned. A common-dir flock serializes runs across processes.
struct WorktreeOwnership {
    let git: GitRunner

    private struct Record: Codable {
        var version = 1
        let path: String
        let branch: String
        var owners: Set<String>
    }

    private func owner(_ group: String?) -> String {
        group.map { "group:\($0)" } ?? "ungrouped"
    }

    private func gitPath(_ args: [String]) throws -> String {
        var path = try git.run(args).get()
        if path.hasSuffix("\n") { path.removeLast() }
        guard path.hasPrefix("/") else { throw CrewError("git did not report an absolute metadata path") }
        return path
    }

    func locked<T>(repo: String, _ operation: () throws -> T) -> Result<T, CrewError> {
        do {
            let common = try gitPath(["-C", (repo as NSString).expandingTildeInPath,
                                      "rev-parse", "--path-format=absolute", "--git-common-dir"])
            let lockPath = URL(fileURLWithPath: common).appendingPathComponent("damson-crew.lock").path
            let fd = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw CrewError("cannot open worktree ownership lock: \(lockPath)") }
            defer { close(fd) }
            while flock(fd, LOCK_EX) != 0 {
                if errno != EINTR { throw CrewError("cannot lock worktree ownership: \(lockPath)") }
            }
            defer { flock(fd, LOCK_UN) }
            return .success(try operation())
        } catch let error as CrewError {
            return .failure(error)
        } catch {
            return .failure(CrewError("worktree ownership: \(error.localizedDescription)"))
        }
    }

    private func recordURL(path: String) throws -> URL {
        let directory = try gitPath(["-C", path, "rev-parse", "--absolute-git-dir"])
        return URL(fileURLWithPath: directory).appendingPathComponent("damson-crew-owner.json")
    }

    private func read(_ url: URL, path: String, branch: String) throws -> Record? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        guard record.version == 1, record.path == WorktreeManager.realpath(path),
              record.branch == branch else {
            throw CrewError("worktree ownership does not match this path and branch; preserved \(path)")
        }
        return record
    }

    /// Reusing a user's worktree never adopts it. Only creation may mint a record.
    func register(path: String, branch: String, group: String?, created: Bool) throws {
        let url = try recordURL(path: path)
        var record: Record
        if let existing = try read(url, path: path, branch: branch) {
            record = existing
        } else if created {
            record = Record(path: WorktreeManager.realpath(path), branch: branch, owners: [])
        } else {
            return
        }
        if record.owners.insert(owner(group)).inserted {
            try JSONEncoder().encode(record).write(to: url, options: .atomic)
        }
    }

    /// Called under the repository lock. Keep the final owner's record on any refusal,
    /// so cleanup can be retried after the user saves their work or stops another pane.
    func remove(repo: String, path: String, branch: String, group: String?,
                inUse: (String) throws -> Bool) throws {
        let url = try recordURL(path: path)
        guard var record = try read(url, path: path, branch: branch) else {
            throw CrewError("not created by damson-crew; preserved \(path)")
        }
        guard record.owners.contains(owner(group)) else {
            throw CrewError("worktree is not owned by this run; preserved \(path)")
        }
        if record.owners.count > 1 {
            record.owners.remove(owner(group))
            try JSONEncoder().encode(record).write(to: url, options: .atomic)
            throw CrewError("released this run's ownership; worktree is still shared by another run")
        }
        guard try !inUse(path) else { throw CrewError("worktree is still used by an open pane; preserved \(path)") }
        _ = try git.run(["-C", (repo as NSString).expandingTildeInPath, "worktree", "remove", path]).get()
    }
}
