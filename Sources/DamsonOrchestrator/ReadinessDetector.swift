import Foundation

/// Infers an `AgentRuntimeState` from a stream of `ReadinessSnapshot`s.
///
/// Layered strategy (see the plan, §"가장 큰 리스크"):
///   L0 process exit  — authoritative terminal state.
///   L1/L2 (generic)  — foreground-job transition + OSC 133 prompt marks, for non-TUI
///                       engines that return to a shell prompt between commands.
///   L3/L4 (engine)   — for long-running TUIs, the engine's `classify` reads the screen
///                       (quiescence + sync-frame cadence + content fingerprints).
///
/// Fusion rules layered on top of the raw classification:
///   • Approval beats idle (never dispatch into an approval prompt).
///   • Idle is debounced (N consecutive confirmations) to survive momentary repaint gaps.
///   • A spawn floor prevents declaring idle during the splash / first paint.
///   • After a task is delivered we hold `.working` until we have actually observed
///     working — this closes the race where the just-typed prompt still looks idle.
public final class ReadinessDetector {
    public struct Config: Sendable {
        /// Consecutive idle observations required before declaring `.idle`.
        public var idleDebounce: Int = 2
        /// No `.idle` within this long after spawn (avoids catching the splash screen).
        public var spawnFloor: TimeInterval = 1.5
        /// After delivery, if we never see `.working`, accept idle once output has been
        /// quiescent for this long (handles instant/no-op turns).
        public var deliveryGiveUp: TimeInterval = 5.0
        public init() {}
    }

    private let engine: AgentEngine
    private let config: Config

    public private(set) var state: AgentRuntimeState = .starting
    /// The most recent transition's justification, for logging/debugging drift.
    public private(set) var lastEvidence: String = "init"

    private var idleConfirmations = 0
    /// A task has been delivered and we're awaiting its turn.
    private var taskActive = false
    /// We've observed `.working` since the last delivery (closes the just-typed race).
    private var sawWorkingSinceDelivery = false

    public init(engine: AgentEngine, config: Config = Config()) {
        self.engine = engine
        self.config = config
    }

    /// Call right after delivering a task prompt. Optimistically enters `.working` so the
    /// scheduler won't immediately re-dispatch, and arms the post-delivery idle guard.
    public func noteTaskDelivered() {
        state = .working
        taskActive = true
        sawWorkingSinceDelivery = false
        idleConfirmations = 0
        lastEvidence = "task delivered"
    }

    /// Feed a snapshot; returns the (possibly updated) state.
    @discardableResult
    public func update(_ snap: ReadinessSnapshot) -> AgentRuntimeState {
        // L0 — process exit is authoritative.
        if snap.processExited {
            let code = snap.exitCode ?? 0
            state = code == 0 ? .finished(code) : .errored("exited with code \(code)")
            taskActive = false
            lastEvidence = "process exited (\(code))"
            return state
        }

        // Raw classification: engine-specific verdict, else generic process signals.
        let raw = engine.classify(snap) ?? genericClassify(snap)

        guard let candidate = raw else {
            // Uncertain. Stay put — but never linger in `.starting` forever once the
            // process is clearly alive and quiet.
            if state == .starting, snap.timeSinceSpawn >= config.spawnFloor,
               snap.timeSinceLastData > 0.6 {
                return transition(to: .idle, evidence: "starting→idle (quiet, no classifier verdict)")
            }
            return state
        }

        switch candidate {
        case .working:
            sawWorkingSinceDelivery = true
            idleConfirmations = 0
            return transition(to: .working, evidence: "working signal")

        case .awaitingApproval:
            idleConfirmations = 0
            return transition(to: .awaitingApproval, evidence: "approval prompt")

        case .awaitingInput:
            idleConfirmations = 0
            return transition(to: .awaitingInput, evidence: "input prompt")

        case .idle:
            return considerIdle(snap)

        case .starting, .finished, .errored:
            // Engines don't emit these; ignore.
            return state
        }
    }

    private func considerIdle(_ snap: ReadinessSnapshot) -> AgentRuntimeState {
        // Spawn floor — don't mistake the splash for readiness.
        if snap.timeSinceSpawn < config.spawnFloor {
            return state
        }
        // Post-delivery guard: a freshly typed prompt still looks idle. Hold `.working`
        // until we've seen real work, unless output has been quiet long enough that the
        // turn was plausibly instant/no-op.
        if taskActive, !sawWorkingSinceDelivery,
           snap.timeSinceLastData < config.deliveryGiveUp {
            return state
        }
        // Debounce.
        idleConfirmations += 1
        guard idleConfirmations >= config.idleDebounce else { return state }
        taskActive = false
        return transition(to: .idle, evidence: "idle (debounced ×\(idleConfirmations))")
    }

    /// Generic readiness for non-TUI engines: foreground-job + prompt marks.
    private func genericClassify(_ snap: ReadinessSnapshot) -> AgentRuntimeState? {
        if snap.isRunningForegroundJob {
            return .working
        }
        // Not running a foreground job → back at the shell prompt.
        if snap.newPromptMarkSinceTaskStart || snap.timeSinceLastData > 0.3 {
            return .idle
        }
        return .idle
    }

    private func transition(to newState: AgentRuntimeState, evidence: String) -> AgentRuntimeState {
        if newState != state || lastEvidence != evidence {
            lastEvidence = evidence
        }
        state = newState
        return state
    }
}
