import SwiftUI
import DamsonTerminal
import DamsonOrchestrator

struct SidebarView: View {
    @EnvironmentObject var store: WorkspaceStore

    var body: some View {
        List(selection: $store.selectedWorkspaceID) {
            Section("Workspaces") {
                ForEach(store.workspaces) { ws in
                    Label(ws.name, systemImage: "shippingbox")
                        .tag(ws.id)
                }
                if store.workspaces.isEmpty {
                    Text("No workspaces")
                        .foregroundStyle(.tertiary)
                        .font(.callout)
                }
            }

            if let ws = store.selectedWorkspace {
                WorkspaceSidebarSections(workspace: ws)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button {
                    store.addWorkspaceViaPanel()
                } label: {
                    Label("Workspace", systemImage: "plus")
                }
                if store.selectedWorkspace != nil {
                    Button {
                        store.requestAddTaskForSelected()
                    } label: {
                        Label("Task", systemImage: "plus.circle")
                    }
                }
                Spacer()
                Menu {
                    Picker("Theme", selection: $store.themeName) {
                        ForEach(DamsonTheme.presets, id: \.name) { theme in
                            Text(theme.name).tag(theme.name)
                        }
                    }
                } label: {
                    Image(systemName: "paintpalette")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Terminal color theme")
            }
            .padding(8)
            .background(.bar)
        }
    }
}

/// Agents + Queue sections for the selected workspace. Split into sub-views so each can
/// observe the controller/queue directly and refresh on change.
struct WorkspaceSidebarSections: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        AgentsSection(controller: workspace.controller)
        QueueSection(queue: workspace.controller.queue)
    }
}

struct AgentsSection: View {
    @ObservedObject var controller: OrchestratorController
    @EnvironmentObject var store: WorkspaceStore

    var body: some View {
        Section("Agents") {
            if controller.agents.isEmpty {
                Text("No active agents")
                    .foregroundStyle(.tertiary)
                    .font(.callout)
            }
            ForEach(controller.agents) { agent in
                AgentRow(agent: agent, isSelected: store.detailMode == .tabs && store.focusedAgentID == agent.id)
                    .contentShape(Rectangle())
                    // Click an agent → open it large in the tabbed view.
                    .onTapGesture { store.focus(agent.id) }
            }
        }
    }
}

struct AgentRow: View {
    @ObservedObject var agent: AgentSession
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(agent.state.color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.task?.title ?? "agent")
                    .lineLimit(1)
                Text(agent.state.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : .clear)
        )
    }
}

struct QueueSection: View {
    @ObservedObject var queue: TaskQueue

    var body: some View {
        if !queue.pending.isEmpty {
            Section("Queue") {
                ForEach(queue.pending) { task in
                    HStack(spacing: 8) {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text(task.title).lineLimit(1)
                    }
                }
            }
        }
    }
}
