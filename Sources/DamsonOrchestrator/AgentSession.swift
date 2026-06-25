import Foundation
import Combine
import DamsonTerminal
import DamsonControl

/// Wraps one `DamsonSession` running a CLI agent, and drives a `ReadinessDetector` from
/// the live grid. This is the bridge between the terminal engine and the orchestrator:
/// it reads the screen into `ReadinessSnapshot`s and exposes a single `@Published state`.
@MainActor
public final class AgentSession: ObservableObject, Identifiable {
    public let id = UUID()
    public let engine: AgentEngine
    public let damsonSession: DamsonSession
    public let worktree: Worktree?
    public private(set) var task: AgentTask?

    @Published public private(set) var state: AgentRuntimeState = .starting
    /// Whether the task prompt has been delivered. The prompt is sent exactly once (on the
    /// first idle after spawn) — without this, every return-to-idle after a turn would
    /// re-type the prompt.
    public private(set) var hasDeliveredInitialPrompt = false

    private let detector: ReadinessDetector
    private var cancellables = Set<AnyCancellable>()
    private var tick: Timer?

    // Timing inputs for the detector.
    private let spawnTime = Date()
    private var lastDataTime = Date()
    private var lastSyncFrameTime: Date?
    private var prevInSyncOutput = false
    private var promptMarkBaseline = 0
    private var taskDeliveredAt: Date?
    private var capturedExitCode: Int32?
    /// Guards `autoResponseKeys` so a benign gate is auto-cleared at most once per entry.
    private var autoRespondedThisApproval = false

    /// Called on every state change (the controller hooks scheduling here).
    public var onStateChange: ((AgentRuntimeState) -> Void)?

    public init(engine: AgentEngine, session: DamsonSession, worktree: Worktree?, task: AgentTask?) {
        self.engine = engine
        self.damsonSession = session
        self.worktree = worktree
        self.task = task
        self.detector = ReadinessDetector(engine: engine)

        session.gridChanged
            .sink { [weak self] in self?.onGridChanged() }
            .store(in: &cancellables)
        session.onExit = { [weak self] code in
            Task { @MainActor in
                self?.capturedExitCode = code
                self?.evaluate()
            }
        }

        // Quiescence/cadence can only be detected by a timer (gridChanged won't fire when
        // output stops). 4 Hz is cheap and well below the spinner's ~1 Hz cadence.
        let t = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        t.tolerance = 0.1
        self.tick = t
    }

    deinit { tick?.invalidate() }

    // MARK: - Driving input

    /// Deliver the task prompt and submit it. Uses bracketed paste when the agent enabled
    /// it, so embedded newlines don't each submit a partial line.
    public func deliverPrompt(_ prompt: String) {
        let session = damsonSession
        if session.bracketedPasteEnabled {
            session.write(Data([0x1B] + Array("[200~".utf8)))
            session.write(Data(prompt.utf8))
            session.write(Data([0x1B] + Array("[201~".utf8)))
        } else {
            session.write(Data(prompt.utf8))
        }
        session.write(Data(keyNameToBytes("enter") ?? [0x0D]))
        taskDeliveredAt = Date()
        hasDeliveredInitialPrompt = true
        detector.noteTaskDelivered()
        setState(detector.state)
    }

    /// Send a single named key (e.g. "1", "enter", "ctrl-c") — used for approval responses.
    public func sendKey(_ name: String) {
        if let bytes = keyNameToBytes(name) {
            damsonSession.write(Data(bytes))
        } else if name.count == 1 {
            damsonSession.write(Data(name.utf8))
        }
    }

    public func interrupt() { damsonSession.write(Data([0x03])) } // Ctrl-C

    /// Raw text injection (no trailing Enter) — used by the control CLI's `send-text`.
    public func sendText(_ text: String) {
        if damsonSession.bracketedPasteEnabled {
            damsonSession.write(Data([0x1B] + Array("[200~".utf8)))
            damsonSession.write(Data(text.utf8))
            damsonSession.write(Data([0x1B] + Array("[201~".utf8)))
        } else {
            damsonSession.write(Data(text.utf8))
        }
    }

    /// Short, human-friendly id used by the control CLI to address this agent.
    public var shortID: String { String(id.uuidString.prefix(8)).lowercased() }

    /// The visible grid as plain text (one line per row, trailing blanks trimmed) — the
    /// CLI's `agent-output`, so an external AI can read what the agent is showing.
    public func gridText() -> String {
        let grid = damsonSession.grid
        var lines: [String] = []
        for r in 0..<grid.rows {
            var s = String(grid.row(r).map { $0.char })
            while let last = s.last, last == " " { s.removeLast() }
            lines.append(s)
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    public func terminate() {
        tick?.invalidate()
        tick = nil
        damsonSession.terminate()
    }

    // MARK: - Snapshot + evaluation

    private func onGridChanged() {
        lastDataTime = Date()
        // Detect a synchronized-output frame edge (false→true) for cadence tracking.
        let now = damsonSession.grid.inSyncOutputMode
        if now && !prevInSyncOutput { lastSyncFrameTime = Date() }
        prevInSyncOutput = now
        evaluate()
    }

    private func evaluate() {
        let snap = makeSnapshot()
        let newState = detector.update(snap)
        setState(newState)

        if newState == .awaitingApproval {
            // Auto-clear only engine-approved benign gates (e.g. the startup trust prompt).
            // Wait for the prompt to settle (quiescent) before responding, and do it once.
            if !autoRespondedThisApproval, snap.timeSinceLastData > 0.3,
               let keys = engine.autoResponseKeys(snap) {
                autoRespondedThisApproval = true
                for key in keys { sendKey(key) }
            }
        } else {
            autoRespondedThisApproval = false
        }
    }

    private func setState(_ s: AgentRuntimeState) {
        guard s != state else { return }
        state = s
        onStateChange?(s)
    }

    private func makeSnapshot() -> ReadinessSnapshot {
        let grid = damsonSession.grid
        var lines: [String] = []
        lines.reserveCapacity(grid.rows)
        for r in 0..<grid.rows {
            let chars = grid.row(r).map { $0.char }
            var s = String(chars)
            while let last = s.last, last == " " { s.removeLast() }
            lines.append(s)
        }
        let now = Date()
        let sinceSync = lastSyncFrameTime.map { now.timeIntervalSince($0) } ?? .infinity
        return ReadinessSnapshot(
            lines: lines,
            cursorRow: grid.cursorRow,
            cursorCol: grid.cursorCol,
            cols: grid.cols,
            rows: grid.rows,
            isAltScreen: grid.isAltScreenActive,
            timeSinceLastData: now.timeIntervalSince(lastDataTime),
            timeSinceLastSyncFrame: sinceSync,
            timeSinceSpawn: now.timeIntervalSince(spawnTime),
            processExited: damsonSession.processExited,
            exitCode: capturedExitCode,
            isRunningForegroundJob: damsonSession.hasRunningForegroundJob,
            newPromptMarkSinceTaskStart: false
        )
    }
}
