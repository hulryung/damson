import SwiftUI
import DamsonOrchestrator

/// Top-level layout: a workspace/agent sidebar and a detail area showing the selected
/// workspace's agents as a grid of live terminal tiles.
struct RootView: View {
    @EnvironmentObject var store: WorkspaceStore
    /// Sidebar can be collapsed (hidden) or shown; also drag-resizable within the width range.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 170, ideal: 240, max: 380)
        } detail: {
            Group {
                if let ws = store.selectedWorkspace {
                    WorkspaceDetailView(workspace: ws)
                } else {
                    EmptyStateView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
                        }
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .help("Toggle sidebar (⌃⌘S)")
                    .keyboardShortcut("s", modifiers: [.command, .control])
                }
            }
        }
        .sheet(isPresented: addTaskPresented) {
            if let ws = store.workspaces.first(where: { $0.id == store.addTaskWorkspaceID }) {
                AddTaskSheet(workspace: ws)
            }
        }
        .sheet(isPresented: newSessionPresented) {
            if let ws = store.workspaces.first(where: { $0.id == store.newSessionWorkspaceID }) {
                NewSessionSheet(workspace: ws)
            }
        }
    }

    private var addTaskPresented: Binding<Bool> {
        Binding(
            get: { store.addTaskWorkspaceID != nil },
            set: { if !$0 { store.addTaskWorkspaceID = nil } }
        )
    }

    private var newSessionPresented: Binding<Bool> {
        Binding(
            get: { store.newSessionWorkspaceID != nil },
            set: { if !$0 { store.newSessionWorkspaceID = nil } }
        )
    }
}

/// Detail pane for one workspace — grid overview or damson-style tabs, plus toolbar
/// controls (view-mode toggle + Add Task). Background tracks the selected theme.
struct WorkspaceDetailView: View {
    @EnvironmentObject var store: WorkspaceStore
    @ObservedObject var workspace: Workspace

    var body: some View {
        Group {
            switch store.detailMode {
            case .grid: AgentGridView(controller: workspace.controller)
            case .tabs: AgentTabsView(controller: workspace.controller)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(store.theme.swiftBackground)
        .navigationTitle(workspace.name)
        .navigationSubtitle(workspace.repo.path)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $store.detailMode) {
                    Image(systemName: "square.grid.2x2").tag(WorkspaceStore.DetailMode.grid)
                    Image(systemName: "rectangle.stack").tag(WorkspaceStore.DetailMode.tabs)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Grid overview / tabbed view")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.addTaskWorkspaceID = workspace.id
                } label: {
                    Label("Add Task", systemImage: "plus")
                }
            }
        }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var store: WorkspaceStore
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("No workspace open")
                .font(.title3)
            Text("Open a git repository to start orchestrating agents.")
                .foregroundStyle(.secondary)
            Button("Open Workspace…") { store.addWorkspaceViaPanel() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(store.theme.swiftBackground)
    }
}
