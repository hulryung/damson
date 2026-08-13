import Darwin
import XCTest
@testable import DamsonAgents

/// The registry reads records damson does not write, in a format damson does not own, and
/// joins them to panes by pid. Every test here is about being wrong safely: a malformed,
/// truncated, stale or mismatched record must produce NO row rather than a plausible one,
/// because a wrong row becomes a wrong badge and the user acts on it.
final class ClaudeSessionRegistryTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("damson-registry-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// Write a record. Defaults to OUR pid, which is by definition alive — the registry
    /// drops records whose process is gone, so a live pid is required to observe anything.
    @discardableResult
    private func write(pid: pid_t = getpid(), status: String = "busy", sessionId: String = "s-1",
                       cwd: String = "/tmp", name: String? = "proj", waitingFor: String? = nil,
                       version: String? = "2.1.228", bodyPID: pid_t? = nil,
                       filename: String? = nil) -> String {
        var obj: [String: Any] = [
            "pid": Int(bodyPID ?? pid), "sessionId": sessionId, "cwd": cwd, "status": status,
        ]
        if let name { obj["name"] = name }
        if let waitingFor { obj["waitingFor"] = waitingFor }
        if let version { obj["version"] = version }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        let path = dir.appendingPathComponent(filename ?? "\(pid).json").path
        FileManager.default.createFile(atPath: path, contents: data)
        return path
    }

    private func makeRegistry() -> ClaudeSessionRegistry { ClaudeSessionRegistry(sessionsDir: dir) }

    func testReadsALiveRecord() {
        write(status: "waiting", waitingFor: "permission to edit main.swift")
        let r = makeRegistry()
        r.refresh()
        let row = r.session(forForegroundPID: getpid())
        XCTAssertEqual(row?.status, "waiting")
        XCTAssertEqual(row?.waitingFor, "permission to edit main.swift")
        XCTAssertEqual(row?.name, "proj")
        XCTAssertEqual(r.observedVersion, "2.1.228")
    }

    /// A status damson has never heard of must still surface as a row — the vocabulary is
    /// dropped in `AgentBadge`, not here. Losing the row would also lose `waitingFor`.
    func testUnknownStatusStillProducesARowAndNoBadge() {
        write(status: "compacting")
        let r = makeRegistry()
        r.refresh()
        XCTAssertEqual(r.session(forForegroundPID: getpid())?.status, "compacting")
        XCTAssertNil(AgentBadge(status: "compacting"))
    }

    /// Claude Code cleans up its own records, but not instantly. A badge for a dead agent
    /// is exactly the lie this class exists to avoid.
    func testRecordForADeadProcessIsIgnored() {
        // pid 0 is never a live user process; the filename is what the registry keys on.
        write(pid: 999_999, bodyPID: 999_999)
        let r = makeRegistry()
        r.refresh()
        XCTAssertTrue(r.byPID.isEmpty, "a record whose process is gone must not produce a row")
    }

    /// A body that disagrees with the filename is a record being rewritten under us, or
    /// something else's file. Trust neither half.
    func testPIDMismatchBetweenFilenameAndBodyIsRejected() {
        write(pid: getpid(), bodyPID: getpid() + 1)
        let r = makeRegistry()
        r.refresh()
        XCTAssertNil(r.session(forForegroundPID: getpid()))
    }

    func testMalformedAndForeignFilesAreIgnored() {
        let live = getpid()
        // Truncated JSON, a record with no status, and files that aren't <pid>.json.
        FileManager.default.createFile(atPath: dir.appendingPathComponent("\(live).json").path,
                                       contents: Data("{\"pid\":".utf8))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("notes.txt").path,
                                       contents: Data("hello".utf8))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("abc.json").path,
                                       contents: Data("{}".utf8))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("\(live).key").path,
                                       contents: Data("secret".utf8))
        let r = makeRegistry()
        r.refresh()
        XCTAssertTrue(r.byPID.isEmpty)
    }

    func testMissingDirectoryIsNotAnError() {
        let r = ClaudeSessionRegistry(
            sessionsDir: dir.appendingPathComponent("nope"))
        r.refresh()
        XCTAssertTrue(r.byPID.isEmpty)
    }

    /// The records are rewritten IN PLACE as status changes — which is why the registry
    /// polls instead of watching the directory. A second refresh must see the new value.
    func testInPlaceRewriteIsPickedUp() {
        write(status: "busy")
        let r = makeRegistry()
        r.refresh()
        XCTAssertEqual(r.session(forForegroundPID: getpid())?.status, "busy")

        // Same path, new contents, and a bumped mtime (the skip-if-unchanged guard keys on it).
        let path = dir.appendingPathComponent("\(getpid()).json").path
        write(status: "waiting")
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: path)
        r.refresh()
        XCTAssertEqual(r.session(forForegroundPID: getpid())?.status, "waiting",
                       "an in-place rewrite must be observed — this is why we poll")
    }

    func testDisappearingRecordClearsTheRow() {
        write()
        let r = makeRegistry()
        r.refresh()
        XCTAssertNotNil(r.session(forForegroundPID: getpid()))
        try? FileManager.default.removeItem(atPath: dir.appendingPathComponent("\(getpid()).json").path)
        r.refresh()
        XCTAssertNil(r.session(forForegroundPID: getpid()), "a closed agent must stop badging")
    }

    func testLookupWithNoForegroundPIDIsNil() {
        write()
        let r = makeRegistry()
        r.refresh()
        // A pane with no tty (a tmux-backed pane) reports nil, and must simply not match.
        XCTAssertNil(r.session(forForegroundPID: nil))
    }
}
