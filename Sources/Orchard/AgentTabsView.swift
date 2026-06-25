import SwiftUI
import DamsonTerminal
import DamsonOrchestrator

/// damson-style tabbed view: a tab bar of agents plus one large terminal for the focused
/// agent. Entered by maximizing a grid tile or via the toolbar's view toggle.
struct AgentTabsView: View {
    @EnvironmentObject var store: WorkspaceStore
    @ObservedObject var controller: OrchestratorController

    var body: some View {
        if controller.agents.isEmpty {
            EmptyAgentsView()
        } else {
            VStack(spacing: 0) {
                AgentTabBar(controller: controller)
                Divider()
                if let agent = currentAgent {
                    DamsonTerminalView(session: agent.damsonSession, isActive: true)
                        .id(agent.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color.clear
                }
            }
        }
    }

    private var currentAgent: AgentSession? {
        controller.agents.first { $0.id == store.focusedAgentID } ?? controller.agents.first
    }
}

/// Horizontal, scrollable tab strip — one chip per agent with a live status dot.
struct AgentTabBar: View {
    @EnvironmentObject var store: WorkspaceStore
    @ObservedObject var controller: OrchestratorController

    var body: some View {
        HStack(spacing: 6) {
            // Always-visible way back to the grid overview.
            Button {
                store.detailMode = .grid
            } label: {
                Label("Grid", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .help("Back to grid overview")
            .padding(.leading, 8)

            Divider().frame(height: 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(controller.agents) { agent in
                        AgentTabChip(
                            agent: agent,
                            isSelected: effectiveSelection == agent.id,
                            select: { store.focusedAgentID = agent.id }
                        )
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .padding(.trailing, 8)
        .background(store.theme.swiftElevated)
        .foregroundStyle(store.theme.swiftForeground)
    }

    private var effectiveSelection: UUID? {
        if let id = store.focusedAgentID, controller.agents.contains(where: { $0.id == id }) { return id }
        return controller.agents.first?.id
    }
}

struct AgentTabChip: View {
    @EnvironmentObject var store: WorkspaceStore
    @ObservedObject var agent: AgentSession
    var isSelected: Bool
    var select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                Circle().fill(agent.state.color).frame(width: 7, height: 7)
                Text(agent.task?.title ?? "agent")
                    .lineLimit(1)
                    .font(.callout)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? store.theme.swiftBackground : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? agent.state.color.opacity(0.6) : .clear, lineWidth: 1)
            )
            .foregroundStyle(store.theme.swiftForeground.opacity(isSelected ? 1 : 0.7))
        }
        .buttonStyle(.plain)
    }
}
