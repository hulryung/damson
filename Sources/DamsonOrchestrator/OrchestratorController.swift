import Foundation
import Combine
import DamsonTerminal

/// The orchestrator brain: owns the task queue and the live agent sessions, creates a
/// worktree per task, spawns an agent, and dispatches work as agents become idle.
/// Analogous to `TmuxIntegrationController` — it owns `DamsonSession`s; the app layer
/// observes `agents`/`queue` and injects each agent's `damsonSession` as a tab.
@MainActor
public final class OrchestratorController: ObservableObject {
    public let runID = UUID()
    @Published public private(set) var agents: [AgentSession] = []
    public let queue = TaskQueue()
    public var maxConcurrency: Int = 3

    /// Base repo all tasks fork from, and the commit pinned at run start.
    public let baseRepo: URL
    public private(set) var baseRef: String = "HEAD"

    private let worktrees: WorktreeManager
    private let worktreesRoot: URL
    /// Template config new agents are built from; per-agent argv/cwd/env are overlaid on a
    /// copy. Mutable so the app can re-theme (see `applyTheme`).
    public var configTemplate: DamsonConfig

    /// App hooks: add/remove the agent's terminal tab, and surface state for the dashboard.
    public var onAgentSpawned: ((AgentSession) -> Void)?
    public var onAgentRetired: ((AgentSession) -> Void)?
    public var onError: ((String) -> Void)?

    public init(baseRepo: URL, worktreesRoot: URL, configTemplate: DamsonConfig) {
        self.baseRepo = baseRepo
        self.worktreesRoot = worktreesRoot
        self.worktrees = WorktreeManager(root: worktreesRoot)
        self.configTemplate = configTemplate
    }

    /// Validate the repo and pin the base commit. Call once before enqueuing.
    public func start() throws {
        try worktrees.validateReady(baseRepo)
        // If worktrees live inside the repo, hide that dir from the main checkout's
        // `git status` via local exclude (no commit, no change to tracked .gitignore).
        if let rel = relativePathInsideRepo(worktreesRoot) {
            let topComponent = rel.split(separator: "/").first.map(String.init) ?? rel
            worktrees.ensureExcluded("\(topComponent)/", in: baseRepo)
        }
        worktrees.prune(base: baseRepo)
        baseRef = try worktrees.resolveRef("HEAD", in: baseRepo)
    }

    /// Relative path of `url` under `baseRepo`, or nil if it's outside the repo.
    private func relativePathInsideRepo(_ url: URL) -> String? {
        let repoPath = baseRepo.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        guard target.hasPrefix(repoPath + "/") else { return nil }
        return String(target.dropFirst(repoPath.count + 1))
    }

    public func enqueue(_ task: AgentTask) {
        queue.enqueue(task)
        schedule()
    }

    /// Spawn an interactive agent with NO upfront mission — a fresh session in its own
    /// worktree that the user drives by typing directly (Cmd-T "new session"). The empty
    /// prompt means the controller never auto-delivers anything.
    public func newInteractiveAgent(engineID: String) {
        guard let engine = AgentEngineRegistry.engine(id: engineID) else { return }
        enqueue(AgentTask(title: engine.displayName, prompt: "",
                          engineID: engineID, baseRepoPath: baseRepo.path))
    }

    public func setMaxConcurrency(_ n: Int) {
        maxConcurrency = max(1, n)
        schedule()
    }

    /// Apply a color theme to future agents and live-update existing ones.
    public func applyTheme(_ theme: DamsonTheme) {
        configTemplate.theme = theme
        for agent in agents {
            var cfg = agent.damsonSession.config
            cfg.theme = theme
            agent.damsonSession.updateConfig(cfg)
        }
    }

    // MARK: - Scheduling

    /// Number of agents occupying a concurrency slot (non-terminal).
    private var activeAgentCount: Int {
        agents.filter { !$0.state.isTerminal }.count
    }

    private func schedule() {
        while queue.hasPending, activeAgentCount < maxConcurrency {
            guard let task = queue.dequeue() else { break }
            do {
                try spawnAgent(for: task)
            } catch {
                onError?("failed to start task \"\(task.title)\": \(error)")
                queue.finish(task.id, status: .failed)
            }
        }
    }

    private func spawnAgent(for task: AgentTask) throws {
        guard let engine = AgentEngineRegistry.engine(id: task.engineID) else {
            throw GitError("unknown engine: \(task.engineID)")
        }
        let branch = "orchestrator/\(runID.uuidString.prefix(8))/\(task.slug)"
        let wt = try worktrees.create(base: baseRepo, branch: branch, from: baseRef)

        var config = configTemplate
        config.cwd = wt.path.path
        config.argv = launchArgv(engine: engine, task: task, worktree: wt.path)

        let session = DamsonSession(config: config)
        let agent = AgentSession(engine: engine, session: session, worktree: wt, task: task)
        agent.onStateChange = { [weak self, weak agent] state in
            guard let self, let agent else { return }
            self.agentStateChanged(agent, state: state)
        }
        agents.append(agent)
        onAgentSpawned?(agent)
    }

    /// Wrap the engine's argv in a login shell (for PATH) unless it already is one.
    private func launchArgv(engine: AgentEngine, task: AgentTask, worktree: URL) -> [String] {
        let inner = engine.launchArgv(task: task, worktree: worktree)
        if engine.launchesOwnShell { return inner }
        let shell = DamsonConfig.loginShellPath()
        let cmd = "exec " + inner.map(Self.shellQuote).joined(separator: " ")
        return [shell, "-l", "-c", cmd]
    }

    private static func shellQuote(_ s: String) -> String {
        if s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=@".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Agent state reactions

    private func agentStateChanged(_ agent: AgentSession, state: AgentRuntimeState) {
        switch state {
        case .idle:
            // Deliver the task prompt exactly once, on the first idle after spawn. Skip
            // interactive agents (empty prompt). Claude Code returns to idle after every
            // turn, so the once-guard stops the prompt being re-typed on each completion.
            if let task = agent.task,
               !task.prompt.isEmpty,
               agent.engine.promptDelivery == .typeWhenIdle,
               !agent.hasDeliveredInitialPrompt {
                agent.deliverPrompt(task.prompt)
            }
        case .finished, .errored:
            finalize(agent, success: state == .finished(0))
        default:
            break
        }
    }

    private func finalize(_ agent: AgentSession, success: Bool) {
        if let task = agent.task {
            queue.finish(task.id, status: success ? .completed : .failed)
        }
        // Worktree retention: keep it (dirty or for inspection) by default — a non-force
        // remove preserves uncommitted work.
        if let wt = agent.worktree {
            _ = try? worktrees.remove(wt, force: false)
        }
        schedule() // a slot freed up
    }

    /// Tear down everything (window closed / app quit). Tasks still running become interrupted.
    public func shutdown(removeWorktrees: Bool = false) {
        for agent in agents {
            if let task = agent.task, !agent.state.isTerminal {
                queue.finish(task.id, status: .interrupted)
            }
            agent.terminate()
            if removeWorktrees, let wt = agent.worktree {
                _ = try? worktrees.remove(wt, force: true)
            }
            onAgentRetired?(agent)
        }
        agents.removeAll()
    }
}
