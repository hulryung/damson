import AppKit
import DamsonTerminal

/// Session-state restoration — on quit, serializes the window/tab/pane layout plus each
/// pane's cwd, and on launch restores that structure. The cwd is queried directly from the
/// OS via proc_pidinfo (independent of shell configuration).
///
/// Scrollback text is not saved (layout + cwd only — the standard scope of terminal restoration).

// MARK: - Serialization model

/// Serialized form of a pane-tree node.
/// `scrollbackID` is the file key where that pane's scrollback is stored (when the setting is
/// on). It is optional so older saved data that lacked this field still decodes (restored
/// without scrollback).
/// `sessionID`/`preamble` exist only for leaves whose PTY was handed to the keeper at quit:
/// the id keys the claim, the preamble (base64 escape bytes from
/// `DamsonSession.stateRestorationPreamble`) rebuilds the tracked terminal modes in the
/// adopting parser. Optional for the same backward-decode reason as `scrollbackID`.
indirect enum RestorablePane: Codable {
    case leaf(cwd: String?, scrollbackID: String?, sessionID: String?, preamble: String?)
    case split(direction: String, ratio: Double, first: RestorablePane, second: RestorablePane)
}

/// One window = an array of tabs. Each tab is the root of a pane tree.
struct RestorableWindow: Codable {
    var tabs: [RestorablePane]
    var selectedTab: Int
    /// Per-tab custom titles (double-click rename). Same order and length as `tabs`. Optional
    /// so older saved data that lacked this field still decodes (all restored with auto titles).
    var tabTitles: [String?]?
}

/// The full restoration state.
struct RestorableState: Codable {
    var windows: [RestorableWindow]
    /// Set when this state was saved with a keeper handoff — the next launch claims
    /// surviving sessions from `keeper-<generation>.sock`. Guards against adopting from
    /// a stale keeper of some other run (or another instance sharing the runtime dir).
    var handoffGeneration: String?

    init(windows: [RestorableWindow], handoffGeneration: String? = nil) {
        self.windows = windows
        self.handoffGeneration = handoffGeneration
    }
}

// MARK: - Save/load

enum SessionRestore {
    private static let key = "damson.restorableState"

    static func save(_ state: RestorableState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> RestorableState? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(RestorableState.self, from: data)
        else { return nil }
        return state
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Scrollback restoration (optional — settings toggle)

    /// Setting: whether to also restore each pane's scrollback text on relaunch. Off by default.
    static var scrollbackRestoreEnabled: Bool {
        UserDefaults.standard.bool(forKey: "damson.restoreScrollback")
    }

    /// Scrollback file directory (~/Library/Application Support/Damson/scrollback).
    private static var scrollbackDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Damson/scrollback", isDirectory: true)
    }

    /// Serialized scrollback. Consecutive cells with the same attributes are grouped into a
    /// run, preserving color/background/attributes while staying compact (most lines are one
    /// to a few runs). Continuation (wide-trailing) cells are excluded and reconstructed on load.
    private struct SerializedRun: Codable {
        var t: String       // text
        var a: CellAttrs    // fg/bg/bold/underline/... — all of them
    }
    private struct SerializedLine: Codable {
        var r: [SerializedRun]
        var w: Bool          // whether this is a soft-wrap continuation
    }

    /// Default (blank) attributes — used to decide trailing-whitespace trimming.
    private static func isPlainBlank(_ c: Cell) -> Bool {
        !c.isContinuation && c.char == " " && c.attrs == CellAttrs(fg: .default)
    }

    /// Run once before capture begins — deletes all previous scrollback files and recreates
    /// the directory. (Each save writes with a new UUID, so old files are orphans — cleaned up here.)
    static func resetScrollbackDir() {
        let fm = FileManager.default
        try? fm.removeItem(at: scrollbackDir)
        try? fm.createDirectory(at: scrollbackDir, withIntermediateDirectories: true)
    }

    /// Saves a session's grid (scrollback + visible screen) to a file and returns its id. nil on failure.
    /// `includeVisible: false` for a handed-off pane sitting on the ALT screen — its visible
    /// frame is the TUI's painting, which the post-adopt SIGWINCH repaints; folding it into
    /// primary-screen scrollback would leave a dead copy of the frame above the live one.
    static func writeScrollback(grid: Grid, includeVisible: Bool = true) -> String? {
        var lines: [SerializedLine] = []
        func serialize(_ line: Line) -> SerializedLine {
            // Trim trailing default-blank cells (keep cells with a background color). Continuation cells: boundary check only.
            var cells = line.cells
            while let last = cells.last, isPlainBlank(last) { cells.removeLast() }
            var runs: [SerializedRun] = []
            var text = ""
            var attrs: CellAttrs?
            for c in cells where !c.isContinuation {
                if let a = attrs, c.attrs != a {
                    runs.append(SerializedRun(t: text, a: a)); text = ""
                }
                attrs = c.attrs
                text.append(c.char)
            }
            if let a = attrs, !text.isEmpty { runs.append(SerializedRun(t: text, a: a)) }
            return SerializedLine(r: runs, w: line.wrapped)
        }
        for line in grid.scrollback { lines.append(serialize(line)) }
        // Include the visible screen too (the most recent context). Trim trailing blank lines.
        if includeVisible {
            var visible: [SerializedLine] = []
            for r in 0..<grid.rows {
                visible.append(serialize(Line(grid.row(r), wrapped: grid.rowWrapped(r))))
            }
            while let last = visible.last, last.r.isEmpty, !last.w { visible.removeLast() }
            lines.append(contentsOf: visible)
        }
        guard !lines.isEmpty else { return nil }

        let id = UUID().uuidString
        let url = scrollbackDir.appendingPathComponent("\(id).json")
        guard let data = try? JSONEncoder().encode(lines) else { return nil }
        do { try data.write(to: url) } catch { return nil }
        return id
    }

    /// Restores saved scrollback as `[Line]` (nil if missing or on failure). Colors use defaults.
    /// `separator: false` for an ADOPTED pane — the session did not restart, so a
    /// "session restored" boundary line would be a lie.
    static func readScrollback(id: String, separator: Bool = true) -> [Line]? {
        let url = scrollbackDir.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: url),
              let lines = try? JSONDecoder().decode([SerializedLine].self, from: data),
              !lines.isEmpty
        else { return nil }
        var out: [Line] = lines.map { ser in
            var cells: [Cell] = []
            for run in ser.r {
                for ch in run.t {
                    cells.append(Cell(char: ch, attrs: run.a))
                    if Cell.isWide(ch) { cells.append(Cell.continuation(attrs: run.a)) }
                }
            }
            return Line(cells, wrapped: ser.w)
        }
        guard separator else { return out }
        // Boundary marker — a separator line at the bottom of the restored content (right above the new session prompt).
        let sep = "──────── session restored ────────"
        out.append(Line(sep.map { Cell(char: $0, attrs: CellAttrs(fg: .default)) }))
        return out
    }
}

// MARK: - PaneNode ↔ RestorablePane conversion

extension PaneNode {
    /// Converts the current tree to its serialized form. Each leaf's cwd is queried via proc_pidinfo.
    /// `handoff` maps sessions that were just released to the keeper: their leaves carry the
    /// claim id + mode preamble, use the cwd snapshotted at release (the live query answers
    /// nil once the PTY is no longer ours), and ALWAYS get their scrollback written — a pane
    /// that keeps running must not come back blank just because the restore-scrollback
    /// setting is off.
    func toRestorable(handoff: [ObjectIdentifier: SessionHandoffRecord] = [:]) -> RestorablePane {
        switch kind {
        case .leaf(let session, _):
            if let rec = handoff[ObjectIdentifier(session)] {
                let sbID = SessionRestore.writeScrollback(
                    grid: session.grid, includeVisible: !session.grid.isAltScreenActive)
                return .leaf(cwd: rec.cwd, scrollbackID: sbID,
                             sessionID: rec.uuid, preamble: rec.preamble.base64EncodedString())
            }
            let sbID = SessionRestore.scrollbackRestoreEnabled
                ? SessionRestore.writeScrollback(grid: session.grid) : nil
            return .leaf(cwd: session.currentWorkingDirectory, scrollbackID: sbID,
                         sessionID: nil, preamble: nil)
        case .split(let dir, let first, let second, let ratio):
            return .split(
                direction: dir == .horizontal ? "horizontal" : "vertical",
                ratio: Double(ratio),
                first: first.toRestorable(handoff: handoff),
                second: second.toRestorable(handoff: handoff)
            )
        }
    }

    /// Rebuilds the tree from its serialized form. Each leaf spawns a new session in its cwd —
    /// unless `adopt` returns a surviving PTY for its sessionID, in which case the session is
    /// built AROUND the still-running child: no fork, replay = mode preamble + everything
    /// buffered while the app was down, then live reads. A leaf whose child died while held
    /// (or when no keeper answered) falls back to the fresh-spawn path below.
    /// Parent links are wired up as well.
    static func from(restorable: RestorablePane,
                     adopt: (String) -> AdoptedSession? = { _ in nil }) -> PaneNode {
        switch restorable {
        case .leaf(let cwd, let scrollbackID, let sessionID, let preamble):
            var config = DamsonConfig.fromUserDefaults()
            // If the saved cwd still exists, use it; otherwise fall back to fromUserDefaults' default (home).
            if let cwd = cwd, FileManager.default.fileExists(atPath: cwd) {
                config.cwd = cwd
            }
            if let sessionID, let adopted = adopt(sessionID) {
                let host = PTYHost()
                let pre = preamble.flatMap { Data(base64Encoded: $0) } ?? Data()
                host.adopt(fd: adopted.fd, pid: adopted.pid,
                           startSec: adopted.startSec, startUsec: adopted.startUsec,
                           replay: pre + adopted.buffer)
                // Scrollback always (saved unconditionally for handed-off leaves), and
                // without the "session restored" separator — this session never stopped.
                let restored = scrollbackID.flatMap {
                    SessionRestore.readScrollback(id: $0, separator: false)
                }
                let session = DamsonSession(config: config, restoredScrollback: restored,
                                            backend: host)
                return PaneNode.leaf(session)
            }
            let restored: [Line]? = (SessionRestore.scrollbackRestoreEnabled ? scrollbackID : nil)
                .flatMap { SessionRestore.readScrollback(id: $0) }
            let session = DamsonSession(config: config, restoredScrollback: restored)
            return PaneNode.leaf(session)
        case .split(let dirStr, let ratio, let first, let second):
            let dir: SplitDirection = (dirStr == "vertical") ? .vertical : .horizontal
            let a = from(restorable: first, adopt: adopt)
            let b = from(restorable: second, adopt: adopt)
            let node = PaneNode(kind: .split(
                direction: dir, first: a, second: b, ratio: CGFloat(ratio)
            ))
            a.parent = node
            b.parent = node
            return node
        }
    }
}
