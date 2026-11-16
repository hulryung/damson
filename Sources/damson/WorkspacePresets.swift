import AppKit
import DamsonTabGroups
import DamsonTerminal

/// File I/O for workspace presets. The format, version check, sanitization and name rules
/// live in DamsonTabGroups (`WorkspacePresetFile`) where they are tested.
enum WorkspacePresets {
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Damson/workspaces.json")
    }
    /// Throws (and the caller must not save) when the file exists but is unreadable or newer:
    /// saving over it would destroy presets this build cannot see.
    static func load() throws -> [WorkspacePreset] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try WorkspacePresetFile.decode(Data(contentsOf: url))
    }
    static func save(_ presets: [WorkspacePreset]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WorkspacePresetFile.encode(presets).write(to: url, options: .atomic)
    }
}

extension PaneNode {
    /// Presets carry layout and cwd only: no process, PTY identity, argv, or scrollback.
    func workspaceLayout() -> RestorablePane {
        switch kind {
        case .leaf(let session, _):
            return .leaf(cwd: session.currentWorkingDirectory ?? session.currentDirectory,
                         scrollbackID: nil, sessionID: nil, preamble: nil,
                         fontZoom: session.fontZoom == 1.0 ? nil : Double(session.fontZoom))
        case .split(let direction, let first, let second, let ratio):
            return .split(direction: direction == .horizontal ? "horizontal" : "vertical", ratio: Double(ratio),
                          first: first.workspaceLayout(), second: second.workspaceLayout())
        }
    }
}
