import DamsonControl
import Foundation

/// Holds a `watch-agents` subscription and keeps an `AgentBoard` current, reconnecting when
/// the connection ends.
///
/// Reconnection is the coordinator's job — damson does not retry on its behalf. And silence
/// is not a symptom: the stream is edge-triggered, so an idle machine produces nothing but a
/// heartbeat every 20s. Only a *closed* connection means anything is wrong.
public final class AgentWatcher {
    /// Opens one subscription and pumps lines into `onLine` until it ends. Injected so the
    /// loop can be tested without a socket — the interesting behaviour is what happens
    /// across a drop, which is awkward to provoke against a real server.
    /// `onOpen` fires once the subscription is live and the server's snapshot is about to
    /// arrive. It is separate from the first line because a subscription can legitimately
    /// open with nothing running, and the board still has to be cleared in that case.
    public typealias Stream = (_ onOpen: @escaping () -> Void,
                               _ onLine: @escaping (AgentEventLine) -> Void) -> Result<Void, CrewError>

    private let stream: Stream
    private let taskFor: (String) -> String?
    private let onChange: (AgentBoard.Change, AgentBoard) -> Void
    /// How long to wait before reconnecting, given how many attempts have failed in a row.
    private let backoff: (Int) -> TimeInterval
    private let sleeper: (TimeInterval) -> Void

    private let lock = NSLock()
    private var board = AgentBoard()
    private var stopped = false

    /// Delivery runs here, off the reading thread. damson gives each subscriber a bounded
    /// mailbox and drops a reader that falls behind, so a notification, a shell-out or a
    /// slow render must never happen between two reads.
    private let delivery = DispatchQueue(label: "damson-crew.delivery")

    /// How long an agent may stay in a working state before it is reported as quiet.
    /// 0 disables it.
    private let stallAfter: TimeInterval

    public init(stream: @escaping Stream,
                taskFor: @escaping (String) -> String? = { _ in nil },
                stallAfter: TimeInterval = 0,
                backoff: @escaping (Int) -> TimeInterval = { min(pow(2.0, Double($0)), 30) },
                sleeper: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                onChange: @escaping (AgentBoard.Change, AgentBoard) -> Void) {
        self.stream = stream
        self.taskFor = taskFor
        self.stallAfter = stallAfter
        self.backoff = backoff
        self.sleeper = sleeper
        self.onChange = onChange
    }

    public var snapshot: AgentBoard {
        lock.lock(); defer { lock.unlock() }
        return board
    }

    public func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    /// Subscribe, and keep subscribing. Returns when `stop()` has been called, or after
    /// `maxAttempts` consecutive failures — a coordinator run should not spin forever
    /// against a damson that has quit.
    public func run(maxAttempts: Int = Int.max) {
        var consecutiveFailures = 0
        while true {
            lock.lock(); let done = stopped; lock.unlock()
            if done { return }

            // The board is cleared when a new subscription actually OPENS, not before
            // connecting. Every subscription starts with its own snapshot of the present, so
            // keeping old rows across one would leave agents on the board that have since
            // gone — but clearing on the way *in* would also blank the last known picture
            // for the whole time damson is unreachable, and leave it blank if it never
            // comes back.
            let outcome = stream(
                { [weak self] in
                    guard let self else { return }
                    self.lock.lock(); self.board.reset(); self.lock.unlock()
                },
                { [weak self] line in self?.ingest(line) })
            lock.lock(); board.snapshotComplete(); let done2 = stopped; lock.unlock()
            if done2 { return }

            switch outcome {
            case .success:      consecutiveFailures = 0   // clean close: the server went away
            case .failure:      consecutiveFailures += 1
            }
            if consecutiveFailures >= maxAttempts { return }
            sleeper(backoff(consecutiveFailures))
        }
    }

    /// One line, on the reading thread. Parse and fold it in; hand the result off elsewhere.
    ///
    /// A `heartbeat` carries no state, but it is the only thing that arrives while agents are
    /// quiet — the stream is edge-triggered — so it doubles as the clock that notices one
    /// that has been working too long.
    private func ingest(_ line: AgentEventLine) {
        lock.lock()
        var changes: [AgentBoard.Change] = []
        if let change = board.apply(line, task: taskFor) { changes.append(change) }
        if stallAfter > 0 { changes += board.tick(stallAfter: stallAfter) }
        let current = board
        lock.unlock()
        guard !changes.isEmpty else { return }
        delivery.async { [onChange] in for c in changes { onChange(c, current) } }
    }
}

public extension AgentWatcher {
    /// The real subscription, over damson's control socket.
    ///
    /// `resolve` is called on **every** attempt rather than once. damson's socket path
    /// carries its pid, so an app restart — which is also an app update — moves it. A
    /// watcher that cached the path would reconnect forever to a socket that no longer
    /// exists and silently stop reporting, which is the worst possible failure for the one
    /// thing here that tells a human they are being waited on.
    static func socketStream(resolve: @escaping () -> Result<String, CrewError>) -> Stream {
        { onOpen, onLine in
            guard case .success(let socketPath) = resolve() else {
                return .failure(CrewError("no damson instance to watch"))
            }
            let json = encodeCommand(.watchAgents, target: .active)
            let result = streamCommand(socketPath: socketPath, commandJSON: json,
                                       onOpen: onOpen) { text in
                // A line this build cannot parse is skipped, not fatal: losing one event is
                // recoverable, dropping the subscription over it is not.
                guard let data = text.data(using: .utf8),
                      let line = try? JSONDecoder().decode(AgentEventLine.self, from: data)
                else { return }
                onLine(line)
            }
            switch result {
            case .success:        return .success(())
            case .failure(let e): return .failure(CrewError(e.description))
            }
        }
    }
}
