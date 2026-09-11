import XCTest
@testable import DamsonComputer

final class ComputerSessionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testExclusiveLeaseExpiresAndRejectsStaleOwner() throws {
        var time = Date()
        let store = ComputerSessionStore(root: root, now: { time })
        let first = try store.acquire(owner: "workflow-a", pid: 1, started: "one", ttl: 10)
        XCTAssertThrowsError(try store.acquire(owner: "workflow-b", pid: 2, started: "two", ttl: 10))
        time.addTimeInterval(11)
        let second = try store.acquire(owner: "workflow-b", pid: 2, started: "two", ttl: 10)
        XCTAssertThrowsError(try store.release(first.token))
        XCTAssertEqual(try store.require(second.token), second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.artifacts + "/session.json"))
    }

    func testStopRevokesTokenAndRequiresExplicitResume() throws {
        let store = ComputerSessionStore(root: root)
        let first = try store.acquire(owner: "a", pid: 1, started: "one", ttl: 30)
        store.stop()
        XCTAssertThrowsError(try store.require(first.token))
        XCTAssertThrowsError(try store.acquire(owner: "b", pid: 2, started: "two", ttl: 30))
        store.resume()
        let second = try store.acquire(owner: "b", pid: 2, started: "two", ttl: 30)
        XCTAssertNotEqual(first.token, second.token)
        XCTAssertThrowsError(try store.renew(first.token, ttl: 30))
    }

    func testInvalidTTLAndOwnerCannotOccupyDesktop() throws {
        let store = ComputerSessionStore(root: root)
        for ttl in [Double.nan, .infinity, -1, 0, 301] {
            XCTAssertThrowsError(try store.acquire(owner: "a", pid: 1, started: "x", ttl: ttl))
        }
        XCTAssertThrowsError(try store.acquire(owner: " ", pid: 1, started: "x", ttl: 30))
        XCTAssertNil(store.session)
    }

    func testRenewExtendsOnlyLiveSession() throws {
        var time = Date()
        let store = ComputerSessionStore(root: root, now: { time })
        let first = try store.acquire(owner: "a", pid: 1, started: "one", ttl: 10)
        time.addTimeInterval(9)
        _ = try store.renew(first.token, ttl: 20)
        time.addTimeInterval(15)
        XCTAssertNoThrow(try store.require(first.token))
        time.addTimeInterval(6)
        XCTAssertThrowsError(try store.renew(first.token, ttl: 20))
    }

    func testRestartNeverRestoresAuthorityFromArtifactFiles() throws {
        let first = ComputerSessionStore(root: root)
        let value = try first.acquire(owner: "a", pid: 1, started: "one", ttl: 30)
        let restarted = ComputerSessionStore(root: root)
        XCTAssertThrowsError(try restarted.require(value.token))
    }
}
