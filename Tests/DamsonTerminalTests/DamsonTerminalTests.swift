import XCTest
import Combine
@testable import DamsonTerminal

final class DamsonTerminalTests: XCTestCase {
    func testClearSelectionFiresRequest() {
        let session = DamsonSession(config: DamsonConfig())
        defer { session.terminate() }
        var fired = 0
        let sub = session.clearSelectionRequested.sink { fired += 1 }
        defer { sub.cancel() }
        session.clearSelection()
        XCTAssertEqual(fired, 1, "clearSelection() must fan out over clearSelectionRequested")
    }

    func testSessionInitializes() {
        let session = DamsonSession(config: DamsonConfig())
        defer { session.terminate() }
        XCTAssertFalse(session.processExited)
        XCTAssertNil(session.exitCode)
        XCTAssertEqual(session.title, "")
    }

    func testConfigDefaults() {
        let config = DamsonConfig()
        XCTAssertEqual(config.fontFamily, "Menlo")
        XCTAssertEqual(config.fontSize, 13)
        XCTAssertGreaterThan(config.scrollbackBytes, 0)
        XCTAssertFalse(config.argv.isEmpty)
        XCTAssertTrue(config.animations)
    }
}
