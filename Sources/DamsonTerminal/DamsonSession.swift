import AppKit
import Combine
import Foundation

/// A single terminal instance. Bundles a PTY + parser + Grid.
/// Created and owned by the host (cmux / damson.app) and injected into `DamsonTerminalView`.
public final class DamsonSession: ObservableObject {
    @Published public private(set) var config: DamsonConfig

    @Published public private(set) var title: String = ""
    @Published public private(set) var workingDirectory: String?
    @Published public private(set) var processExited: Bool = false
    public private(set) var exitCode: Int32?

    /// Semantic events emitted by VTParser (for debug/test hooks).
    /// Screen rendering no longer goes through this; it observes `grid` + `gridChanged` instead.
    public let outputEvents = PassthroughSubject<DamsonOutputEvent, Never>()

    /// Bracketed paste mode. Toggled via CSI ?2004h/l. When on, the host wraps
    /// pasted text in ESC[200~ ... ESC[201~ on Cmd+V.
    public private(set) var bracketedPasteEnabled: Bool = false

    /// Mouse reporting mode. 0 = off, 1000 = press/release, 1002 = + drag, 1003 = any motion.
    public private(set) var mouseReportingMode: Int = 0
    /// SGR mouse encoding (CSI ?1006h). true uses SGR format, false uses X10 classic.
    public private(set) var mouseSGREncoding: Bool = false

    /// Charset designation (`ESC ( <f>` / `ESC ) <f>`) and the active GL slot (SI/SO).
    /// `'B'` (0x42) = US-ASCII; `'0'` (0x30) = DEC Special Graphics (line-drawing). When
    /// the active charset is Special Graphics, printable 0x5F…0x7E map to box/line glyphs.
    private var g0Charset: UInt8 = 0x42
    private var g1Charset: UInt8 = 0x42
    private var activeGL: Int = 0   // 0 = G0, 1 = G1

    /// Cell grid (the current viewport).
    public let grid: Grid

    /// Grid-mutation notification. May fire multiple times while processing a single
    /// PTY chunk, so the host should coalesce on a per-runloop basis.
    public let gridChanged = PassthroughSubject<Void, Never>()

    /// Host request to drop any active text selection. Selection state lives in the
    /// view layer (`DamsonTerminalView`), so the model fans the request out via this
    /// subject and the view clears + re-renders. Lets a host (cmux/`Damson.app`) clear
    /// the selection through the model API without reaching into the view.
    public let clearSelectionRequested = PassthroughSubject<Void, Never>()

    // Callbacks the host subscribes to. Prefer weak captures.
    public var onTitleChanged: ((String) -> Void)?
    /// Current working directory reported by the shell via OSC 7. Updated only when
    /// shell integration (OSC 7 emit) is enabled. The source for a split/new tab inheriting
    /// the "current directory". If never reported, stays at the spawn-time `config.cwd`.
    public private(set) var currentDirectory: String?
    public var onCwdChanged: ((String) -> Void)?
    /// Absolute line numbers of prompt lines recorded via OSC 133;A (based on scrollbackPushCount,
    /// so stable across eviction). The source for ⌘↑/⌘↓ prompt jumps. Accumulated only when
    /// shell integration (OSC 133 emit) is enabled.
    public private(set) var promptMarks: [UInt64] = []
    public var onBell: (() -> Void)?
    public var onExit: ((Int32) -> Void)?
    public var onURLClick: ((URL) -> Void)?
    public var onClipboardWrite: ((String) -> Void)?
    public var onOutput: ((Data) -> Void)?

    /// Raw pre-parse PTY bytes, multi-subscriber. Fires with exactly the chunks `onOutput`
    /// receives (and never while a `tmux -CC` takeover owns the stream), so an embedder can
    /// observe the byte stream without claiming — or clobbering — the single `onOutput`
    /// closure. Delivered synchronously on the PTY-drain thread (main), before the chunk is
    /// parsed; subscribers must not block.
    public let outputBytes = PassthroughSubject<Data, Never>()

    // The pluggable byte source/sink. Defaults to a local forkpty (`PTYHost`); a tmux -CC
    // pane injects a `TmuxPaneBackend` via the backend-factory init below — see
    // docs/TMUX-INTEGRATION.md. Whether `spawn` actually forks (PTYHost) or is a no-op
    // (tmux, already spawned) is the backend's concern.
    private let pty: SessionIOBackend
    private let parser = VTParser()

    /// Default path: a local forkpty session. Behavior is identical to before the seam —
    /// the backend is a freshly constructed `PTYHost`.
    public convenience init(config: DamsonConfig, restoredScrollback: [Line]? = nil) {
        self.init(config: config, restoredScrollback: restoredScrollback, backend: PTYHost(),
                  initialCols: 80, initialRows: 24)
    }

    /// Backend-injection path: construct a session over an arbitrary `SessionIOBackend`
    /// (e.g. a `TmuxPaneBackend` for a tmux `-CC` pane). `spawn` is still called with the
    /// config's argv/env/cwd; a tmux backend treats it as a no-op.
    public convenience init(config: DamsonConfig, restoredScrollback: [Line]? = nil,
                            backend: SessionIOBackend) {
        self.init(config: config, restoredScrollback: restoredScrollback, backend: backend,
                  initialCols: 80, initialRows: 24)
    }

    /// Opt-in initial-size spawn over the default forkpty backend — see the designated
    /// init below for why an embedder would pass a size.
    public convenience init(config: DamsonConfig, restoredScrollback: [Line]? = nil,
                            initialCols: Int, initialRows: Int) {
        self.init(config: config, restoredScrollback: restoredScrollback, backend: PTYHost(),
                  initialCols: initialCols, initialRows: initialRows)
    }

    /// Designated init. The two-argument forms above keep the historical contract — spawn
    /// at 80×24, with the host expected to `resize` once its real geometry is known. An
    /// embedder that already knows its grid passes it here, so the child starts at the
    /// right size instead of laying out at 80×24 and reflowing on the first SIGWINCH.
    /// Non-positive values are clamped to 1; existing callers and behavior are unchanged.
    public init(config: DamsonConfig, restoredScrollback: [Line]? = nil,
                backend: SessionIOBackend, initialCols: Int, initialRows: Int) {
        let cols = max(1, initialCols)
        let rows = max(1, initialRows)
        self.pty = backend
        self.config = config
        self.currentDirectory = config.cwd
        // Width policy for EAW-Ambiguous symbols (process-global user setting).
        Cell.treatAmbiguousAsWide = config.ambiguousWide
        self.grid = Grid(
            cols: cols,
            rows: rows,
            pen: CellAttrs(fg: .default)
        )
        self.grid.maxScrollbackLines = config.scrollbackLines
        self.grid.setCursorShape(config.cursorShape)
        // Seed the previous session's scrollback before any live output (session restore; passed only when the setting is on).
        if let restoredScrollback { grid.seedScrollback(restoredScrollback) }

        parser.delegate = self

        pty.onData = { [weak self] data in
            self?.handlePTYData(data)
        }
        pty.onExit = { [weak self] code in
            self?.handlePTYExit(code: code)
        }

        do {
            try pty.spawn(
                argv: config.argv,
                env: config.env,
                cwd: config.cwd,
                cols: cols,
                rows: rows
            )
        } catch {
            NSLog("damson: PTY spawn failed: \(error)")
        }
    }

    // MARK: - Restart survival (keeper handoff / adoption)

    /// Detach the local PTY from this session for handoff to the keeper — the child
    /// keeps running, this session just stops owning it. nil when there is nothing
    /// sensible to hand off: tmux-backed panes (tmux already persists them) and the
    /// `tmux -CC` control client (adopting a control-mode byte stream into a fresh
    /// session would splice a half-spoken protocol).
    public func releasePTYForHandoff() -> PTYHost.PTYHandoff? {
        guard !inTmuxControlMode, let host = pty as? PTYHost else { return nil }
        return host.releaseOwnership()
    }

    /// The escape bytes that recreate this session's tracked terminal state in a fresh
    /// parser — replayed into the ADOPTING session before any live output, so modes set
    /// long before the restart (mouse reporting, bracketed paste, alt screen…) survive it.
    /// Lives here, next to `applyModeChange`, so the two can't drift apart: everything
    /// damson tracks is emitted, everything it doesn't track has nothing to restore.
    /// (Scroll region and saved cursor are deliberately absent — the post-adopt SIGWINCH
    /// makes any full-screen program repaint and re-establish those itself.)
    public func stateRestorationPreamble() -> Data {
        var out = ""
        if !title.isEmpty {
            out += "\u{1b}]2;\(title)\u{07}"
        }
        if g0Charset != 0x42 { out += "\u{1b}(\(Character(UnicodeScalar(g0Charset)))" }
        if g1Charset != 0x42 { out += "\u{1b})\(Character(UnicodeScalar(g1Charset)))" }
        if activeGL == 1 { out += "\u{0e}" }                     // SO — G1 active
        if grid.isAltScreenActive { out += "\u{1b}[?1049h" }
        if !grid.cursorVisible { out += "\u{1b}[?25l" }
        if grid.insertMode { out += "\u{1b}[4h" }
        if bracketedPasteEnabled { out += "\u{1b}[?2004h" }
        if mouseReportingMode > 0 { out += "\u{1b}[?\(mouseReportingMode)h" }
        if mouseSGREncoding { out += "\u{1b}[?1006h" }
        if grid.hasUsedSyncOutput {
            // Re-arm the sticky "this app uses sync output" bit; the transient
            // in-sync state must end false, hence the immediate reset.
            out += "\u{1b}[?2026h\u{1b}[?2026l"
        }
        if grid.cursorShape != config.cursorShape {
            let ps: Int
            switch grid.cursorShape {
            case .block: ps = 2
            case .underline: ps = 4
            case .bar: ps = 6
            }
            out += "\u{1b}[\(ps) q"
        }
        return Data(out.utf8)
    }

    /// Additional input beyond key events (e.g. text synthesized by the host).
    public func write(_ bytes: Data) {
        pty.write(bytes)
    }

    /// The child shell's current working directory (for session restore). nil on failure.
    public var currentWorkingDirectory: String? {
        pty.childWorkingDirectory
    }

    /// Whether this session is running a command in the foreground (rather than waiting at a prompt).
    /// Used so the quit-confirmation dialog only prompts when there's actually a running job.
    public var hasRunningForegroundJob: Bool {
        pty.isRunningForegroundJob
    }

    /// The process group owning this session's terminal, when it has one. A host uses this
    /// to tell *what* is running in the pane — e.g. to match it against a tool's own
    /// process registry. nil for backends with no tty (tmux panes) and for a dead child.
    public var foregroundProcessID: pid_t? {
        pty.foregroundPID
    }

    public func resize(cols: Int, rows: Int) {
        dumpEvent("resize", cols, rows)
        // While a foreground app owns the screen, don't physically preserve (clip) the
        // "prompt block" — the shell won't redraw it, and clipping would permanently
        // truncate the app's output on width shrink. See Grid.resize(preservePromptBlock:).
        grid.resize(cols: cols, rows: rows, preservePromptBlock: !hasRunningForegroundJob)
        pty.resize(cols: cols, rows: rows)
        gridChanged.send()
    }

    /// Reflow the on-screen grid to a new size WITHOUT notifying the shell
    /// (no SIGWINCH). Used during a live window resize so the shell doesn't redraw
    /// (and accumulate) its prompt on every drag frame; the host sends one real
    /// `resize` (SIGWINCH) when the drag ends.
    public func resizeGridOnly(cols: Int, rows: Int) {
        dumpEvent("resize-grid-only", cols, rows)
        grid.resize(cols: cols, rows: rows, preservePromptBlock: !hasRunningForegroundJob)
        gridChanged.send()
    }

    /// Drop any active text selection. Selection state is owned by the view, so this
    /// fans the request out over `clearSelectionRequested`; the subscribed view clears
    /// its anchor/head and re-renders.
    public func clearSelection() {
        clearSelectionRequested.send()
    }

    /// Called on hot-reload, e.g. when the font/colors/palette change.
    /// Since `config` is `@Published`, subscribers (the view) react automatically.
    public func updateConfig(_ config: DamsonConfig) {
        self.config = config
        Cell.treatAmbiguousAsWide = config.ambiguousWide
        grid.maxScrollbackLines = config.scrollbackLines
        // Apply the user's default cursor shape immediately. An app may later
        // override it via DECSCUSR; that takes precedence until the next reset.
        grid.setCursorShape(config.cursorShape)
    }

    public func terminate() {
        pty.terminate()
    }

    // MARK: - Internals

    /// Posted (object = the session) when this session's output stream entered tmux `-CC`
    /// control mode — i.e. the user ran `tmux -CC …` in this pane. The app observes this to
    /// take the byte stream over into a `TmuxControlClient` (native tmux windows).
    public static let tmuxControlModeDetectedNotification =
        Notification.Name("DamsonSessionTmuxControlModeDetected")

    /// True while this session's stream is a tmux control-mode stream (post-DCS-takeover):
    /// bytes route to `onTmuxControlData` instead of the VT parser/grid.
    public private(set) var inTmuxControlMode = false

    /// Raw control-stream consumer while in tmux control mode. Set by `TmuxTakeoverBackend`
    /// (synchronously, inside the takeover notification) so the first control bytes that
    /// followed the DCS introducer aren't lost.
    public var onTmuxControlData: ((Data) -> Void)?

    /// Resume normal terminal parsing after the control stream ended (`%exit` — the user
    /// detached or the tmux server quit). The wrapped shell is back at its prompt.
    public func endTmuxControlMode() {
        inTmuxControlMode = false
        onTmuxControlData = nil
        parser.endTmuxTakeover()
    }

    /// DAMSON_DUMP_OUTPUT=<dir> — append every raw output byte this session receives to a
    /// per-session file in <dir>. The captured stream can be replayed through VTParser+Grid
    /// in a test to reproduce rendering bugs exactly (docs/TMUX-INTEGRATION.md §15.2).
    private lazy var dumpHandle: FileHandle? = {
        guard let dir = ProcessInfo.processInfo.environment["DAMSON_DUMP_OUTPUT"],
              !dir.isEmpty else { return nil }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let base = "\(dir)/session-\(stamp)-\(UInt(bitPattern: ObjectIdentifier(self).hashValue) & 0xFFFF)"
        FileManager.default.createFile(atPath: base + ".bin", contents: nil)
        FileManager.default.createFile(atPath: base + ".events", contents: nil)
        dumpEventsHandle = FileHandle(forWritingAtPath: base + ".events")
        return FileHandle(forWritingAtPath: base + ".bin")
    }()
    /// Side-channel for the dump: one line per resize, `<byte-offset> resize <cols> <rows>`,
    /// where byte-offset is the position in the .bin stream BEFORE which the resize landed.
    /// A replay harness interleaves them to reproduce resize races deterministically.
    private var dumpEventsHandle: FileHandle?
    private var dumpByteCount: UInt64 = 0

    private func dumpEvent(_ kind: String, _ cols: Int, _ rows: Int) {
        guard dumpHandle != nil, let h = dumpEventsHandle else { return }
        h.write(Data("\(dumpByteCount) \(kind) \(cols) \(rows)\n".utf8))
    }

    private func handlePTYData(_ data: Data) {
        dumpHandle?.write(data)
        dumpByteCount += UInt64(data.count)
        if inTmuxControlMode {
            onTmuxControlData?(data)
            return
        }
        onOutput?(data)
        outputBytes.send(data)
        parser.feed(data)
        if parser.tmuxControlModeDetected {
            // The user ran `tmux -CC` in this pane. Post FIRST so an observer can install
            // `onTmuxControlData` (via TmuxTakeoverBackend), THEN hand over the control
            // bytes that arrived in the same chunk as the DCS introducer.
            inTmuxControlMode = true
            NotificationCenter.default.post(
                name: Self.tmuxControlModeDetectedNotification, object: self)
            let remainder = parser.takeTakeoverRemainder()
            if !remainder.isEmpty { onTmuxControlData?(remainder) }
        }
        gridChanged.send()
    }

    private func handlePTYExit(code: Int32) {
        processExited = true
        exitCode = code
        onExit?(code)
    }

    /// OSC dispatch — 0/2 (title), 4/10/11 (color query), 8 (hyperlink); everything else ignored.
    fileprivate func dispatchOSCIfNeeded(_ oscParams: [String]) {
        guard let kind = oscParams.first else { return }
        switch kind {
        case "0", "2":
            guard oscParams.count >= 2 else { return }
            let newTitle = oscParams[1]
            if newTitle != title {
                title = newTitle
                onTitleChanged?(newTitle)
            }
        case "4":
            // OSC 4 ; index ; spec — query if spec == "?"
            guard oscParams.count >= 3, oscParams[2] == "?",
                  let index = Int(oscParams[1]), (0...15).contains(index) else { return }
            let color = config.theme.paletteColor(index)
            respondToOSCColorQuery(kind: "4", index: index, color: color)
        case "10":
            // OSC 10 ; ? — query default fg
            guard oscParams.count >= 2, oscParams[1] == "?" else { return }
            respondToOSCColorQuery(kind: "10", index: nil, color: config.foregroundColor)
        case "11":
            // OSC 11 ; ? — query default bg
            guard oscParams.count >= 2, oscParams[1] == "?" else { return }
            respondToOSCColorQuery(kind: "11", index: nil, color: config.backgroundColor)
        case "7":
            // OSC 7 ; file://host/path ST — the current working directory reported by the shell.
            guard oscParams.count >= 2,
                  let path = Self.parseFileURLPath(oscParams[1]) else { return }
            if path != currentDirectory {
                currentDirectory = path
                onCwdChanged?(path)
            }
        case "8":
            // OSC 8 ; params ; URI ST
            //   start: params is typically "id=xxx" or an empty string, URI non-empty
            //   end: URI empty
            let uri = oscParams.count >= 3 ? oscParams[2] : ""
            grid.setHyperlink(uri.isEmpty ? nil : uri)
        case "133":
            // OSC 133 ; A/B/C/D — FinalTerm semantic prompt. v1 uses only A (prompt start)
            // to mark prompt lines. B/C/D are reserved for the future.
            if oscParams.count >= 2, oscParams[1] == "A" {
                let absLine = grid.scrollbackPushCount + UInt64(max(0, grid.cursorRow))
                if promptMarks.last != absLine {
                    promptMarks.append(absLine)
                    if promptMarks.count > 5000 {
                        promptMarks.removeFirst(promptMarks.count - 5000)
                    }
                }
                // Mark this row so a resize preserves the whole prompt block's
                // physical-row count (keeps the shell's relative redraw in sync).
                grid.markPromptStart()
            }
        default:
            break
        }
    }

    /// Extracts just the path portion from OSC 7's `file://host/path` (percent-decoded). host is ignored.
    static func parseFileURLPath(_ uri: String) -> String? {
        guard uri.hasPrefix("file://") else { return nil }
        let afterScheme = uri.dropFirst("file://".count)
        // The path starts at the first '/' after host. If host is empty (`file:///path`), that's '/' right away.
        guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
        let path = String(afterScheme[slash...])
        return path.removingPercentEncoding ?? path
    }

    private func respondToOSCColorQuery(kind: String, index: Int?, color: NSColor) {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let r = UInt16(max(0, min(1, srgb.redComponent)) * 65535)
        let g = UInt16(max(0, min(1, srgb.greenComponent)) * 65535)
        let b = UInt16(max(0, min(1, srgb.blueComponent)) * 65535)
        let rgbSpec = String(format: "rgb:%04x/%04x/%04x", r, g, b)
        let payload: String
        if let index = index {
            payload = "\(kind);\(index);\(rgbSpec)"
        } else {
            payload = "\(kind);\(rgbSpec)"
        }
        let response = "\u{1B}]\(payload)\u{1B}\\"
        if let data = response.data(using: .utf8) {
            pty.write(data)
        }
    }

    /// Converts a CSI emitted by the parser into a grid mutation.
    fileprivate func handleCSI(
        params: [Int],
        intermediates: [UInt8],
        finalByte: UInt8,
        privateMarker: UInt8?
    ) {
        // Common default handling: when the first param is unspecified (-1) or 0, treat it as 1.
        let p1 = (params.first ?? -1) <= 0 ? 1 : params[0]

        // Dispatch by category. Each CSI final byte belongs to exactly one group,
        // so the order between handlers doesn't matter; each returns whether it
        // consumed the byte.
        if applyCursorCSI(finalByte, p1: p1, params: params) { return }
        if applyEditCSI(finalByte, p1: p1, params: params) { return }
        if applyStateCSI(finalByte, params: params, intermediates: intermediates, privateMarker: privateMarker) { return }
        if applyReportCSI(finalByte, params: params, intermediates: intermediates, privateMarker: privateMarker) { return }

        switch finalByte {
        case 0x6D:                          // m — SGR
            // SGR applies to `CSI ... m` only when there's **neither** a private marker
            // nor an intermediate. `CSI > 4 ; 2 m` (xterm modifyOtherKeys / Kitty keyboard
            // protocol) and `CSI ? Pn m` (DEC private SGR) etc. are not SGR.
            // Claude Code sends `\x1b[>4;2m` at startup; treating it as SGR would set
            // param 4 → underline ON, and with no following reset the underline leaks
            // across the whole session.
            // Mirrors: anthropics/claude-code#23698, halite Rust 40bd82f.
            if privateMarker == nil && intermediates.isEmpty {
                grid.applySGR(params)
            }
        case 0x68:                          // h — SET MODE
            applyModeChange(params: params, privateMarker: privateMarker, set: true)
        case 0x6C:                          // l — RESET MODE
            applyModeChange(params: params, privateMarker: privateMarker, set: false)
        default:
            break // Ignore unsupported CSI (alt screen / scroll region, etc. land in a later milestone)
        }
    }

    /// Cursor positioning CSIs (CUU/CUD/CUF/CUB/CNL/CPL/CUP/CHA/HPA/VPA).
    private func applyCursorCSI(_ finalByte: UInt8, p1: Int, params: [Int]) -> Bool {
        switch finalByte {
        case 0x41: grid.cursorUp(p1)        // A — CUU
        case 0x42: grid.cursorDown(p1)      // B — CUD
        case 0x43: grid.cursorForward(p1)   // C — CUF
        case 0x44: grid.cursorBack(p1)      // D — CUB
        case 0x45:                          // E — CNL: down n lines, to column 1
            grid.cursorDown(p1)
            grid.setCursorColumn(1)
        case 0x46:                          // F — CPL: up n lines, to column 1.
            // Multi-line progress UIs (Homebrew's concurrent downloads) repaint
            // their status block with this; dropping it duplicates the block
            // below on every refresh.
            grid.cursorUp(p1)
            grid.setCursorColumn(1)
        case 0x48, 0x66:                    // H / f — CUP / HVP
            let r = (!params.isEmpty && params[0] > 0) ? params[0] : 1
            let c = (params.count > 1 && params[1] > 0) ? params[1] : 1
            grid.setCursor(row: r, col: c)
        case 0x47, 0x60:                    // G / ` — CHA / HPA: move to absolute column
            grid.setCursorColumn(p1)
        case 0x64:                          // d — VPA: move to absolute row
            grid.setCursorRow(p1)
        default: return false
        }
        return true
    }

    /// Erase / insert / delete / scroll CSIs (ED/EL/ECH/IL/DL/ICH/DCH/SU/SD).
    private func applyEditCSI(_ finalByte: UInt8, p1: Int, params: [Int]) -> Bool {
        switch finalByte {
        case 0x4A:                          // J — ED
            let mode = (params.first ?? -1) < 0 ? 0 : params[0]
            grid.eraseInDisplay(mode: mode)
        case 0x4B:                          // K — EL
            let mode = (params.first ?? -1) < 0 ? 0 : params[0]
            grid.eraseInLine(mode: mode)
        case 0x58: grid.eraseChars(p1)        // X — ECH: erase n cells from the cursor
        case 0x4C: grid.insertLines(p1)       // L — IL: insert n blank lines
        case 0x4D: grid.deleteLines(p1)       // M — DL: delete n lines
        case 0x40: grid.insertChars(p1)       // @ — ICH: insert n blank cells
        case 0x50: grid.deleteChars(p1)       // P — DCH: delete n cells
        case 0x53: grid.scrollUp(count: p1)   // S — SU
        case 0x54: grid.scrollDown(count: p1) // T — SD
        default: return false
        }
        return true
    }

    /// State-setting CSIs that have no program response: save/restore cursor (SC/RC),
    /// scroll region (DECSTBM), cursor shape (DECSCUSR).
    private func applyStateCSI(_ finalByte: UInt8, params: [Int], intermediates: [UInt8],
                               privateMarker: UInt8?) -> Bool {
        switch finalByte {
        case 0x73:                          // s — SC (DECSC ANSI variant)
            if privateMarker == nil { grid.saveCursor() }
        case 0x75:                          // u — RC (DECRC ANSI variant)
            if privateMarker == nil { grid.restoreCursor() }
        case 0x72:                          // r — DECSTBM (must have no private marker)
            if privateMarker == nil {
                let top = (!params.isEmpty && params[0] > 0) ? params[0] : 1
                let bot = (params.count > 1 && params[1] > 0) ? params[1] : grid.rows
                grid.setScrollRegion(top: top - 1, bottom: bot - 1)
            }
        case 0x71:                          // q — DECSCUSR (intermediate=SP)
            if privateMarker == nil && intermediates == [0x20] {
                let shape: Grid.CursorShape
                switch params.first ?? 0 {
                case 1, 2: shape = .block
                case 3, 4: shape = .underline
                case 5, 6: shape = .bar
                default: shape = config.cursorShape  // 0/unspecified = reset → user default
                }
                grid.setCursorShape(shape)
            }
        case 0x67:                          // g — TBC (tab clear)
            if privateMarker == nil { applyTabClear(params) }
        default: return false
        }
        return true
    }

    /// TBC (`CSI g`): 0 clears the tab stop at the cursor, 3 clears every stop.
    private func applyTabClear(_ params: [Int]) {
        switch params.first ?? 0 {
        case 0: grid.clearTabStop()
        case 3: grid.clearAllTabStops()
        default: break
        }
    }

    /// CSIs that write a reply back to the program: device attributes (DA1/DA2)
    /// and device status report (DSR — operating status / cursor position).
    private func applyReportCSI(_ finalByte: UInt8, params: [Int], intermediates: [UInt8],
                                privateMarker: UInt8?) -> Bool {
        switch finalByte {
        case 0x63:                          // c — DA1 / DA2
            if privateMarker == nil && intermediates.isEmpty {
                // Primary DA → VT102 identification: ESC [ ? 6 c
                pty.write(Data([0x1B, 0x5B, 0x3F, 0x36, 0x63]))
            } else if privateMarker == 0x3E && intermediates.isEmpty {
                // Secondary DA → ESC [ > 0 ; 0 ; 0 c (generic)
                pty.write(Data([0x1B, 0x5B, 0x3E, 0x30, 0x3B, 0x30, 0x3B, 0x30, 0x63]))
            }
        case 0x6E:                          // n — DSR (Device Status Report)
            // Only the ANSI form (no private marker). Many CLIs — gh, shell
            // prompt frameworks, vim — send `CSI 6 n` and BLOCK on a read until
            // the cursor-position report comes back; without it they stall ~5s
            // on a timeout (the "gh is slow inside damson" symptom).
            if privateMarker == nil {
                switch params.first ?? 0 {
                case 5:
                    // Operating-status report → terminal OK: ESC [ 0 n
                    pty.write(Data([0x1B, 0x5B, 0x30, 0x6E]))
                case 6:
                    // Cursor Position Report → ESC [ row ; col R (1-based, screen-relative).
                    let row = min(max(grid.cursorRow + 1, 1), grid.rows)
                    let col = min(max(grid.cursorCol + 1, 1), grid.cols)
                    pty.write(Data("\u{1B}[\(row);\(col)R".utf8))
                default:
                    break
                }
            }
        default: return false
        }
        return true
    }

    private func applyModeChange(params: [Int], privateMarker: UInt8?, set: Bool) {
        // ANSI (non-private) modes. The only one we implement is IRM (mode 4).
        if privateMarker == nil {
            for p in params where p == 4 { grid.setInsertMode(set) }
            return
        }
        // DEC private modes (`?`).
        guard privateMarker == 0x3F else { return }
        for p in params where p > 0 {
            switch p {
            case 25:
                grid.setCursorVisible(set)
            case 47, 1047, 1049:
                // The difference between 47/1047/1049 is a subtle one in cursor-save and clear
                // timing, but M3.7 treats all three identically as "enter/leave alt". In practice
                // vim/less/htop are fine.
                if set {
                    grid.enterAltScreen()
                } else {
                    grid.leaveAltScreen()
                }
            case 2004:
                // Bracketed paste mode toggle. Read by the host (view).
                bracketedPasteEnabled = set
            case 1000, 1002, 1003:
                // Enable mouse reporting — keep only the strongest mode.
                mouseReportingMode = set ? p : 0
            case 1006:
                // SGR mouse encoding
                mouseSGREncoding = set
            case 2026:
                // Synchronized Output Mode (DECSET 2026) — used by apps that don't use the
                // alt-screen and instead redraw on the primary screen via cursor positioning,
                // such as Claude Code and Ink-based TUIs.
                //   - hasUsedSyncOutput: once set even once, becomes sticky-true. Enables
                //     TUI-friendly policies such as viewport-top anchoring on resize.
                //   - inSyncOutputMode: transient (set ⇔ true, clear ⇔ false).
                //     Used by the host to batch a frame up to the ESU and present it atomically
                //     (avoiding torn frames). Unrelated to scrollback accumulation — sync is just
                //     a presentation hint, so lines that scroll off during a redraw still
                //     accumulate normally.
                if set { grid.hasUsedSyncOutput = true }
                grid.inSyncOutputMode = set
            default:
                break
            }
        }
    }
}

extension DamsonSession: VTParserDelegate {
    public func vtParser(_ parser: VTParser, didEmitText text: String) {
        // SI/SO flush pending text before switching GL, so the whole run shares one
        // charset. When it's DEC Special Graphics, translate each cell to its line-glyph.
        let graphics = (activeGL == 0 ? g0Charset : g1Charset) == 0x30
        if graphics {
            for ch in text { grid.putChar(Self.decSpecialGraphic(ch)) }
        } else {
            for ch in text { grid.putChar(ch) }
        }
        outputEvents.send(.text(text))
    }

    public func vtParser(_ parser: VTParser, didDesignateCharset slot: Int, charset: UInt8) {
        switch slot {
        case 0: g0Charset = charset
        case 1: g1Charset = charset
        default: break   // G2/G3 aren't reachable via SI/SO; store nothing.
        }
    }

    public func vtParser(_ parser: VTParser, didExecute byte: UInt8) {
        switch byte {
        case 0x0E: activeGL = 1   // SO (shift-out) — invoke G1 into GL
        case 0x0F: activeGL = 0   // SI (shift-in)  — invoke G0 into GL
        case 0x08: grid.backspace()
        case 0x0A: grid.lineFeed()
        case 0x0D: grid.carriageReturn()
        case 0x09:
            // HT (TAB) — move the cursor to the next tab stop (respects HTS/TBC edits).
            grid.tabForward()
        case 0x07:
            onBell?()
        default:
            break
        }
        outputEvents.send(.execute(byte))
    }

    public func vtParser(
        _ parser: VTParser,
        didEmitCSI params: [Int],
        intermediates: [UInt8],
        finalByte: UInt8,
        privateMarker: UInt8?
    ) {
        handleCSI(params: params, intermediates: intermediates, finalByte: finalByte, privateMarker: privateMarker)
        outputEvents.send(.csi(
            params: params,
            intermediates: intermediates,
            finalByte: finalByte,
            privateMarker: privateMarker
        ))
    }

    public func vtParser(_ parser: VTParser, didEmitOSC params: [String]) {
        dispatchOSCIfNeeded(params)
        outputEvents.send(.osc(params))
    }

    /// DEC Special Graphics (VT100 line-drawing) for 0x5F…0x7E; other chars pass through.
    /// Applied when the active charset is `'0'` (`ESC ( 0`, selected via SI/SO).
    private static let decGraphicsTable: [Character] = [
        "\u{00A0}", "\u{25C6}", "\u{2592}", "\u{2409}", "\u{240C}", "\u{240D}", "\u{240A}",
        "\u{00B0}", "\u{00B1}", "\u{2424}", "\u{240B}", "\u{2518}", "\u{2510}", "\u{250C}",
        "\u{2514}", "\u{253C}", "\u{23BA}", "\u{23BB}", "\u{2500}", "\u{23BC}", "\u{23BD}",
        "\u{251C}", "\u{2524}", "\u{2534}", "\u{252C}", "\u{2502}", "\u{2264}", "\u{2265}",
        "\u{03C0}", "\u{2260}", "\u{00A3}", "\u{00B7}",
    ]

    private static func decSpecialGraphic(_ ch: Character) -> Character {
        guard ch.unicodeScalars.count == 1, let v = ch.unicodeScalars.first?.value,
              (0x5F...0x7E).contains(v) else { return ch }
        return decGraphicsTable[Int(v - 0x5F)]
    }

    public func vtParser(_ parser: VTParser, didEmitESC finalByte: UInt8) {
        switch finalByte {
        case 0x37: // '7' — DECSC: save cursor + pen
            grid.saveCursor()
        case 0x38: // '8' — DECRC: restore cursor + pen
            grid.restoreCursor()
        case 0x44: // 'D' — IND: cursor down one line, scrolling at the region bottom.
            grid.lineFeed()
        case 0x45: // 'E' — NEL: IND plus a carriage return.
            grid.carriageReturn()
            grid.lineFeed()
        case 0x4D: // 'M' — RI: cursor UP one line, scrolling the region DOWN at the top.
            grid.reverseIndex()
        case 0x48: // 'H' — HTS: set a horizontal tab stop at the cursor column
            grid.setTabStop()
        case 0x63: // 'c' — RIS: reset the terminal to its power-on state.
            grid.fullReset()
            // Reset session-level private modes an app may have left on, so a program
            // using RIS to recover isn't stranded with mouse reporting / bracketed paste
            // / sync-output still active. (hasUsedSyncOutput is a sticky per-session hint
            // and intentionally not reset.)
            bracketedPasteEnabled = false
            mouseReportingMode = 0
            mouseSGREncoding = false
            grid.inSyncOutputMode = false
            g0Charset = 0x42
            g1Charset = 0x42
            activeGL = 0
        case 0x3D, 0x3E: // '=' / '>' — application/normal keypad mode (ignored in M3.9)
            break
        default:
            break
        }
    }
}
