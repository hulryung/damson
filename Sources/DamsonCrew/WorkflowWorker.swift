import Darwin
import Foundation

/// A finite worker runs inside a real terminal pane. Its private result record, not the
/// terminal's interactive status, is the scheduler's completion protocol.
public enum WorkflowWorker {
    public static func run(directory: URL) throws -> Int32 {
        let store = WorkflowStore(root: directory)
        let lock = try WorkflowLock(directory.appendingPathComponent("worker.lock"))
        defer { withExtendedLifetime(lock) {} }
        let resultURL = directory.appendingPathComponent("result.json")
        if FileManager.default.fileExists(atPath: resultURL.path) {
            return try store.read(WorkflowResult.self, from: resultURL).succeeded ? 0 : 1
        }
        let attempt = try store.read(WorkflowAttempt.self, from: directory.appendingPathComponent("input.json"))
        let started = directory.appendingPathComponent("started.json")
        // A cold app restore may replay argv. Never repeat an already-started attempt.
        if FileManager.default.fileExists(atPath: started.path) {
            try store.save(WorkflowResult(token: attempt.token, succeeded: false,
                message: "worker interrupted; inspect any surviving child processes before retrying", retryable: false), to: resultURL)
            return 1
        }
        try store.save(["pid": Int(getpid())], to: started)
        let deadline = Date().addingTimeInterval(attempt.task.timeoutSeconds)
        let logURL = directory.appendingPathComponent("output.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        var result = WorkflowResult(token: attempt.token, succeeded: false, message: "worker failed")
        do {
            try execute(attempt.task.argv(previousLog: attempt.previousLog), cwd: attempt.task.cwd, log: log, logURL: logURL,
                        deadline: deadline)
            for (index, command) in attempt.task.verify.enumerated() {
                print("\n[damson-crew] validation \(index + 1)/\(attempt.task.verify.count)")
                try execute(command, cwd: attempt.task.cwd, log: log, logURL: logURL, deadline: deadline)
            }
            for path in attempt.task.outputs {
                let url = URL(fileURLWithPath: attempt.task.cwd).appendingPathComponent(path)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw CrewError("required output missing: \(path)")
                }
            }
            result.succeeded = true
            result.message = "command, validations, and required outputs passed"
        } catch { result.message = String(describing: error) }
        try log.write(contentsOf: Data(("\n[damson-crew] " + result.message + "\n").utf8))
        try log.synchronize()
        try store.save(result, to: resultURL)
        print("\n[damson-crew] \(attempt.task.id): \(result.succeeded ? "SUCCEEDED" : "FAILED") — \(result.message)")
        return result.succeeded ? 0 : 1
    }

    private static func execute(_ command: [String], cwd: String, log: FileHandle, logURL: URL,
                                deadline: Date) throws {
        guard Date() < deadline else { throw CrewError("task timeout reached") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        var environment = ProcessInfo.processInfo.environment
        for key in ["CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDECODE"] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        let reader = try FileHandle(forReadingFrom: logURL)
        defer { try? reader.close() }
        try reader.seek(toOffset: log.offset())
        try process.run()
        var timedOut = false
        while process.isRunning {
            relay(reader)
            if Date() >= deadline {
                timedOut = true
                terminate(process)
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        relay(reader)
        if timedOut { throw CrewError("task timed out") }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw CrewError("command failed (exit \(process.terminationStatus)): \(command.first ?? "")")
        }
    }

    private static func relay(_ reader: FileHandle) {
        if let data = try? reader.read(upToCount: 65536), !data.isEmpty {
            try? FileHandle.standardOutput.write(contentsOf: data)
        }
    }

    private static func terminate(_ process: Process) {
        // Foundation on macOS creates a process group per child. Check before signalling
        // a group: never send a signal to the terminal's own foreground group by accident.
        let pid = process.processIdentifier
        let group = getpgid(pid)
        if group == pid { kill(-pid, SIGTERM) } else { process.terminate() }
        let grace = Date().addingTimeInterval(1)
        while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
        if group == pid { kill(-pid, SIGKILL) } else if process.isRunning { kill(pid, SIGKILL) }
    }
}
