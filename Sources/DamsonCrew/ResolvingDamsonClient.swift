import DamsonControl

/// Resolve on each request because restarting the app changes its PID-based socket path.
/// A request is sent once: retrying a mutation after a timeout could repeat its effects.
public struct ResolvingDamsonClient: DamsonClient {
    private let resolve: () -> Result<String, CrewError>
    private let transport: (String, ControlCommandKind, PaneTarget) -> Result<ControlResponse, CrewError>

    public init(resolve: @escaping () -> Result<String, CrewError>) {
        self.init(resolve: resolve) { path, kind, target in
            sendCommand(socketPath: path, commandJSON: encodeCommand(kind, target: target))
                .mapError { CrewError($0.description) }
        }
    }

    init(resolve: @escaping () -> Result<String, CrewError>,
         transport: @escaping (String, ControlCommandKind, PaneTarget) -> Result<ControlResponse, CrewError>) {
        self.resolve = resolve
        self.transport = transport
    }

    public func send(_ kind: ControlCommandKind, target: PaneTarget) -> Result<ControlResponse, CrewError> {
        resolve().flatMap { transport($0, kind, target) }
    }
}
