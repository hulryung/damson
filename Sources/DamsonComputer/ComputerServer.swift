import Foundation
import Darwin
import DamsonControl

/// A process-wide lock makes the socket and desktop lease unique across every
/// Damson instance. Client reads run off the UI thread and have finite timeouts.
public final class ComputerServer {
    private var listener: Int32 = -1
    private var lockFD: Int32 = -1
    private let slots = DispatchSemaphore(value: 8)

    public init() {}

    public func start(handler: @escaping (ComputerRequest, @escaping (Data) -> Void) -> Void) throws {
        try ComputerPaths.prepareRuntime()
        lockFD = open(ComputerPaths.runtime + "/helper.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw ComputerFailure("already_running", "A computer helper is already running.")
        }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw ComputerFailure("transport", "Cannot create listener.") }
        unlink(ComputerPaths.socket)
        if let error = bindOrConnectUnix(fd: listener, path: ComputerPaths.socket, listen: true) {
            throw ComputerFailure("transport", error)
        }
        chmod(ComputerPaths.socket, 0o600)
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        let serverFD = listener
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while true {
                let client = accept(serverFD, nil, nil)
                if client < 0 { if errno == EINTR { continue }; break }
                guard slots.wait(timeout: .now()) == .success else { close(client); continue }
                ComputerTransport.configure(client)
                DispatchQueue.global().async { [self] in
                    defer { close(client); slots.signal() }
                    var uid: uid_t = 0
                    var gid: gid_t = 0
                    guard getpeereid(client, &uid, &gid) == 0, uid == getuid(),
                          case .line(let data) = readFramedLine(fd: client, hardCap: 64 * 1024),
                          data.count <= 64 * 1024,
                          let request = try? JSONDecoder().decode(ComputerRequest.self, from: data) else { return }
                    let done = DispatchSemaphore(value: 0)
                    // The completion is exactly once; keep the descriptor open until it
                    // completes, so a late async screenshot cannot write to a reused fd.
                    handler(request) { reply in
                        // A client that stops reading must not block the main actor
                        // (including the menu's Stop action) while its write times out.
                        DispatchQueue.global().async {
                            try? ComputerTransport.writeLine(reply, fd: client)
                            done.signal()
                        }
                    }
                    done.wait()
                }
            }
        }
    }

    deinit {
        if listener >= 0 { close(listener) }
        if lockFD >= 0 { close(lockFD) }
    }
}
