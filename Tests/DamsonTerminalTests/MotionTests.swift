import XCTest
import AppKit
@testable import DamsonTerminal

final class MotionTests: XCTestCase {

    // MARK: enabled gate truth table (pure function — no UserDefaults/NSWorkspace mocking)

    func testEnabledWhenToggleOnAndReduceMotionOff() {
        XCTAssertTrue(Motion.isEnabled(toggledOn: true, reduceMotionEnabled: false))
    }

    func testDisabledWhenToggleOff() {
        XCTAssertFalse(Motion.isEnabled(toggledOn: false, reduceMotionEnabled: false))
    }

    func testReduceMotionWinsOverToggleOn() {
        // Reduce Motion must take precedence over the toggle and block motion.
        XCTAssertFalse(Motion.isEnabled(toggledOn: true, reduceMotionEnabled: true))
    }

    func testDisabledWhenBothOff() {
        XCTAssertFalse(Motion.isEnabled(toggledOn: false, reduceMotionEnabled: true))
    }

    // MARK: snapshot

    func testSnapshotReturnsImageForSizedView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        view.wantsLayer = true
        XCTAssertNotNil(Motion.snapshot(of: view))
    }

    func testSnapshotReturnsNilForZeroSizeView() {
        let view = NSView(frame: .zero)
        XCTAssertNil(Motion.snapshot(of: view))
    }

    // MARK: timing constants

    func testTimingConstants() {
        XCTAssertEqual(Motion.duration, 0.16, accuracy: 0.0001)
    }
}
