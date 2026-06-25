import Foundation
import DamsonOrchestrator
import OrchardControl

/// Maps an `OrchardCommand` (from orchard-cli) onto the live `WorkspaceStore`. Runs on the
/// main actor — the control server hops here from its worker thread. This is the surface an
/// external AI uses to drive Orchard: open workspaces, enqueue tasks, read/drive agents.
@MainActor
extension WorkspaceStore {
    func handle(_ cmd: OrchardCommand) -> OrchardResponse {
        switch cmd.cmd {
        case "list-workspaces":
            return OrchardResponse(ok: true, workspaces: workspaces.enumerated().map {
                WorkspaceInfo(index: $0.offset, name: $0.element.name,
                              path: $0.element.repo.path,
                              agentCount: $0.element.controller.agents.count)
            })

        case "add-workspace":
            guard let path = cmd.path else { return .error("path required") }
            addWorkspace(repo: URL(fileURLWithPath: path), silent: true)
            guard workspaces.contains(where: { $0.repo.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path }) else {
                return .error("could not open \(path) (not a git repo?)")
            }
            return .ok("opened \(path)")

        case "list-agents":
            return OrchardResponse(ok: true, agents: agentInfos(workspaceFilter: cmd.workspace))

        case "set-concurrency":
            guard let wi = cmd.workspace, workspaces.indices.contains(wi) else {
                return .error("invalid workspace index")
            }
            guard let count = cmd.count, count >= 1 else { return .error("count >= 1 required") }
            workspaces[wi].controller.setMaxConcurrency(count)
            return .ok("maxConcurrency = \(count) for \(workspaces[wi].name)")

        case "add-task":
            guard let wi = cmd.workspace, workspaces.indices.contains(wi) else {
                return .error("invalid workspace index (see list-workspaces)")
            }
            guard let prompt = cmd.prompt, !prompt.isEmpty else { return .error("prompt required") }
            let ws = workspaces[wi]
            let engine = cmd.engine ?? "claude-code"
            guard AgentEngineRegistry.engine(id: engine) != nil else {
                return .error("unknown engine '\(engine)'")
            }
            let title = cmd.title ?? String(prompt.prefix(40))
            ws.controller.enqueue(AgentTask(title: title, prompt: prompt,
                                            engineID: engine, baseRepoPath: ws.repo.path))
            return .ok("enqueued '\(title)' in \(ws.name)")

        case "show-new-session":
            // Trigger exactly what Cmd-T does (requestNewSession → engine-picker sheet),
            // so the sheet can be verified on screen without synthesizing a keystroke.
            if selectedWorkspaceID == nil { selectedWorkspaceID = workspaces.first?.id }
            requestNewSession(mode: .tabs)
            return .ok("opened new-session picker")

        case "new-session":
            guard let wi = cmd.workspace, workspaces.indices.contains(wi) else {
                return .error("invalid workspace index")
            }
            let engine = cmd.engine ?? "claude-code"
            guard AgentEngineRegistry.engine(id: engine) != nil else {
                return .error("unknown engine '\(engine)'")
            }
            workspaces[wi].controller.newInteractiveAgent(engineID: engine)
            return .ok("opened \(engine) session in \(workspaces[wi].name)")

        case "agent-output":
            guard let agent = findAgent(cmd.agent) else { return .error("agent not found") }
            return OrchardResponse(ok: true, output: agent.gridText())

        case "view":
            switch (cmd.text ?? "").lowercased() {
            case "grid": detailMode = .grid
            case "tabs": detailMode = .tabs
            default: return .error("view requires grid|tabs")
            }
            return .ok("view = \(cmd.text ?? "")")

        case "focus":
            // Same effect as clicking the agent in the sidebar: open it large in the tabbed view.
            guard let agent = findAgent(cmd.agent) else { return .error("agent not found") }
            for (wi, ws) in workspaces.enumerated() where ws.controller.agents.contains(where: { $0.id == agent.id }) {
                selectedWorkspaceID = ws.id
                _ = wi
            }
            focus(agent.id)
            return .ok("focused \(agent.shortID)")

        case "send-text":
            guard let agent = findAgent(cmd.agent) else { return .error("agent not found") }
            guard let text = cmd.text else { return .error("text required") }
            agent.sendText(text)
            return .ok()

        case "send-key":
            guard let agent = findAgent(cmd.agent) else { return .error("agent not found") }
            guard let keys = cmd.keys, !keys.isEmpty else { return .error("keys required") }
            for key in keys { agent.sendKey(key) }
            return .ok()

        case "interrupt":
            guard let agent = findAgent(cmd.agent) else { return .error("agent not found") }
            agent.interrupt()
            return .ok()

        default:
            return .error("unknown command: \(cmd.cmd)")
        }
    }

    private func agentInfos(workspaceFilter: Int?) -> [AgentInfo] {
        var out: [AgentInfo] = []
        for (wi, ws) in workspaces.enumerated() {
            if let filter = workspaceFilter, filter != wi { continue }
            for agent in ws.controller.agents {
                out.append(AgentInfo(
                    id: agent.shortID, workspace: wi,
                    title: agent.task?.title ?? "agent",
                    engine: agent.engine.id, state: agent.state.cliToken,
                    branch: agent.worktree?.branch))
            }
        }
        return out
    }

    private func findAgent(_ shortID: String?) -> AgentSession? {
        guard let sid = shortID?.lowercased() else { return nil }
        for ws in workspaces {
            for agent in ws.controller.agents where agent.shortID == sid { return agent }
        }
        return nil
    }
}
