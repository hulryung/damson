import Foundation

// MARK: - Serialization model
//
// Lives here rather than in the app so the formats built on it (session restore, workspace
// presets) can be tested; the PaneNode conversions stay in the app.

/// Serialized form of a pane-tree node.
/// `scrollbackID` is the file key where that pane's scrollback is stored (when the setting is
/// on). It is optional so older saved data that lacked this field still decodes (restored
/// without scrollback).
/// `sessionID`/`preamble` exist only for leaves whose PTY was handed to the keeper at quit:
/// the id keys the claim, the preamble (base64 escape bytes from
/// `DamsonSession.stateRestorationPreamble`) rebuilds the tracked terminal modes in the
/// adopting parser. Optional for the same backward-decode reason as `scrollbackID`.
/// `paneID`/`argv` exist so a pane keeps its identity and its program across a restart:
/// the id is what an external driver addressed it by, and argv is what it was running.
/// Optional for the same backward-decode reason as the fields above — and added to the
/// EXISTING case rather than as a new one, deliberately. `load()` is one `try?` over the
/// whole state, so a saved file carrying a case an older build doesn't know would lose
/// every window's layout on a downgrade, not just the new part.
public indirect enum RestorablePane: Codable, Equatable {
    case leaf(cwd: String?, scrollbackID: String?, sessionID: String?, preamble: String?,
              paneID: String? = nil, argv: [String]? = nil, fontZoom: Double? = nil)
    case split(direction: String, ratio: Double, first: RestorablePane, second: RestorablePane)
}

/// One window = an array of tabs. Each tab is the root of a pane tree.
public struct RestorableWindow: Codable, Equatable {
    public var tabs: [RestorablePane]
    public var selectedTab: Int
    /// Per-tab custom titles (double-click rename). Same order and length as `tabs`. Optional
    /// so older saved data that lacked this field still decodes (all restored with auto titles).
    public var tabTitles: [String?]?
    /// Tab groups and which tab is in which. Optional, and left out entirely when the window
    /// has no groups, so an ordinary window's blob is byte-identical to what shipped before
    /// groups existed. Same reason as every optional above: `load()` is one `try?` over the
    /// whole state, so a required field would cost every window's layout on a downgrade.
    public var tabGroups: RestorableTabGroups?
    /// Set (true) only on the dedicated quick-terminal window, so a restart restores it as
    /// that window instead of a second ordinary one. `quickTerminalHidden` says it was
    /// ordered out at quit. Optional and omitted otherwise, for the reason above.
    public var quickTerminal: Bool?
    public var quickTerminalHidden: Bool?

    public init(tabs: [RestorablePane], selectedTab: Int, tabTitles: [String?]? = nil,
                tabGroups: RestorableTabGroups? = nil) {
        self.tabs = tabs
        self.selectedTab = selectedTab
        self.tabTitles = tabTitles
        self.tabGroups = tabGroups
    }
}

// MARK: - Workspace presets

public extension RestorablePane {
    /// Sanitize even edited preset files: opening a workspace never runs saved commands,
    /// never claims a keeper session, never reuses a pane id and never replays scrollback.
    /// Ratios are clamped to what a divider drag allows.
    var freshWorkspace: RestorablePane {
        switch self {
        case .leaf(let cwd, _, _, _, _, _, let zoom):
            return .leaf(cwd: cwd, scrollbackID: nil, sessionID: nil, preamble: nil,
                         fontZoom: zoom.flatMap { $0.isFinite ? $0 : nil })
        case .split(let direction, let ratio, let first, let second):
            return .split(direction: direction == "vertical" ? "vertical" : "horizontal",
                          ratio: ratio.isFinite ? min(0.95, max(0.05, ratio)) : 0.5,
                          first: first.freshWorkspace, second: second.freshWorkspace)
        }
    }

    /// Every leaf's saved directory, in tree order (nil-cwd leaves skipped).
    var directories: [String] {
        switch self {
        case .leaf(let cwd, _, _, _, _, _, _): return cwd.map { [$0] } ?? []
        case .split(_, _, let first, let second): return first.directories + second.directories
        }
    }
}

public extension RestorableWindow {
    /// A preset's window made safe to open: fresh leaves, titles padded/truncated to the
    /// tab count, a selected tab that exists, and never the quick-terminal role.
    var freshWorkspace: RestorableWindow {
        var w = RestorableWindow(tabs: tabs.map(\.freshWorkspace),
                                 selectedTab: tabs.indices.contains(selectedTab) ? selectedTab : 0,
                                 tabTitles: nil, tabGroups: tabGroups)
        if let titles = tabTitles {
            w.tabTitles = tabs.indices.map { titles.indices.contains($0) ? titles[$0] : nil }
        }
        return w
    }
}

public struct WorkspacePreset: Codable, Equatable {
    public let id: UUID
    public var name: String
    public var window: RestorableWindow

    public init(id: UUID = UUID(), name: String, window: RestorableWindow) {
        self.id = id
        self.name = name
        self.window = window
    }
}

/// The on-disk workspace preset file: `{"version": N, "presets": [...]}`.
public enum WorkspacePresetFile {
    public static let currentVersion = 1

    public enum LoadError: Error, Equatable, LocalizedError {
        /// Written by a newer Damson. Not overwritten: saving is refused until it is upgraded.
        case newerVersion(Int)
        case unreadable

        public var errorDescription: String? {
            switch self {
            case .newerVersion(let v):
                return "The saved workspaces were written by a newer version of Damson (format \(v)). "
                    + "Update Damson to use them; the file has been left unchanged."
            case .unreadable:
                return "The saved workspaces file could not be read. It has been left unchanged; "
                    + "move or repair ~/Library/Application Support/Damson/workspaces.json to start over."
            }
        }
    }

    private struct Header: Decodable { let version: Int? }
    private struct Store: Codable { var version: Int; var presets: [WorkspacePreset] }

    /// Reads the version before the body, so a newer format whose shape changed reports
    /// "newer version" rather than a generic decode failure.
    public static func decode(_ data: Data) throws -> [WorkspacePreset] {
        guard let header = try? JSONDecoder().decode(Header.self, from: data),
              let version = header.version, version >= 1 else { throw LoadError.unreadable }
        guard version <= currentVersion else { throw LoadError.newerVersion(version) }
        guard let store = try? JSONDecoder().decode(Store.self, from: data) else { throw LoadError.unreadable }
        return store.presets
    }

    public static func encode(_ presets: [WorkspacePreset]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Store(version: currentVersion, presets: presets))
    }
}

public extension Array where Element == WorkspacePreset {
    /// Names compare trimmed and case-insensitively, so "Api" and "api " are the same preset.
    func index(named name: String) -> Int? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return firstIndex { $0.name.compare(wanted, options: [.caseInsensitive]) == .orderedSame }
    }

    /// Adds a preset, or replaces the layout of the one with the same name (keeping its id
    /// and position). Returns true when it replaced.
    @discardableResult
    mutating func upsert(name: String, window: RestorableWindow) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = index(named: trimmed) {
            self[i].name = trimmed
            self[i].window = window
            return true
        }
        append(WorkspacePreset(name: trimmed, window: window))
        return false
    }
}
