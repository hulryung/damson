import Foundation

/// Explicit, finite work. Interactive badges never advance this graph.
public struct Workflow: Codable, Equatable {
    public var version: Int
    public var name: String
    public var maxParallel: Int
    public var tasks: [WorkflowTask]

    enum CodingKeys: String, CodingKey, CaseIterable { case version, name, maxParallel, tasks }

    init(version: Int, name: String, maxParallel: Int, tasks: [WorkflowTask]) {
        self.version = version
        self.name = name
        self.maxParallel = maxParallel
        self.tasks = tasks
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownWorkflowFields(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        name = try c.decode(String.self, forKey: .name)
        maxParallel = try c.decode(Int.self, forKey: .maxParallel)
        tasks = try c.decode([WorkflowTask].self, forKey: .tasks)
    }

    public static func load(_ url: URL) throws -> Workflow {
        var flow = try JSONDecoder().decode(Workflow.self, from: Data(contentsOf: url))
        for index in flow.tasks.indices {
            let path = (flow.tasks[index].cwd as NSString).expandingTildeInPath
            flow.tasks[index].cwd = URL(fileURLWithPath: path,
                relativeTo: url.deletingLastPathComponent()).standardizedFileURL.path
        }
        try flow.validate()
        return flow
    }

    public func validate() throws {
        guard version == 1 else { throw CrewError("unsupported workflow version: \(version)") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...32).contains(maxParallel), !tasks.isEmpty else {
            throw CrewError("workflow needs a name, tasks, and maxParallel between 1 and 32")
        }
        var ids = Set<String>()
        for task in tasks {
            guard !task.id.isEmpty, task.id.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            }), ids.insert(task.id).inserted else { throw CrewError("invalid or duplicate task id: \(task.id)") }
            guard !task.command.isEmpty, !task.command[0].isEmpty,
                  (1...10).contains(task.maxAttempts), task.timeoutSeconds.isFinite,
                  task.timeoutSeconds > 0, task.timeoutSeconds <= 86400 else {
                throw CrewError("invalid command, maxAttempts, or timeoutSeconds: \(task.id)")
            }
            guard task.verify.allSatisfy({ !$0.isEmpty && !$0[0].isEmpty }),
                  !(task.command + task.verify.flatMap { $0 }).contains(where: { $0.contains("\0") }) else {
                throw CrewError("invalid validation command or NUL argument: \(task.id)")
            }
            if let prompt = task.prompt {
                guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !prompt.contains("\0"), !task.verify.isEmpty else {
                    throw CrewError("agent task requires a nonempty prompt and validation commands: \(task.id)")
                }
                let isClaude = (task.command[0] as NSString).lastPathComponent == "claude"
                if isClaude && !task.command.contains("--print") && !task.command.contains("-p") {
                    throw CrewError("managed Claude tasks require --print: \(task.id)")
                }
            }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: task.cwd, isDirectory: &directory), directory.boolValue else {
                throw CrewError("task \(task.id) working directory does not exist: \(task.cwd)")
            }
            for output in task.outputs {
                guard !output.isEmpty, !output.hasPrefix("/"),
                      !output.split(separator: "/").contains("..") else {
                    throw CrewError("task outputs must be relative paths without '..': \(task.id)")
                }
            }
        }
        for task in tasks {
            guard Set(task.dependsOn).count == task.dependsOn.count,
                  Set(task.dependsOn).isSubset(of: ids), !task.dependsOn.contains(task.id) else {
                throw CrewError("unknown, duplicate, or self dependency: \(task.id)")
            }
        }
        var visited = Set<String>()
        while visited.count < tasks.count {
            let ready = tasks.filter { !visited.contains($0.id) && Set($0.dependsOn).isSubset(of: visited) }
            guard !ready.isEmpty else { throw CrewError("workflow contains a dependency cycle") }
            visited.formUnion(ready.map(\.id))
        }
    }
}

public struct WorkflowTask: Codable, Equatable {
    public var id: String
    public var cwd: String
    public var command: [String]
    public var prompt: String?
    public var dependsOn: [String] = []
    public var verify: [[String]] = []
    public var outputs: [String] = []
    /// Tasks sharing a resource are serialized, even if their graph allows parallel work.
    public var resources: [String] = []
    public var maxAttempts: Int = 1
    public var timeoutSeconds: Double = 900

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, cwd, command, prompt, dependsOn, verify, outputs, resources, maxAttempts, timeoutSeconds
    }

    func argv(previousLog: String?) -> [String] {
        guard var text = prompt else { return command }
        if let previousLog {
            text += "\n\nThe previous attempt failed. Read its command and validation log at " + previousLog +
                ". Correct the failure in the existing work and re-run the relevant tests before finishing."
        }
        if command.contains(where: { $0.contains("{prompt}") }) {
            return command.map { $0.replacingOccurrences(of: "{prompt}", with: text) }
        }
        return command + [text]
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownWorkflowFields(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        cwd = try c.decode(String.self, forKey: .cwd)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        if let explicit = try c.decodeIfPresent([String].self, forKey: .command) {
            command = explicit
        } else if prompt != nil {
            command = ["claude", "--print", "--output-format", "json"]
        } else {
            throw CrewError("task requires command or prompt: \(id)")
        }
        dependsOn = try c.decodeIfPresent([String].self, forKey: .dependsOn) ?? []
        verify = try c.decodeIfPresent([[String]].self, forKey: .verify) ?? []
        outputs = try c.decodeIfPresent([String].self, forKey: .outputs) ?? []
        resources = try c.decodeIfPresent([String].self, forKey: .resources) ?? []
        maxAttempts = try c.decodeIfPresent(Int.self, forKey: .maxAttempts) ?? 1
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 900
    }
}

public struct WorkflowState: Codable {
    public enum Status: String, Codable { case pending, running, succeeded, failed, blocked }
    public struct TaskState: Codable {
        public var status: Status = .pending
        public var attempts: Int = 0
        public var attempt: String?
        public var pane: String?
        public var dispatchedAt: Date?
        public var message: String?
    }
    public var version = 1
    public var runID = UUID().uuidString
    public var workflow: Workflow
    public var tasks: [String: TaskState]

    public init(workflow: Workflow) {
        self.workflow = workflow
        tasks = Dictionary(uniqueKeysWithValues: workflow.tasks.map { ($0.id, TaskState()) })
    }

    public var finished: Bool {
        tasks.values.allSatisfy { [.succeeded, .failed, .blocked].contains($0.status) }
    }
    public var succeeded: Bool { tasks.values.allSatisfy { $0.status == .succeeded } }

    public func readyTasks() -> [WorkflowTask] {
        let running = workflow.tasks.filter { tasks[$0.id]?.status == .running }
        var resources = Set(running.flatMap(\.resources))
        var slots = workflow.maxParallel - running.count
        return workflow.tasks.filter { task in
            guard slots > 0, tasks[task.id]?.status == .pending,
                  task.dependsOn.allSatisfy({ tasks[$0]?.status == .succeeded }),
                  resources.isDisjoint(with: task.resources) else { return false }
            resources.formUnion(task.resources)
            slots -= 1
            return true
        }
    }

    public mutating func blockDescendants() {
        var changed = true
        while changed {
            changed = false
            for task in workflow.tasks where tasks[task.id]?.status == .pending {
                if task.dependsOn.contains(where: { [.failed, .blocked].contains(tasks[$0]?.status) }) {
                    tasks[task.id]?.status = .blocked
                    tasks[task.id]?.message = "prerequisite failed"
                    changed = true
                }
            }
        }
    }
}

private struct WorkflowJSONKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectUnknownWorkflowFields(_ decoder: Decoder, allowed: Set<String>) throws {
    let fields = try decoder.container(keyedBy: WorkflowJSONKey.self)
    let unknown = Set(fields.allKeys.map(\.stringValue)).subtracting(allowed)
    if !unknown.isEmpty { throw CrewError("unknown workflow fields: " + unknown.sorted().joined(separator: ", ")) }
}
