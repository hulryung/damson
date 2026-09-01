import Foundation

/// Pre-accepts Claude Code's workspace-trust prompt for a worktree damson-crew just created.
///
/// **Why this is needed.** Claude Code prompts on a git repository root it has not seen
/// before — measured: a plain directory under a trusted parent does not prompt, a fresh git
/// repo does, and trust is not inherited. A git worktree is a repository root by definition,
/// so a fan-out that makes one worktree per task hits the prompt once per task and stops
/// dead, with every agent waiting on a keypress.
///
/// **Why it is defensible.** The directory is a checkout of a repository the user named in
/// their own task list, created seconds earlier by damson-crew. It is not an unknown folder,
/// and it contains nothing they did not already have.
///
/// **Why it is careful.** This writes another product's config file, which holds the user's
/// whole Claude Code state. damson has no way to restore what it damages, so it refuses on
/// anything it does not fully understand: no file, unparseable content, or an unexpected
/// shape all mean "leave it alone" rather than "write what we think it should be".
public enum WorkspaceTrust {
    public static let backupSuffix = ".damson-backup"

    public static func defaultConfigPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json")
    }

    /// Mark `path` as trusted. Returns whether anything changed.
    @discardableResult
    public static func accept(path: String,
                              configPath: String = WorkspaceTrust.defaultConfigPath())
        -> Result<Bool, CrewError> {
        let workspace = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard workspace.hasPrefix("/") else {
            return .failure(CrewError("not an absolute workspace path: '\(path)'"))
        }
        guard let data = FileManager.default.contents(atPath: configPath) else {
            // Claude Code has never run here. Inventing its state file is not damson's place.
            return .failure(CrewError("no Claude Code config at \(configPath)"))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(CrewError("could not read \(configPath); leaving it untouched"))
        }
        // `projects` may be absent on a fresh install, but if it is present it must be an
        // object. Anything else means the format has moved and this code is out of date.
        var projects: [String: Any] = [:]
        if let existing = root["projects"] {
            guard let dict = existing as? [String: Any] else {
                return .failure(CrewError("unexpected 'projects' shape in \(configPath); leaving it untouched"))
            }
            projects = dict
        }

        var entry = (projects[workspace] as? [String: Any]) ?? [:]
        if entry["hasTrustDialogAccepted"] as? Bool == true { return .success(false) }
        entry["hasTrustDialogAccepted"] = true
        projects[workspace] = entry

        var updated = root
        updated["projects"] = projects
        guard let out = try? JSONSerialization.data(withJSONObject: updated,
                                                    options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return .failure(CrewError("could not re-encode \(configPath); leaving it untouched"))
        }

        // Keep the state from BEFORE the first change: if this goes wrong, that is the only
        // copy of what the user had.
        let backup = configPath + backupSuffix
        if !FileManager.default.fileExists(atPath: backup) {
            try? data.write(to: URL(fileURLWithPath: backup))
        }
        // Same directory, then rename: a partial write must never be visible as the config.
        let temp = configPath + ".damson-tmp-\(getpid())"
        do {
            try out.write(to: URL(fileURLWithPath: temp))
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: configPath),
                                                     withItemAt: URL(fileURLWithPath: temp))
        } catch {
            try? FileManager.default.removeItem(atPath: temp)
            return .failure(CrewError("could not update \(configPath): \(error.localizedDescription)"))
        }
        return .success(true)
    }
}
