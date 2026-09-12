import XCTest
import CoreGraphics
@testable import DamsonComputer

final class DesktopEventsTests: XCTestCase {
    func testShortcutReleasesModifiersBeforeUnicodeInput() throws {
        let events = DesktopEvents()
        let down = try events.key(0, down: true, flags: [.maskCommand, .maskShift])
        XCTAssertTrue(down.flags.contains(.maskCommand))
        XCTAssertTrue(down.flags.contains(.maskShift))
        let up = try events.key(0, down: false, flags: [.maskCommand, .maskShift])
        XCTAssertTrue(up.flags.isEmpty)
        let units = Array("한🎮".utf16)
        let text = try events.unicode(units, down: true)
        XCTAssertTrue(text.flags.isEmpty)
        var result = [UniChar](repeating: 0, count: 64)
        var count = 0
        text.keyboardGetUnicodeString(maxStringLength: result.count, actualStringLength: &count, unicodeString: &result)
        XCTAssertEqual(Array(result.prefix(count)), units)
    }

    func testScrollCarriesActualTargetPointAndPixelDeltas() throws {
        let point = CGPoint(x: -320, y: 450)
        let event = try DesktopEvents().scroll(dx: 42, dy: -150, at: point)
        XCTAssertEqual(event.type, .scrollWheel)
        XCTAssertEqual(event.location, point)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -150)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), 42)
        XCTAssertTrue(event.flags.isEmpty)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventIsContinuous), 1)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventScrollCount), 1)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventScrollPhase), 0)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventMomentumPhase), 0)
    }

    func testMousePreservesNegativeFractionalGlobalPoints() throws {
        let point = CGPoint(x: -500.5, y: 240.25)
        let event = try DesktopEvents().mouse(.leftMouseDown, at: point)
        XCTAssertEqual(event.location, point)
        XCTAssertEqual(event.type, .leftMouseDown)
        XCTAssertTrue(event.flags.isEmpty)
    }

    func testInvalidUnicodeCannotSilentlyDispatchNothing() throws {
        let events = DesktopEvents()
        XCTAssertThrowsError(try events.unicode([], down: true))
        XCTAssertThrowsError(try events.unicode(Array(repeating: 65, count: 65), down: true))
    }
}
