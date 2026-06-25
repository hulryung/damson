import SwiftUI
import DamsonOrchestrator

/// Compose and enqueue a task for a workspace. A worktree is created and the prompt is
/// delivered to the agent once it becomes idle.
struct AddTaskSheet: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var prompt = ""
    @State private var engineID = AgentEngineRegistry.all.first?.id ?? "claude-code"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Agent Task")
                .font(.headline)

            TextField("Title (e.g. Fix flaky parser test)", text: $title)
                .textFieldStyle(.roundedBorder)

            Picker("Engine", selection: $engineID) {
                ForEach(AgentEngineRegistry.all, id: \.id) { engine in
                    Text(engine.displayName).tag(engine.id)
                }
            }
            .pickerStyle(.menu)

            Text("Prompt")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextEditor(text: $prompt)
                .font(.system(.body, design: .monospaced))
                .frame(height: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor))
                )

            HStack {
                Text(workspace.repo.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func start() {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }
        let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(trimmedPrompt.prefix(40))
            : title
        workspace.controller.enqueue(AgentTask(
            title: finalTitle,
            prompt: trimmedPrompt,
            engineID: engineID,
            baseRepoPath: workspace.repo.path
        ))
        dismiss()
    }
}
