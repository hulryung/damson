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
indirect enum RestorablePane: Codable {
    case leaf(cwd: String?, scrollbackID: String?)
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
    static func writeScrollback(grid: Grid) -> String? {
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
        var visible: [SerializedLine] = []
        for r in 0..<grid.rows {
            visible.append(serialize(Line(grid.row(r), wrapped: grid.rowWrapped(r))))
        }
        while let last = visible.last, last.r.isEmpty, !last.w { visible.removeLast() }
        lines.append(contentsOf: visible)
        guard !lines.isEmpty else { return nil }

        let id = UUID().uuidString
        let url = scrollbackDir.appendingPathComponent("\(id).json")
        guard let data = try? JSONEncoder().encode(lines) else { return nil }
        do { try data.write(to: url) } catch { return nil }
        return id
    }

    /// Restores saved scrollback as `[Line]` (nil if missing or on failure). Colors use defaults.
    static func readScrollback(id: String) -> [Line]? {
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
        // Boundary marker — a separator line at the bottom of the restored content (right above the new session prompt).
        let sep = "──────── session restored ────────"
        out.append(Line(sep.map { Cell(char: $0, attrs: CellAttrs(fg: .default)) }))
        return out
    }
}

// MARK: - PaneNode ↔ RestorablePane conversion

extension PaneNode {
    /// Converts the current tree to its serialized form. Each leaf's cwd is queried via proc_pidinfo.
    func toRestorable() -> RestorablePane {
        switch kind {
        case .leaf(let session, _):
            let sbID = SessionRestore.scrollbackRestoreEnabled
                ? SessionRestore.writeScrollback(grid: session.grid) : nil
            return .leaf(cwd: session.currentWorkingDirectory, scrollbackID: sbID)
        case .split(let dir, let first, let second, let ratio):
            return .split(
                direction: dir == .horizontal ? "horizontal" : "vertical",
                ratio: Double(ratio),
                first: first.toRestorable(),
                second: second.toRestorable()
            )
        }
    }

    /// Rebuilds the tree from its serialized form. Each leaf spawns a new session in its cwd.
    /// Parent links are wired up as well.
    static func from(restorable: RestorablePane) -> PaneNode {
        switch restorable {
        case .leaf(let cwd, let scrollbackID):
            var config = DamsonConfig.fromUserDefaults()
            // If the saved cwd still exists, use it; otherwise fall back to fromUserDefaults' default (home).
            if let cwd = cwd, FileManager.default.fileExists(atPath: cwd) {
                config.cwd = cwd
            }
            let restored: [Line]? = (SessionRestore.scrollbackRestoreEnabled ? scrollbackID : nil)
                .flatMap { SessionRestore.readScrollback(id: $0) }
            let session = DamsonSession(config: config, restoredScrollback: restored)
            return PaneNode.leaf(session)
        case .split(let dirStr, let ratio, let first, let second):
            let dir: SplitDirection = (dirStr == "vertical") ? .vertical : .horizontal
            let a = from(restorable: first)
            let b = from(restorable: second)
            let node = PaneNode(kind: .split(
                direction: dir, first: a, second: b, ratio: CGFloat(ratio)
            ))
            a.parent = node
            b.parent = node
            return node
        }
    }
}
