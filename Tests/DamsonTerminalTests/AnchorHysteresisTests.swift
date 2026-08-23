import XCTest
@testable import DamsonTerminal

/// The viewport-anchoring decision is a noisy boolean driving a visible scroll change, so it
/// is debounced. These pin the two properties that matter: a repaint's transient must not
/// release the anchor, and a genuine return to the shell must.
final class AnchorHysteresisTests: XCTestCase {

    func testTrueIsImmediate() {
        var h = AnchorHysteresis()
        XCTAssertTrue(h.update(raw: true), "an anchored grid anchors on the spot")
    }

    /// The bug this exists for: a TUI repaint walks the cursor below its content for a frame
    /// or two, and that must not move the viewport.
    func testShortFalseBurstsDoNotRelease() {
        var h = AnchorHysteresis()
        _ = h.update(raw: true)
        for i in 1..<AnchorHysteresis.releaseAfter {
            XCTAssertTrue(h.update(raw: false), "released after only \(i) false readings")
        }
    }

    /// A real return to the shell keeps reading false, and must release — otherwise the
    /// bottom clamp stays a fraction low and an empty prompt can scroll into dead space.
    func testSustainedFalseReleases() {
        var h = AnchorHysteresis()
        _ = h.update(raw: true)
        for _ in 0..<AnchorHysteresis.releaseAfter { _ = h.update(raw: false) }
        XCTAssertFalse(h.update(raw: false), "a sustained false must release the anchor")
    }

    /// One true reading re-arms the full budget: an interleaved repaint (false, false, true,
    /// false, …) never accumulates its way to a release.
    func testAnyTrueRearmsTheStreak() {
        var h = AnchorHysteresis()
        for _ in 0..<(AnchorHysteresis.releaseAfter * 3) {
            _ = h.update(raw: false)
            _ = h.update(raw: false)
            XCTAssertTrue(h.update(raw: true))
        }
        // Still holding after all that churn.
        XCTAssertTrue(h.update(raw: false))
    }

    /// An alt-screen transition is a real mode change; the new screen is judged fresh rather
    /// than coasting on the previous one's streak.
    func testResetJudgesTheNextReadingFresh() {
        var h = AnchorHysteresis()
        _ = h.update(raw: true)
        for _ in 0..<(AnchorHysteresis.releaseAfter - 1) { _ = h.update(raw: false) }
        h.reset()
        // The budget is whole again, so the next falses don't tip it over immediately.
        for _ in 1..<AnchorHysteresis.releaseAfter {
            XCTAssertTrue(h.update(raw: false))
        }
    }

    func testStartsUnanchoredUntilToldOtherwise() {
        var h = AnchorHysteresis()
        // A plain shell reads false from the first render and must not be anchored for long.
        var stillAnchored = 0
        for _ in 0..<(AnchorHysteresis.releaseAfter * 2) where h.update(raw: false) {
            stillAnchored += 1
        }
        XCTAssertEqual(stillAnchored, AnchorHysteresis.releaseAfter - 1,
                       "a never-anchored grid must settle to unanchored promptly")
    }
}
