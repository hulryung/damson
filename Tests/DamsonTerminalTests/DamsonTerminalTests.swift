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

    func testFontZoomDefaultsToOneAndClamps() {
        let session = DamsonSession(config: DamsonConfig())
        defer { session.terminate() }
        XCTAssertEqual(session.fontZoom, 1.0)
        session.setFontZoom(2.0)
        XCTAssertEqual(session.fontZoom, 2.0)
        session.setFontZoom(100)
        XCTAssertEqual(session.fontZoom, DamsonSession.fontZoomRange.upperBound)
        session.setFontZoom(0)
        XCTAssertEqual(session.fontZoom, DamsonSession.fontZoomRange.lowerBound)
    }

    func testFontZoomPublishesOnlyOnChange() {
        let session = DamsonSession(config: DamsonConfig())
        defer { session.terminate() }
        var seen: [CGFloat] = []
        let sub = session.$fontZoom.dropFirst().sink { seen.append($0) }
        defer { sub.cancel() }
        session.setFontZoom(1.0)   // already 1.0 — a fresh tab copying the default must not redraw
        session.setFontZoom(1.5)
        session.setFontZoom(1.5)   // unchanged
        session.setFontZoom(9)     // clamped to the same value every time
        session.setFontZoom(9)
        XCTAssertEqual(seen, [1.5, DamsonSession.fontZoomRange.upperBound])
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
