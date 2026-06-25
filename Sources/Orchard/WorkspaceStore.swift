import AppKit
import Combine
import DamsonTerminal
import DamsonOrchestrator

/// One orchestration workspace: a git repo plus its `OrchestratorController` (the brain
/// that spawns/drives agents in that repo's worktrees).
@MainActor
final class Workspace: ObservableObject, Identifiable {
    let id = UUID()
    let name: String
    let repo: URL
    let controller: OrchestratorController

    init(repo: URL, theme: DamsonTheme) throws {
        self.repo = repo
        self.name = repo.lastPathComponent
        let root = repo.appendingPathComponent(".damson", isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
        var config = DamsonConfig()
        config.theme = theme
        self.controller = OrchestratorController(
            baseRepo: repo,
            worktreesRoot: root,
            configTemplate: config
        )
        try controller.start()
    }
}

/// Top-level app state: workspaces, selection, sheet routing, and the chosen color theme.
/// Workspaces and theme persist across launches via `UserDefaults` (Orchard's own domain).
@MainActor
final class WorkspaceStore: ObservableObject {
    /// How the detail area presents a workspace's agents.
    enum DetailMode: Hashable { case grid, tabs }

    @Published var workspaces: [Workspace] = []
    @Published var selectedWorkspaceID: Workspace.ID?
    @Published var selectedAgentID: UUID?
    /// Non-nil drives the "Add Task" (mission) sheet for that workspace.
    @Published var addTaskWorkspaceID: Workspace.ID?
    /// Non-nil drives the "New Session" (engine picker, no mission) sheet.
    @Published var newSessionWorkspaceID: Workspace.ID?

    /// Grid overview vs. damson-style tabbed (one large terminal + tab bar).
    @Published var detailMode: DetailMode = .grid
    /// The agent shown large in `.tabs` mode (and highlighted in the tab bar).
    @Published var focusedAgentID: UUID?

    /// Selected terminal color theme (applies to all agent terminals).
    @Published var themeName: String {
        didSet {
            defaults.set(themeName, forKey: themeKey)
            applyThemeToAll()
        }
    }

    private let defaults = UserDefaults.standard
    private let workspacesKey = "orchard.workspaces"
    private let themeKey = "orchard.theme"

    init() {
        themeName = defaults.string(forKey: themeKey)
            ?? DamsonTheme.presets.first?.name
            ?? DamsonConfig().theme.name
    }

    var theme: DamsonTheme {
        DamsonTheme.preset(named: themeName) ?? DamsonTheme.presets.first ?? DamsonConfig().theme
    }

    var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    /// Re-open workspaces saved from a previous launch (quietly skips missing/invalid repos).
    func restore() {
        guard let paths = defaults.stringArray(forKey: workspacesKey) else { return }
        for path in paths {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue
            else { continue }
            addWorkspace(repo: url, silent: true)
        }
    }

    /// Choose a git repo and open it as a workspace.
    func addWorkspaceViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Workspace"
        panel.message = "Choose a git repository to orchestrate agents in."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addWorkspace(repo: url)
    }

    func addWorkspace(repo: URL, silent: Bool = false) {
        if let existing = workspaces.first(where: { $0.repo.standardizedFileURL == repo.standardizedFileURL }) {
            selectedWorkspaceID = existing.id
            return
        }
        do {
            let ws = try Workspace(repo: repo, theme: theme)
            workspaces.append(ws)
            selectedWorkspaceID = ws.id
            persistWorkspaces()
        } catch {
            guard !silent else { return }
            let alert = NSAlert()
            alert.messageText = "Couldn't open workspace"
            alert.informativeText = String(describing: error)
            alert.runModal()
        }
    }

    func removeWorkspace(_ ws: Workspace) {
        ws.controller.shutdown(removeWorktrees: false)
        workspaces.removeAll { $0.id == ws.id }
        if selectedWorkspaceID == ws.id { selectedWorkspaceID = workspaces.first?.id }
        persistWorkspaces()
    }

    /// Maximize one agent into the damson-style tabbed view.
    func focus(_ agentID: UUID) {
        focusedAgentID = agentID
        detailMode = .tabs
    }

    /// Trigger the Add-Task (mission) sheet for the selected workspace (toolbar + / CLI).
    func requestAddTaskForSelected() {
        guard let id = selectedWorkspaceID else {
            addWorkspaceViaPanel()
            return
        }
        addTaskWorkspaceID = id
    }

    /// Cmd-T / Cmd-D: open the engine picker to start a new mission-less session, switching
    /// to the requested layout (tabs = stacked, grid = beside).
    func requestNewSession(mode: DetailMode) {
        guard let id = selectedWorkspaceID else {
            addWorkspaceViaPanel()
            return
        }
        detailMode = mode
        newSessionWorkspaceID = id
    }

    func shutdownAll() {
        for ws in workspaces { ws.controller.shutdown(removeWorktrees: false) }
    }

    private func applyThemeToAll() {
        let t = theme
        for ws in workspaces { ws.controller.applyTheme(t) }
    }

    private func persistWorkspaces() {
        defaults.set(workspaces.map { $0.repo.path }, forKey: workspacesKey)
    }
}
