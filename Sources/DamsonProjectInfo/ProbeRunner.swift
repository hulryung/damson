import Foundation

/// The result of one bounded helper-process run (git, lsof).
public struct ProbeResult: Equatable {
    public enum Outcome: Equatable {
        case exited(Int32)
        /// Killed at the deadline; output is whatever arrived first.
        case timedOut
        /// Killed once stdout passed the cap; output is the first `outputCap` bytes.
        case truncated
        case launchFailed(String)
    }
    public var outcome: Outcome
    public var stdout: Data
    public var stderr: String

    public init(outcome: Outcome, stdout: Data = Data(), stderr: String = "") {
        self.outcome = outcome
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { outcome == .exited(0) }
    public var output: String { String(decoding: stdout, as: UTF8.self) }

    /// Why this run did not succeed, in a few words for the summary panel.
    public var failureReason: String {
        switch outcome {
        case .timedOut: return "timed out"
        case .truncated: return "output too large"
        case .launchFailed(let message): return "could not run (\(message))"
        case .exited(let code):
            let line = stderr.split(whereSeparator: \.isNewline).first.map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            return line.flatMap { $0.isEmpty ? nil : String($0.prefix(160)) } ?? "exit status \(code)"
        }
    }
}

/// Runs a helper with a hard deadline and an output cap, off whatever thread calls it.
///
/// stdout and stderr are separate pipes: a git warning on stderr must never be counted as
/// a status record. Both are drained while the child runs, so a large repository cannot
/// block on a full pipe, and the deadline does not depend on EOF — a grandchild that keeps
/// the pipe open cannot hold the caller past `timeout` plus the kill grace.
public struct ProbeRunner {
    public var timeout: TimeInterval
    public var outputCap: Int
    public var environment: [String: String]

    public init(timeout: TimeInterval = 5, outputCap: Int = 2_000_000,
                environment: [String: String] = ProbeRunner.defaultEnvironment) {
        self.timeout = timeout
        self.outputCap = outputCap
        self.environment = environment
    }

    /// Stable, unlocalised output, and no index.lock taken on the user's repository.
    public static var defaultEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        return env
    }

    public func run(_ executable: String, _ arguments: [String]) -> ProbeResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let lock = NSLock()
        var stdout = Data(), stderr = Data(), truncated = false
        let done = DispatchGroup()
        let cap = outputCap
        func drain(_ handle: FileHandle, into append: @escaping (Data) -> Bool) {
            done.enter()
            var finished = false
            handle.readabilityHandler = { handle in
                let chunk = handle.availableData
                lock.lock()
                if finished { lock.unlock(); return }
                if chunk.isEmpty {
                    finished = true
                    handle.readabilityHandler = nil
                    lock.unlock()
                    done.leave()
                    return
                }
                let overflow = append(chunk)
                lock.unlock()
                if overflow, process.isRunning { process.terminate() }
            }
        }
        drain(out.fileHandleForReading) { chunk in
            if truncated { return false }
            if stdout.count + chunk.count > cap {
                stdout.append(chunk.prefix(cap - stdout.count))
                truncated = true
                return true
            }
            stdout.append(chunk)
            return false
        }
        drain(err.fileHandleForReading) { chunk in
            if stderr.count < 65_536 { stderr.append(chunk.prefix(65_536 - stderr.count)) }
            return false
        }
        done.enter()
        process.terminationHandler = { _ in done.leave() }

        do { try process.run() } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            return ProbeResult(outcome: .launchFailed(error.localizedDescription))
        }
        // The write ends belong to the child now; holding them here would keep EOF away.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()

        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            if process.isRunning { process.terminate() }
            if done.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 1)
            }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil

        lock.lock()
        defer { lock.unlock() }
        let errText = String(decoding: stderr, as: UTF8.self)
        let outcome: ProbeResult.Outcome
        if truncated { outcome = .truncated }
        else if timedOut { outcome = .timedOut }
        else if process.isRunning { outcome = .timedOut }
        else { outcome = .exited(process.terminationStatus) }
        return ProbeResult(outcome: outcome, stdout: stdout, stderr: errText)
    }
}
