import SwiftUI
import DamsonOrchestrator

/// Engine picker for Cmd-T / Cmd-D — starts a fresh agent session with NO upfront mission.
/// A worktree is created and the engine launched; the user types the mission directly in
/// the terminal. (For a pre-defined mission, use the toolbar "+" / orchard-cli add-task.)
struct NewSessionSheet: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("New Session")
                .font(.headline)
            Text("Pick an engine — a fresh worktree opens and you type the mission in the terminal.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                ForEach(AgentEngineRegistry.all, id: \.id) { engine in
                    Button {
                        workspace.controller.newInteractiveAgent(engineID: engine.id)
                        dismiss()
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: engine.id == "claude-code" ? "sparkles" : "terminal")
                                .font(.system(size: 22))
                            Text(engine.displayName)
                                .font(.callout)
                        }
                        .frame(width: 130, height: 80)
                    }
                    .buttonStyle(.bordered)
                }
            }

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .frame(width: 360)
    }
}
