import DamsonControl
import DamsonCrew
import Foundation

/// Separate parser keeps existing interactive fan-out behavior compatible.
enum WorkflowCommand {
    static let help = """
    Managed workflows (finite commands with explicit completion):
      damson-crew workflow run --plan FILE --state DIR [--pid PID]
      damson-crew workflow status --state DIR
      damson-crew workflow validate --plan FILE

    run validates the graph, then opens ready tasks in Damson panes. It waits for
    command exit, validation commands, and declared output files before advancing.
    Re-run with the same plan/state to resume. Changed plans require a new directory.
    Ctrl-C stops the coordinator; workers continue, and the same command resumes.
    Task logs and attempt results are retained in DIR. A failed workflow exits 1.
    """

    static func execute(_ args: [String]) -> Int32? {
        guard let command = args.first, ["workflow", "workflow-worker"].contains(command) else { return nil }
        do {
            if command == "workflow-worker" {
                guard args.count == 2 else { throw CrewError("workflow-worker requires an attempt directory") }
                return try WorkflowWorker.run(directory: URL(fileURLWithPath: args[1]))
            }
            return try workflow(Array(args.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("damson-crew: \(error)\n".utf8))
            return 2
        }
    }

    private static func workflow(_ args: [String]) throws -> Int32 {
        guard let action = args.first, !["--help", "-h"].contains(action) else { print(help); return 0 }
        guard ["run", "status", "validate"].contains(action) else { throw CrewError(help) }
        var values: [String: String] = [:]
        var i = 1
        while i < args.count {
            let key = args[i]
            guard ["--plan", "--state", "--pid"].contains(key), i + 1 < args.count,
                  values[key] == nil else { throw CrewError("invalid or duplicate workflow option: \(key)") }
            values[key] = args[i + 1]
            i += 2
        }
        if action == "validate" {
            guard let plan = values["--plan"], values["--state"] == nil, values["--pid"] == nil else {
                throw CrewError("workflow validate requires only --plan FILE")
            }
            let flow = try Workflow.load(URL(fileURLWithPath: (plan as NSString).expandingTildeInPath))
            print("valid: \(flow.name), \(flow.tasks.count) tasks, maxParallel=\(flow.maxParallel)")
            return 0
        }
        guard let path = values["--state"] else { throw CrewError("workflow requires --state DIR") }
        let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        if action == "status" {
            guard values["--plan"] == nil, values["--pid"] == nil else {
                throw CrewError("workflow status accepts only --state")
            }
            let data = try Data(contentsOf: directory.appendingPathComponent("state.json"))
            let state = try JSONDecoder().decode(WorkflowState.self, from: data)
            FileHandle.standardOutput.write(data)
            print("")
            return state.finished && !state.succeeded ? 1 : 0
        }
        guard let plan = values["--plan"] else { throw CrewError("workflow run requires --plan FILE") }
        var flow = try Workflow.load(URL(fileURLWithPath: (plan as NSString).expandingTildeInPath))
        let settings = OrchestrationSettings.load()
        for index in flow.tasks.indices where flow.tasks[index].prompt != nil {
            flow.tasks[index].command = AgentFlags.apply(skipPermissions: settings.skipPermissions,
                                                        to: flow.tasks[index].command)
        }
        var pid: Int?
        if let value = values["--pid"] {
            guard let parsed = Int(value), parsed > 0 else { throw CrewError("--pid must be positive") }
            pid = parsed
        }
        let client = ResolvingDamsonClient(resolve: {
            pickDamsonSocket(pid: pid).mapError { CrewError($0.message) }
        })
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let runner = try WorkflowRunner(workflow: flow, directory: directory,
                                        executable: executable, client: client)
        var previous: [String: String] = [:]
        repeat {
            try runner.tick()
            for task in flow.tasks {
                guard let row = runner.state.tasks[task.id] else { continue }
                let line = "\(task.id)\t\(row.status.rawValue)\tattempt=\(row.attempts)\t\(row.message ?? "")"
                if previous[task.id] != line {
                    FileHandle.standardOutput.write(Data((line + "\n").utf8))
                    previous[task.id] = line
                }
            }
            if !runner.state.finished { Thread.sleep(forTimeInterval: 0.25) }
        } while !runner.state.finished
        return runner.state.succeeded ? 0 : 1
    }
}
