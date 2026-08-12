import Darwin
import Foundation

/// One live Claude Code session, as reported by the CLI itself.
struct ClaudeSessionRow {
    let pid: pid_t
    let sessionId: String
    let cwd: String
    /// The session's display name (`--name`, or derived from the directory).
    let name: String?
    /// Raw status string. Deliberately kept raw here — `AgentBadge` owns the vocabulary,
    /// and an unknown value must survive this far so it can be dropped there rather than
    /// silently coerced into a neighbouring state.
    let status: String
    /// Free-form description of what a `waiting` session is blocked on. Optional in the
    /// source data (Claude Code reads it back as `typeof x === "string" ? x : undefined`).
    let waitingFor: String?
    /// Claude Code's own version string. Present only in the on-disk records; used to
    /// notice that the format has moved on from what this code was written against.
    let version: String?
}

/// Tracks the Claude Code sessions running on this machine.
///
/// Claude Code writes one JSON record per live session into `~/.claude/sessions/<pid>.json`
/// and rewrites it **in place** as the session's status changes. Reading those files is how
/// damson learns what a pane is doing.
///
/// Two deliberate choices, both about not being wrong:
///
/// 1. **Poll, don't watch the directory.** The files are rewritten in place, not renamed
///    into position, so a `DispatchSource` vnode source on the *directory* fires on
///    add/remove only and would never see a busy→waiting transition: every badge would
///    freeze at whatever state the session had when it started. A `stat`-and-reread sweep
///    over a handful of small files is cheap and, more importantly, correct.
/// 2. **Never infer from the terminal's rendered content.** damson previously identified
///    agent state by matching spinner glyphs and prompt-box borders on screen; that broke
///    on every Claude Code release. This reads a documented record instead, and when the
///    record is missing or unrecognizable it reports *nothing* rather than a guess.
///
/// All access is main-thread only: the sweep is driven by a timer owned by `CrewController`,
/// and the parsed table is read from the UI on the same thread.
final class ClaudeSessionRegistry {
    /// Live rows keyed by pid. Empty until the first `refresh()`.
    private(set) var byPID: [pid_t: ClaudeSessionRow] = [:]

    /// The newest Claude Code version seen in a record, for diagnostics when the format
    /// drifts away from what this was written against.
    private(set) var observedVersion: String?

    private let sessionsDir: URL
    /// mtime+size per file path, so an unchanged record is skipped without re-parsing.
    private var fileStamps: [String: (mtime: Int, size: Int)] = [:]
    private var cache: [pid_t: ClaudeSessionRow] = [:]
    private var didWarnUnreadable = false

    init(sessionsDir: URL? = nil) {
        self.sessionsDir = sessionsDir
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions")
    }

    /// Re-read the session directory. Cheap on a quiet tick: only records whose mtime or
    /// size moved are parsed again.
    func refresh() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir.path) else {
            // A missing directory is the normal state on a machine that has never run
            // Claude Code — not an error, and not worth a log line every tick.
            if !byPID.isEmpty { byPID.removeAll(); cache.removeAll(); fileStamps.removeAll() }
            return
        }

        var seen = Set<pid_t>()
        var stamps: [String: (mtime: Int, size: Int)] = [:]

        for name in names {
            // Exactly the shape Claude Code itself matches: `<digits>.json`. Anything else
            // in this directory (the per-session `.key` files, editor droppings) is not ours.
            guard name.hasSuffix(".json") else { continue }
            let stem = String(name.dropLast(5))
            guard !stem.isEmpty, stem.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let pid = pid_t(stem) else { continue }

            let path = sessionsDir.appendingPathComponent(name).path
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.intValue else { continue }
            let mtime = Int((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
            stamps[path] = (mtime, size)

            // A record whose process is gone is stale: Claude Code cleans these up, but not
            // instantly, and a badge for a dead agent is exactly the kind of lie this class
            // exists to avoid. `kill(pid, 0)` is the cheap liveness probe.
            guard kill(pid, 0) == 0 || errno == EPERM else { continue }

            if let prior = fileStamps[path], prior.mtime == mtime, prior.size == size,
               let cached = cache[pid] {
                byPID[pid] = cached
                seen.insert(pid)
                continue
            }

            guard let row = Self.parse(path: path, expecting: pid) else { continue }
            cache[pid] = row
            byPID[pid] = row
            seen.insert(pid)
            if let v = row.version { observedVersion = v }
        }

        fileStamps = stamps
        for pid in byPID.keys where !seen.contains(pid) {
            byPID.removeValue(forKey: pid)
            cache.removeValue(forKey: pid)
        }
    }

    /// The session whose pid matches, if any. This is the whole join: a pane's PTY
    /// foreground process group IS the pid of the `claude` running in it, because a shell
    /// puts each foreground job in its own process group led by that process.
    func session(forForegroundPID pid: pid_t?) -> ClaudeSessionRow? {
        guard let pid else { return nil }
        return byPID[pid]
    }

    private static func parse(path: String, expecting pid: pid_t) -> ClaudeSessionRow? {
        guard let data = FileManager.default.contents(atPath: path),
              // A record is a few hundred bytes; anything large is not one, and parsing it
              // would only put a stranger's bytes through JSONSerialization on the main thread.
              data.count <= 256 * 1024,
              let any = try? JSONSerialization.jsonObject(with: data),
              let obj = any as? [String: Any],
              let status = obj["status"] as? String else { return nil }

        // Trust the filename's pid over the body's: the file IS keyed by pid, and a record
        // whose contents disagree is one being rewritten under us or left by something else.
        if let bodyPID = (obj["pid"] as? NSNumber)?.int32Value, bodyPID != pid { return nil }

        return ClaudeSessionRow(
            pid: pid,
            sessionId: obj["sessionId"] as? String ?? "",
            cwd: obj["cwd"] as? String ?? "",
            name: obj["name"] as? String,
            status: status,
            waitingFor: obj["waitingFor"] as? String,
            version: obj["version"] as? String
        )
    }
}
