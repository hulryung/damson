import SwiftUI
import DamsonTerminal
import DamsonOrchestrator

/// Tiling grid of agent terminals that fills the whole window — rows/cols are computed
/// from the agent count and each tile stretches to share the available space evenly.
struct AgentGridView: View {
    @EnvironmentObject var store: WorkspaceStore
    @ObservedObject var controller: OrchestratorController

    private let gap: CGFloat = 10

    var body: some View {
        if controller.agents.isEmpty {
            EmptyAgentsView()
        } else {
            let agents = controller.agents
            let n = agents.count
            let cols = columnCount(for: n)
            let rows = Int(ceil(Double(n) / Double(cols)))
            VStack(spacing: gap) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(0..<cols, id: \.self) { c in
                            let idx = r * cols + c
                            if idx < n {
                                AgentTileView(agent: agents[idx]) { store.focus(agents[idx].id) }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                }
            }
            .padding(gap)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Near-square tiling, biased slightly wider since terminals are landscape.
    private func columnCount(for n: Int) -> Int {
        guard n > 1 else { return 1 }
        return Int(ceil(sqrt(Double(n))))
    }
}

struct EmptyAgentsView: View {
    @EnvironmentObject var store: WorkspaceStore
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "circle.grid.3x3")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(store.theme.swiftForeground.opacity(0.5))
            Text("No agents yet")
                .font(.title3)
                .foregroundStyle(store.theme.swiftForeground.opacity(0.85))
            Text("Add a task to spawn an agent in its own worktree.")
                .foregroundStyle(store.theme.swiftForeground.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One agent: status header + live terminal surface + quick actions (maximize / approve / interrupt).
struct AgentTileView: View {
    @EnvironmentObject var store: WorkspaceStore
    @ObservedObject var agent: AgentSession
    @StateObject private var surfaceRef = SurfaceRef()
    var onMaximize: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            AgentTerminalView(session: agent.damsonSession, ref: surfaceRef)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(store.theme.swiftBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(agent.state.color.opacity(0.55), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(agent.state.color).frame(width: 9, height: 9)
            Text(agent.task?.title ?? "agent")
                .fontWeight(.medium)
                .lineLimit(1)
            Text(agent.state.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            actions
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(store.theme.swiftElevated)
        .foregroundStyle(store.theme.swiftForeground)
    }

    @ViewBuilder
    private var actions: some View {
        if agent.state == .awaitingApproval {
            Button("Approve") { agent.sendKey("enter") }.controlSize(.small)
            Button("Deny") { agent.sendKey("escape") }.controlSize(.small)
        }
        Button { surfaceRef.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
            .help("Zoom out this terminal").controlSize(.small).buttonStyle(.borderless)
        Button { surfaceRef.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
            .help("Zoom in this terminal").controlSize(.small).buttonStyle(.borderless)
        Button { agent.interrupt() } label: { Image(systemName: "stop.circle") }
            .help("Interrupt (Ctrl-C)").controlSize(.small).buttonStyle(.borderless)
        Button(action: onMaximize) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
            .help("Maximize (open in tabbed view)").controlSize(.small).buttonStyle(.borderless)
    }
}
