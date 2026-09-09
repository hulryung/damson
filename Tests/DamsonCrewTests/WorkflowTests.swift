import DamsonControl
import Foundation
import XCTest
@testable import DamsonCrew

final class WorkflowTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func task(_ id: String, dependencies: [String] = [], command: [String] = ["/usr/bin/true"],
                      extra: [String: Any] = [:]) throws -> WorkflowTask {
        var object: [String: Any] = ["id": id, "cwd": root.path, "command": command, "dependsOn": dependencies]
        object.merge(extra) { _, value in value }
        return try JSONDecoder().decode(WorkflowTask.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func flow(_ tasks: [WorkflowTask], parallel: Int = 2) -> Workflow {
        Workflow(version: 1, name: "test", maxParallel: parallel, tasks: tasks)
    }
    private final class Client: DamsonClient {
        var specs: [SpawnSpec] = []
        var onSpawn: ((SpawnSpec) -> Void)?
        func send(_ kind: ControlCommandKind, target: PaneTarget) -> Result<ControlResponse, CrewError> {
            guard case .spawnPane(let spec) = kind else { return .failure(CrewError("unexpected request")) }
            specs.append(spec)
            onSpawn?(spec)
            return .success(.pane(PaneInfo(index: 0, cols: 80, rows: 24, active: false,
                                          id: UUID().uuidString)))
        }
    }
    private func runner(_ workflow: Workflow, _ client: Client = Client()) throws -> WorkflowRunner {
        try WorkflowRunner(workflow: workflow, directory: root.appendingPathComponent("state"),
                           executable: "/test/damson-crew", client: client)
    }
    private func result(_ runner: WorkflowRunner, task: String, succeeded: Bool) throws {
        let token = try XCTUnwrap(runner.state.tasks[task]?.attempt)
        let store = WorkflowStore(root: root.appendingPathComponent("state"))
        try store.save(WorkflowResult(token: token, succeeded: succeeded, message: "fixture"),
                       to: store.attemptURL(token).appendingPathComponent("result.json"))
    }

    func testRejectsCyclesUnknownAndDuplicateIDs() throws {
        XCTAssertThrowsError(try flow([task("a", dependencies: ["b"]), task("b", dependencies: ["a"])]).validate())
        XCTAssertThrowsError(try flow([task("a", dependencies: ["missing"])]).validate())
        XCTAssertThrowsError(try flow([task("a"), task("a")]).validate())
        XCTAssertThrowsError(try flow([task("../a")]).validate())
    }

    func testRejectsInvalidInputsBeforeCreatingStateOrSpawning() throws {
        let client = Client()
        XCTAssertThrowsError(try runner(flow([task("a", extra: ["timeoutSeconds": 0])]), client))
        XCTAssertThrowsError(try runner(flow([task("a", extra: ["verify": [[]]])]), client))
        XCTAssertThrowsError(try runner(flow([task("a", extra: ["outputs": ["../escape"]])]), client))
        XCTAssertThrowsError(try runner(flow([task("a", extra: ["cwd": "/missing-directory-workflow"])]), client))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("state").path))
        XCTAssertTrue(client.specs.isEmpty)
    }

    func testDependenciesAndConcurrency() throws {
        let client = Client()
        let run = try runner(flow([task("a"), task("b"), task("c", dependencies: ["a", "b"])]), client)
        try run.tick()
        XCTAssertEqual(client.specs.count, 2)
        try result(run, task: "a", succeeded: true)
        try run.tick()
        XCTAssertEqual(run.state.tasks["c"]?.status, .pending)
        try result(run, task: "b", succeeded: true)
        try run.tick()
        XCTAssertEqual(run.state.tasks["c"]?.status, .running)
        try result(run, task: "c", succeeded: true)
        try run.tick()
        XCTAssertTrue(run.state.succeeded)
    }

    func testSharedResourcesSerializeButIndependentResourcesRun() throws {
        let tasks = try [task("a", extra: ["resources": ["repo"]]),
                         task("b", extra: ["resources": ["repo"]]), task("c")]
        let run = try runner(flow(tasks, parallel: 3))
        try run.tick()
        XCTAssertEqual(run.state.tasks["a"]?.status, .running)
        XCTAssertEqual(run.state.tasks["b"]?.status, .pending)
        XCTAssertEqual(run.state.tasks["c"]?.status, .running)
    }

    func testFailureBlocksTransitiveDependentsButNotIndependentWork() throws {
        let run = try runner(flow([task("a"), task("b", dependencies: ["a"]),
                                   task("c", dependencies: ["b"]), task("d")]))
        try run.tick()
        try result(run, task: "a", succeeded: false)
        try result(run, task: "d", succeeded: true)
        try run.tick()
        XCTAssertEqual(run.state.tasks["b"]?.status, .blocked)
        XCTAssertEqual(run.state.tasks["c"]?.status, .blocked)
        XCTAssertTrue(run.state.finished)
        XCTAssertFalse(run.state.succeeded)
    }

    func testRetriesUseNewAttemptAndStopAtBound() throws {
        let client = Client()
        let run = try runner(flow([task("a", extra: ["maxAttempts": 2])]), client)
        try run.tick()
        let first = run.state.tasks["a"]?.attempt
        try result(run, task: "a", succeeded: false)
        try run.tick()
        XCTAssertNotEqual(run.state.tasks["a"]?.attempt, first)
        XCTAssertEqual(run.state.tasks["a"]?.attempts, 2)
        XCTAssertNotEqual(client.specs[0].key, client.specs[1].key)
        try result(run, task: "a", succeeded: false)
        try run.tick()
        XCTAssertEqual(run.state.tasks["a"]?.status, .failed)
        XCTAssertEqual(client.specs.count, 2)
    }

    func testCoordinatorLockRejectsConcurrentWriter() throws {
        let workflow = try flow([task("a")])
        let run = try runner(workflow)
        XCTAssertThrowsError(try runner(workflow))
        withExtendedLifetime(run) {}
    }

    func testResumePreservesPendingAttemptAndCompletedWork() throws {
        let workflow = try flow([task("a"), task("b", dependencies: ["a"])])
        let client = Client()
        var run: WorkflowRunner? = try runner(workflow, client)
        try run!.tick()
        let token = run!.state.tasks["a"]?.attempt
        run = nil
        run = try runner(workflow, client)
        try run!.tick()
        XCTAssertEqual(run!.state.tasks["a"]?.attempt, token)
        XCTAssertEqual(client.specs[0].key, client.specs[1].key)
        try result(run!, task: "a", succeeded: true)
        try run!.tick()
        run = nil
        run = try runner(workflow, client)
        try run!.tick()
        XCTAssertEqual(run!.state.tasks["a"]?.status, .succeeded)
        XCTAssertEqual(run!.state.tasks["a"]?.attempts, 1)
    }

    func testChangedPlanCannotResume() throws {
        let workflow = try flow([task("a")])
        var run: WorkflowRunner? = try runner(workflow)
        try run!.tick()
        run = nil
        XCTAssertThrowsError(try runner(flow([task("a", command: ["/usr/bin/false"])])))
    }

    func testHeldWorkerLockPreventsDuplicateSpawn() throws {
        let client = Client()
        let run = try runner(flow([task("a")]), client)
        try run.tick()
        let token = try XCTUnwrap(run.state.tasks["a"]?.attempt)
        let store = WorkflowStore(root: root.appendingPathComponent("state"))
        let workerLock = try WorkflowLock(store.attemptURL(token).appendingPathComponent("worker.lock"))
        try run.tick()
        XCTAssertEqual(client.specs.count, 1)
        withExtendedLifetime(workerLock) {}
    }

    func testInterruptedAttemptFailsWithoutReplaying() throws {
        let run = try runner(flow([task("a")]))
        try run.tick()
        let token = try XCTUnwrap(run.state.tasks["a"]?.attempt)
        let store = WorkflowStore(root: root.appendingPathComponent("state"))
        try store.save(["pid": 123], to: store.attemptURL(token).appendingPathComponent("started.json"))
        try run.tick()
        XCTAssertEqual(run.state.tasks["a"]?.status, .failed)
        XCTAssertEqual(try WorkflowWorker.run(directory: store.attemptURL(token)), 1)
    }

    private func worker(_ task: WorkflowTask) throws -> WorkflowResult {
        let directory = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = WorkflowStore(root: directory)
        try store.save(WorkflowAttempt(token: "test", task: task), to: directory.appendingPathComponent("input.json"))
        _ = try WorkflowWorker.run(directory: directory)
        // A replay must return the sealed result without running any command again.
        _ = try WorkflowWorker.run(directory: directory)
        return try store.read(WorkflowResult.self, from: directory.appendingPathComponent("result.json"))
    }

    func testWorkerRunsRealCommandAndValidatorExactlyOnce() throws {
        let result = try worker(task("a", command: ["/bin/sh", "-c", "echo once >> artifact"],
                                     extra: ["outputs": ["artifact"], "verify": [["/bin/test", "-f", "artifact"]]]))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("artifact")), "once\n")
    }

    func testExitZeroCannotBypassValidationOrMissingOutput() throws {
        XCTAssertFalse(try worker(task("a", extra: ["verify": [["/usr/bin/false"]]])).succeeded)
        XCTAssertFalse(try worker(task("b", extra: ["outputs": ["missing"]])).succeeded)
        XCTAssertFalse(try worker(task("c", command: ["/usr/bin/false"])).succeeded)
    }

    func testTimeoutTerminatesRealProcess() throws {
        let started = Date()
        let result = try worker(task("a", command: ["/bin/sleep", "30"], extra: ["timeoutSeconds": 0.2]))
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.message.contains("timed out"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
    func testMisspelledDependencyFieldIsRejected() throws {
        XCTAssertThrowsError(try task("a", extra: ["dependencies": ["b"]]))
    }

    func testPromptTasksRequireFiniteCommandAndValidation() throws {
        XCTAssertThrowsError(try flow([task("a", extra: ["prompt": "implement"])]).validate())
        XCTAssertThrowsError(try flow([task("a", command: ["claude"],
            extra: ["prompt": "implement", "verify": [["/usr/bin/true"]]])]).validate())
        let agent = try task("a", command: ["claude", "--print"],
            extra: ["prompt": "implement", "verify": [["/usr/bin/true"]]])
        XCTAssertNoThrow(try flow([agent]).validate())
        XCTAssertTrue(agent.argv(previousLog: "/previous/output.log").last?.contains("/previous/output.log") == true)
    }

    func testLostWorkerDoesNotRetryPotentiallySurvivingChildren() throws {
        let run = try runner(flow([task("a", extra: ["maxAttempts": 3])]))
        try run.tick()
        let token = try XCTUnwrap(run.state.tasks["a"]?.attempt)
        let store = WorkflowStore(root: root.appendingPathComponent("state"))
        try store.save(["pid": 123], to: store.attemptURL(token).appendingPathComponent("started.json"))
        try run.tick()
        XCTAssertEqual(run.state.tasks["a"]?.status, .failed)
        XCTAssertEqual(run.state.tasks["a"]?.attempts, 1)
    }

    func testTimeoutTerminatesDescendantsInCommandProcessGroup() throws {
        let result = try worker(task("a", command: ["/bin/sh", "-c", "sleep 30 & echo $! > child-pid; wait"],
                                     extra: ["timeoutSeconds": 0.3]))
        XCTAssertFalse(result.succeeded)
        let text = try String(contentsOf: root.appendingPathComponent("child-pid"))
        let pid = try XCTUnwrap(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        // kill(pid, 0) can still see an unreaped zombie; ps state distinguishes it from a live child.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "stat=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let status = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertTrue(status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || status.contains("Z"), status)
    }

}
