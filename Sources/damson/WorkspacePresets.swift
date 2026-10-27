import AppKit
import DamsonTerminal

struct WorkspacePreset: Codable {
    let id: UUID
    let name: String
    let window: RestorableWindow
}

enum WorkspacePresets {
    private struct Store: Codable { var version = 1; var presets: [WorkspacePreset] }
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Damson/workspaces.json")
    }
    static func load() throws -> [WorkspacePreset] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let store = try JSONDecoder().decode(Store.self, from: Data(contentsOf: url))
        guard store.version == 1 else {
            throw NSError(domain: "Damson", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported workspace format."])
        }
        return store.presets
    }
    static func save(_ presets: [WorkspacePreset]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Store(presets: presets)).write(to: url, options: .atomic)
    }
}

extension PaneNode {
    /// Presets carry layout and cwd only: no process, PTY identity, argv, or scrollback.
    func workspaceLayout() -> RestorablePane {
        switch kind {
        case .leaf(let session, _):
            return .leaf(cwd: session.currentDirectory ?? session.currentWorkingDirectory,
                         scrollbackID: nil, sessionID: nil, preamble: nil, fontZoom: Double(session.fontZoom))
        case .split(let direction, let first, let second, let ratio):
            return .split(direction: direction == .horizontal ? "horizontal" : "vertical", ratio: Double(ratio),
                          first: first.workspaceLayout(), second: second.workspaceLayout())
        }
    }
}

extension RestorablePane {
    /// Sanitize even edited preset files: opening a workspace never runs saved commands.
    var freshWorkspace: RestorablePane {
        switch self {
        case .leaf(let cwd, _, _, _, _, _, let zoom):
            return .leaf(cwd: cwd, scrollbackID: nil, sessionID: nil, preamble: nil, fontZoom: zoom)
        case .split(let direction, let ratio, let first, let second):
            return .split(direction: direction == "horizontal" ? "horizontal" : "vertical",
                          ratio: ratio.isFinite ? min(0.9, max(0.1, ratio)) : 0.5,
                          first: first.freshWorkspace, second: second.freshWorkspace)
        }
    }
}
