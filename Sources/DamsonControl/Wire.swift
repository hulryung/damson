import Foundation

/// NDJSON wire-format types for damson-cli ↔ damson server.
/// Encoding/decoding is implemented manually. (The format derives from the CLI
/// spec in Rust halite's `docs/CLI.md`, but is now damson's own format.)

public enum SplitDir: String, Codable, Sendable {
    case horizontal
    case vertical
}

/// A pane-relative direction used by focus-pane / resize-pane.
public enum PaneDir: String, Codable, Sendable {
    case left
    case right
    case up
    case down
}

public enum ControlCommandKind: Equatable, Sendable {
    case newTab
    case split(SplitDir)
    case switchTab(index: Int)
    case closeTab
    case listTabs
    // --- Remote input & pane control (damson-cli expansion). ---
    /// Type literal UTF-8 text into the active pane (as if pasted/typed).
    case sendText(String)
    /// Send one or more named keys/chords (enter, tab, esc, up, ctrl-c, …) in order.
    case sendKeys([String])
    /// Resize the active window so its terminal grid is `cols` × `rows`.
    case resizeWindow(cols: Int, rows: Int)
    /// Nudge the active split's divider toward `dir` by `amount` cells (default 1).
    case resizePane(dir: PaneDir, amount: Int)
    /// Move pane focus to the adjacent pane in `dir`.
    case focusPane(dir: PaneDir)
    /// Close the active pane.
    case closePane
    /// Structured per-pane info for the active tab.
    case listPanes
    /// The active pane's visible grid as plain text (one line per row) — for remote
    /// inspection of rendering state (debugging/driving the UI from scripts).
    case dumpGrid
    /// Font zoom on the active pane: "in" | "out" | "reset" — same path as Cmd+=/-.
    case zoom(String)
    /// Apply a preset pane layout to the active tab (e.g. "columns2060", "grid2x2").
    case applyLayout(String)
    // --- Addressable panes (orchestration). NEW cases, never widened ones: adding an
    // associated value to an existing case is source-breaking at every construction site,
    // in this repo and in anything else that links this library product.
    /// Open a pane running a caller-supplied argv, and return its stable id.
    case spawnPane(SpawnSpec)
    /// Every pane in every window, with its stable id — the addressing table.
    case listAgents
    /// One pane's details, by id (or the active pane when no target is given).
    case paneInfo
    /// Subscribe to agent state changes. Unlike every other command this one does not
    /// answer and hang up: the connection stays open and each change arrives as one more
    /// NDJSON line until the client disconnects.
    case watchAgents
    /// Pin a label on a pane's tab, or clear it with the empty string. The label wins over
    /// the child's own OSC titles, which shells rewrite on every prompt.
    case setTitle(String)
    /// Every tab group in every window.
    case listGroups
    /// Close every tab in a group. Destructive — see the note on `GroupInfo`.
    case closeGroup(String)
    case setGroupCollapsed(String, Bool)
    case renameGroup(String, to: String)
    /// Move a whole group so its first tab lands at `to`, counted among the tabs that are
    /// not in it. The same operation the group header's drag performs.
    case moveGroup(String, to: Int)
}

/// Where a command should land. Absent on the wire means `.active`, so every existing
/// client keeps its exact meaning.
public enum PaneTarget: Equatable, Sendable {
    case active
    case id(String)
}

/// What to open, for `spawnPane`.
public struct SpawnSpec: Equatable, Sendable, Codable {
    /// Where the new pane goes. nil = a new tab.
    public let split: SplitDir?
    public let cwd: String?
    public let argv: [String]
    /// Idempotency token. The server records it and, on a repeat, returns the SAME pane
    /// instead of opening a second one.
    ///
    /// This is not belt-and-braces. The control socket's handler hops to the main actor and
    /// waits with a 2s timeout; on expiry it reports failure to the client **while the queued
    /// work still runs to completion**. A spawn that overruns 2s — easy under a tab-creation
    /// animation — therefore answers "failed" for a pane that did open, and a client that
    /// retries would mint a second agent. With a key, the retry is answered with the first
    /// pane's id.
    public let key: String?
    /// Label for the new pane's tab, pinned the moment it opens. Optional and appended
    /// only when set, so a spawn without one is byte-identical to what shipped before.
    public let title: String?
    /// Group for the new tab, by name. Created if absent, joined if present — the same
    /// idempotency `key` gives the spawn itself, so a coordinator looping over tasks never
    /// has to ask whether the group exists first.
    public let group: String?

    public init(split: SplitDir? = nil, cwd: String? = nil, argv: [String],
                key: String? = nil, title: String? = nil, group: String? = nil) {
        self.split = split
        self.cwd = cwd
        self.argv = argv
        self.key = key
        self.title = title
        self.group = group
    }
}

/// An incoming command. JSON: `{"cmd":"new-tab"}`, `{"cmd":"split","args":{"dir":"horizontal"}}`, etc.
public struct ControlCommand: Decodable, Equatable, Sendable {
    public let kind: ControlCommandKind
    /// Which pane the command addresses. A payload with no `"pane"` key decodes to
    /// `.active`, which is what every client sent before this existed — so old JSON keeps
    /// its exact meaning and `init(kind:)` keeps its signature.
    public let target: PaneTarget

    public init(kind: ControlCommandKind, target: PaneTarget = .active) {
        self.kind = kind
        self.target = target
    }

    enum CodingKeys: String, CodingKey { case cmd, args, pane }
    private struct SplitArgs: Decodable { let dir: SplitDir }
    private struct SwitchArgs: Decodable { let index: Int }
    private struct TextArgs: Decodable { let text: String }
    private struct KeysArgs: Decodable { let keys: [String] }
    private struct ResizeWindowArgs: Decodable { let cols: Int; let rows: Int }
    private struct ResizePaneArgs: Decodable { let dir: PaneDir; let amount: Int? }
    private struct PaneDirArgs: Decodable { let dir: PaneDir }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .cmd)
        if let pane = try c.decodeIfPresent(String.self, forKey: .pane), !pane.isEmpty {
            self.target = .id(pane)
        } else {
            self.target = .active
        }
        switch name {
        case "new-tab":
            self.kind = .newTab
        case "close-tab":
            self.kind = .closeTab
        case "list-tabs":
            self.kind = .listTabs
        case "split":
            let a = try c.decode(SplitArgs.self, forKey: .args)
            self.kind = .split(a.dir)
        case "switch-tab":
            let a = try c.decode(SwitchArgs.self, forKey: .args)
            self.kind = .switchTab(index: a.index)
        case "send-text":
            let a = try c.decode(TextArgs.self, forKey: .args)
            self.kind = .sendText(a.text)
        case "send-key":
            let a = try c.decode(KeysArgs.self, forKey: .args)
            self.kind = .sendKeys(a.keys)
        case "resize-window":
            let a = try c.decode(ResizeWindowArgs.self, forKey: .args)
            // The CLI validates positivity, but a direct socket writer can send
            // {"cols":-5,"rows":0}; reject it here so the server never applies a 0×0
            // (or negative) grid, which would break resize/rendering.
            guard a.cols > 0, a.rows > 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .args, in: c,
                    debugDescription: "resize-window cols/rows must be positive")
            }
            self.kind = .resizeWindow(cols: a.cols, rows: a.rows)
        case "resize-pane":
            let a = try c.decode(ResizePaneArgs.self, forKey: .args)
            self.kind = .resizePane(dir: a.dir, amount: a.amount ?? 1)
        case "focus-pane":
            let a = try c.decode(PaneDirArgs.self, forKey: .args)
            self.kind = .focusPane(dir: a.dir)
        case "close-pane":
            self.kind = .closePane
        case "list-panes":
            self.kind = .listPanes
        case "dump-grid":
            self.kind = .dumpGrid
        case "zoom":
            struct ZoomArgs: Decodable { let action: String }
            let a = try c.decode(ZoomArgs.self, forKey: .args)
            self.kind = .zoom(a.action)
        case "layout":
            struct LayoutArgs: Decodable { let name: String }
            let a = try c.decode(LayoutArgs.self, forKey: .args)
            self.kind = .applyLayout(a.name)
        case "spawn-pane":
            let spec = try c.decode(SpawnSpec.self, forKey: .args)
            guard !spec.argv.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .args, in: c, debugDescription: "spawn-pane requires a non-empty argv")
            }
            self.kind = .spawnPane(spec)
        case "list-agents":
            self.kind = .listAgents
        case "pane-info":
            self.kind = .paneInfo
        case "watch-agents":
            self.kind = .watchAgents
        case "group-list":
            self.kind = .listGroups
        case "group-close":
            struct NameArgs: Decodable { let name: String }
            let a = try c.decode(NameArgs.self, forKey: .args)
            guard !a.name.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .args, in: c, debugDescription: "group-close requires a name")
            }
            self.kind = .closeGroup(a.name)
        case "group-collapse":
            struct CollapseArgs: Decodable { let name: String; let collapsed: Bool }
            let a = try c.decode(CollapseArgs.self, forKey: .args)
            guard !a.name.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .args, in: c, debugDescription: "group-collapse requires a name")
            }
            self.kind = .setGroupCollapsed(a.name, a.collapsed)
        case "group-rename":
            struct RenameArgs: Decodable { let name: String; let to: String }
            let a = try c.decode(RenameArgs.self, forKey: .args)
            guard !a.name.isEmpty, !a.to.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .args, in: c,
                    debugDescription: "group-rename requires a name and a new name")
            }
            self.kind = .renameGroup(a.name, to: a.to)
        case "group-move":
            struct MoveArgs: Decodable { let name: String; let to: Int }
            let a = try c.decode(MoveArgs.self, forKey: .args)
            guard !a.name.isEmpty, a.to >= 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .args, in: c,
                    debugDescription: "group-move requires a name and a non-negative index")
            }
            self.kind = .moveGroup(a.name, to: a.to)
        case "set-title":
            struct TitleArgs: Decodable { let title: String }
            let a = try c.decode(TitleArgs.self, forKey: .args)
            self.kind = .setTitle(a.title)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .cmd, in: c,
                debugDescription: "unknown command: \(name)"
            )
        }
    }
}

/// Minimal JSON string escaping for the hand-rolled encoder (matches what a strict
/// JSON parser expects: quotes, backslash, and the control characters that require it).
func jsonEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count + 2)
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case let c where c.value < 0x20:
            out += String(format: "\\u%04x", c.value)
        default:
            out.unicodeScalars.append(scalar)
        }
    }
    return out
}

/// Serializes a command → JSON on the CLI side. Produces output identical to the Rust `cmd_to_json` (down to key order).
public func encodeCommand(_ kind: ControlCommandKind) -> String {
    switch kind {
    case .newTab: return #"{"cmd":"new-tab"}"#
    case .closeTab: return #"{"cmd":"close-tab"}"#
    case .listTabs: return #"{"cmd":"list-tabs"}"#
    case .split(let d):
        return #"{"cmd":"split","args":{"dir":"\#(d.rawValue)"}}"#
    case .switchTab(let i):
        return #"{"cmd":"switch-tab","args":{"index":\#(i)}}"#
    case .sendText(let t):
        return #"{"cmd":"send-text","args":{"text":"\#(jsonEscape(t))"}}"#
    case .sendKeys(let keys):
        let arr = keys.map { #""\#(jsonEscape($0))""# }.joined(separator: ",")
        return #"{"cmd":"send-key","args":{"keys":[\#(arr)]}}"#
    case .resizeWindow(let cols, let rows):
        return #"{"cmd":"resize-window","args":{"cols":\#(cols),"rows":\#(rows)}}"#
    case .resizePane(let dir, let amount):
        return #"{"cmd":"resize-pane","args":{"dir":"\#(dir.rawValue)","amount":\#(amount)}}"#
    case .focusPane(let dir):
        return #"{"cmd":"focus-pane","args":{"dir":"\#(dir.rawValue)"}}"#
    case .closePane: return #"{"cmd":"close-pane"}"#
    case .listPanes: return #"{"cmd":"list-panes"}"#
    case .dumpGrid: return #"{"cmd":"dump-grid"}"#
    case .zoom(let a):
        return #"{"cmd":"zoom","args":{"action":"\#(jsonEscape(a))"}}"#
    case .applyLayout(let name):
        return #"{"cmd":"layout","args":{"name":"\#(jsonEscape(name))"}}"#
    case .spawnPane(let spec):
        var parts: [String] = []
        if let s = spec.split { parts.append(#""split":"\#(s.rawValue)""#) }
        if let c = spec.cwd { parts.append(#""cwd":"\#(jsonEscape(c))""#) }
        parts.append(#""argv":[\#(spec.argv.map { #""\#(jsonEscape($0))""# }.joined(separator: ","))]"#)
        if let k = spec.key { parts.append(#""key":"\#(jsonEscape(k))""#) }
        if let t = spec.title { parts.append(#""title":"\#(jsonEscape(t))""#) }
        if let g = spec.group { parts.append(#""group":"\#(jsonEscape(g))""#) }
        return #"{"cmd":"spawn-pane","args":{\#(parts.joined(separator: ","))}}"#
    case .listAgents: return #"{"cmd":"list-agents"}"#
    case .paneInfo: return #"{"cmd":"pane-info"}"#
    case .watchAgents: return #"{"cmd":"watch-agents"}"#
    case .setTitle(let t):
        return #"{"cmd":"set-title","args":{"title":"\#(jsonEscape(t))"}}"#
    case .listGroups: return #"{"cmd":"group-list"}"#
    case .closeGroup(let n):
        return #"{"cmd":"group-close","args":{"name":"\#(jsonEscape(n))"}}"#
    case .setGroupCollapsed(let n, let c):
        return #"{"cmd":"group-collapse","args":{"name":"\#(jsonEscape(n))","collapsed":\#(c)}}"#
    case .renameGroup(let n, let to):
        return #"{"cmd":"group-rename","args":{"name":"\#(jsonEscape(n))","to":"\#(jsonEscape(to))"}}"#
    case .moveGroup(let n, let to):
        return #"{"cmd":"group-move","args":{"name":"\#(jsonEscape(n))","to":\#(to)}}"#
    }
}

/// Attach a pane target to an encoded command. Splices into the existing object rather
/// than re-encoding, so every command's payload stays byte-identical when no target is set.
public func encodeCommand(_ kind: ControlCommandKind, target: PaneTarget) -> String {
    let base = encodeCommand(kind)
    guard case .id(let id) = target else { return base }
    return String(base.dropLast()) + #","pane":"\#(jsonEscape(id))"}"#
}

/// One `group-list` row.
///
/// Reported by name rather than by id: a coordinator names a run and never sees the UUID
/// damson keys groups on internally. Names are not unique, so a command naming a group acts
/// on the first one on screen — the only answer a user could predict.
public struct GroupInfo: Codable, Equatable, Sendable {
    public let name: String
    public let tabs: Int
    public let collapsed: Bool
    public let colorIndex: Int?

    public init(name: String, tabs: Int, collapsed: Bool = false, colorIndex: Int? = nil) {
        self.name = name
        self.tabs = tabs
        self.collapsed = collapsed
        self.colorIndex = colorIndex
    }

    enum CodingKeys: String, CodingKey { case name, tabs, collapsed, colorIndex }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(tabs, forKey: .tabs)
        try c.encode(collapsed, forKey: .collapsed)
        try c.encodeIfPresent(colorIndex, forKey: .colorIndex)
    }
}

/// A single list-tabs result row.
public struct TabInfo: Codable, Equatable, Sendable {
    public let index: Int
    public let pane_count: Int
    public init(index: Int, pane_count: Int) {
        self.index = index
        self.pane_count = pane_count
    }
}

/// A single list-panes result row (panes of the active tab). `active` marks the focused pane.
public struct PaneInfo: Codable, Equatable, Sendable {
    public let index: Int
    public let cols: Int
    public let rows: Int
    public let active: Bool
    // Added for orchestration. All optional and all defaulted, so the original four-argument
    // initializer still compiles unchanged everywhere — including downstream of this library.
    /// Stable pane id (see PaneRegistry). Present once a pane has been addressed.
    public let id: String?
    /// Which tab the pane lives in — `index` is only unique within a tab.
    public let tab: Int?
    /// The process group owning the pane's tty: what is actually running in it.
    public let pid: Int32?
    public let cwd: String?
    public let title: String?
    /// Agent status when the pane is running one damson recognizes, else nil.
    public let agent: String?
    /// The name of the group holding this pane's tab, when it is in one.
    public let group: String?

    public init(index: Int, cols: Int, rows: Int, active: Bool,
                id: String? = nil, tab: Int? = nil, pid: Int32? = nil,
                cwd: String? = nil, title: String? = nil, agent: String? = nil,
                group: String? = nil) {
        self.index = index
        self.cols = cols
        self.rows = rows
        self.active = active
        self.id = id
        self.tab = tab
        self.pid = pid
        self.cwd = cwd
        self.title = title
        self.agent = agent
        self.group = group
    }

    enum CodingKeys: String, CodingKey {
        case index, cols, rows, active, id, tab, pid, cwd, title, agent, group
    }

    /// Hand-rolled so nil fields are OMITTED rather than encoded as null — a `list-panes`
    /// response for ordinary panes stays byte-identical to what it has always been.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(index, forKey: .index)
        try c.encode(cols, forKey: .cols)
        try c.encode(rows, forKey: .rows)
        try c.encode(active, forKey: .active)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(tab, forKey: .tab)
        try c.encodeIfPresent(pid, forKey: .pid)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(agent, forKey: .agent)
        try c.encodeIfPresent(group, forKey: .group)
    }
}

/// One line of a `watch-agents` stream.
///
/// A separate type from `PaneInfo` on purpose: that one answers "what is this pane", this
/// one answers "what just changed", and a subscriber needs the BEFORE as well as the after.
public struct AgentEventLine: Codable, Equatable, Sendable {
    /// "appeared" | "changed" | "vanished".
    public let event: String
    public let pane: String
    public let pid: Int32?
    public let status: String?
    public let previousStatus: String?
    public let waitingFor: String?
    public let cwd: String?

    public init(event: String, pane: String, pid: Int32? = nil, status: String? = nil,
                previousStatus: String? = nil, waitingFor: String? = nil, cwd: String? = nil) {
        self.event = event
        self.pane = pane
        self.pid = pid
        self.status = status
        self.previousStatus = previousStatus
        self.waitingFor = waitingFor
        self.cwd = cwd
    }

    enum CodingKeys: String, CodingKey {
        case event, pane, pid, status, previousStatus, waitingFor, cwd
    }

    /// Nils omitted, so a `vanished` line doesn't carry a wall of nulls.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(event, forKey: .event)
        try c.encode(pane, forKey: .pane)
        try c.encodeIfPresent(pid, forKey: .pid)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(previousStatus, forKey: .previousStatus)
        try c.encodeIfPresent(waitingFor, forKey: .waitingFor)
        try c.encodeIfPresent(cwd, forKey: .cwd)
    }
}

// MARK: - Named key → terminal byte sequence

/// Translates a named key/chord (as passed to `damson-cli send-key`) into the exact
/// byte sequence the live keyboard path emits, so a CLI-sent key behaves identically
/// to a typed one. Mirrors `DamsonTerminalView.doCommand(by:)` / `keyDown` encodings.
///
/// Returns `nil` for an unknown name (the caller reports an error). Pure + platform-agnostic
/// so it's unit-testable from `DamsonControlTests`.
///
/// Supported names (case-insensitive, '-'/'_' interchangeable):
///   enter/return, tab, backtab/shift-tab, esc/escape, space,
///   backspace, delete (forward delete), up/down/left/right,
///   home, end, pageup/pgup, pagedown/pgdn, insert,
///   ctrl-<a..z> (control byte 0x01–0x1a), and f1–f12.
public func keyNameToBytes(_ name: String) -> [UInt8]? {
    let raw = name.trimmingCharacters(in: .whitespaces)
    guard !raw.isEmpty else { return nil }
    let key = raw.lowercased().replacingOccurrences(of: "_", with: "-")

    // Ctrl-<letter> → control byte. Mirrors keyDown's `lower - 0x60` (Ctrl-A = 0x01).
    // Accept "ctrl-c" / "control-c" / "c-c".
    for prefix in ["ctrl-", "control-", "c-"] where key.hasPrefix(prefix) {
        let letter = key.dropFirst(prefix.count)
        guard letter.count == 1, let scalar = letter.unicodeScalars.first?.value,
              (0x61...0x7a).contains(scalar) else { return nil }
        return [UInt8(scalar - 0x60)]
    }

    switch key {
    case "enter", "return", "cr":
        return [0x0D]
    case "shift-enter", "newline":
        // ESC CR — the "newline without submit" mapping (see keyDown).
        return [0x1B, 0x0D]
    case "tab":
        return [0x09]
    case "backtab", "shift-tab":
        return [0x1B, 0x5B, 0x5A]            // CSI Z
    case "esc", "escape":
        return [0x1B]
    case "space":
        return [0x20]
    case "backspace", "bs":
        return [0x7F]                         // DEL — shells map this to erase
    case "delete", "del", "forward-delete":
        return [0x1B, 0x5B, 0x33, 0x7E]       // CSI 3 ~
    case "up":
        return [0x1B, 0x5B, 0x41]             // CSI A
    case "down":
        return [0x1B, 0x5B, 0x42]             // CSI B
    case "right":
        return [0x1B, 0x5B, 0x43]             // CSI C
    case "left":
        return [0x1B, 0x5B, 0x44]             // CSI D
    case "home":
        return [0x1B, 0x5B, 0x48]             // CSI H
    case "end":
        return [0x1B, 0x5B, 0x46]             // CSI F
    case "pageup", "page-up", "pgup", "pg-up":
        return [0x1B, 0x5B, 0x35, 0x7E]       // CSI 5 ~
    case "pagedown", "page-down", "pgdn", "pg-dn", "pg-down":
        return [0x1B, 0x5B, 0x36, 0x7E]       // CSI 6 ~
    case "insert", "ins":
        return [0x1B, 0x5B, 0x32, 0x7E]       // CSI 2 ~
    case "f1":  return [0x1B, 0x4F, 0x50]     // SS3 P
    case "f2":  return [0x1B, 0x4F, 0x51]     // SS3 Q
    case "f3":  return [0x1B, 0x4F, 0x52]     // SS3 R
    case "f4":  return [0x1B, 0x4F, 0x53]     // SS3 S
    case "f5":  return [0x1B, 0x5B, 0x31, 0x35, 0x7E]   // CSI 15 ~
    case "f6":  return [0x1B, 0x5B, 0x31, 0x37, 0x7E]   // CSI 17 ~
    case "f7":  return [0x1B, 0x5B, 0x31, 0x38, 0x7E]   // CSI 18 ~
    case "f8":  return [0x1B, 0x5B, 0x31, 0x39, 0x7E]   // CSI 19 ~
    case "f9":  return [0x1B, 0x5B, 0x32, 0x30, 0x7E]   // CSI 20 ~
    case "f10": return [0x1B, 0x5B, 0x32, 0x31, 0x7E]   // CSI 21 ~
    case "f11": return [0x1B, 0x5B, 0x32, 0x33, 0x7E]   // CSI 23 ~
    case "f12": return [0x1B, 0x5B, 0x32, 0x34, 0x7E]   // CSI 24 ~
    default:
        return nil
    }
}

/// The response. Success: `{"ok":true}` (+ optional tabs), failure: `{"ok":false,"err":"..."}`.
public struct ControlResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let err: String?
    public let tabs: [TabInfo]?
    public let panes: [PaneInfo]?
    /// dump-grid result: the visible grid as plain text, one line per row.
    public let grid: String?
    /// spawn-pane / pane-info result. Defaulted, so the original initializer is unchanged.
    public let pane: PaneInfo?
    /// group-list result.
    public let groups: [GroupInfo]?

    public init(ok: Bool, err: String? = nil, tabs: [TabInfo]? = nil, panes: [PaneInfo]? = nil,
                grid: String? = nil, pane: PaneInfo? = nil, groups: [GroupInfo]? = nil) {
        self.ok = ok
        self.err = err
        self.tabs = tabs
        self.panes = panes
        self.grid = grid
        self.pane = pane
        self.groups = groups
    }

    public static func ok() -> Self { .init(ok: true) }
    public static func err(_ msg: String) -> Self { .init(ok: false, err: msg) }
    public static func tabs(_ list: [TabInfo]) -> Self {
        .init(ok: true, tabs: list)
    }
    public static func panes(_ list: [PaneInfo]) -> Self {
        .init(ok: true, panes: list)
    }
    public static func grid(_ text: String) -> Self {
        .init(ok: true, grid: text)
    }
    /// `spawn-pane` — the id of the pane that was opened (or, on a repeated `key`, the one
    /// opened the first time).
    public static func pane(_ info: PaneInfo) -> Self {
        .init(ok: true, pane: info)
    }
    /// `group-list` — every group in every window.
    public static func groups(_ list: [GroupInfo]) -> Self {
        .init(ok: true, groups: list)
    }

    enum CodingKeys: String, CodingKey { case ok, err, tabs, panes, grid, pane, groups }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ok, forKey: .ok)
        if let err = err { try c.encode(err, forKey: .err) }
        if let tabs = tabs { try c.encode(tabs, forKey: .tabs) }
        if let panes = panes { try c.encode(panes, forKey: .panes) }
        if let grid = grid { try c.encode(grid, forKey: .grid) }
        if let pane = pane { try c.encode(pane, forKey: .pane) }
        if let groups = groups { try c.encode(groups, forKey: .groups) }
    }
}
