import AppKit
import XCTest
@testable import DamsonTerminal

/// A display link that has gone silent must not keep reporting itself as running.
///
/// `NSView.displayLink(target:selector:)` documents that its callback "will not be invoked"
/// while the view is hidden or on no display — and it goes quiet WITHOUT invalidating itself.
/// Connecting an external monitor puts a window through exactly that state. Callers gate work
/// on `isRunning`, so a link stuck in it would never be restarted: the pane that owned it kept
/// accepting scroll deltas and never rendered them again, while a newly opened pane was fine.
///
/// These tests reproduce that state directly: a view belonging to no window is on no display,
/// so the link is created but never fires.
final class AnimationLinkTests: XCTestCase {

    /// Long enough to pass `AnimationLink.stallTimeout` (0.25s) with margin.
    private let pastStallTimeout: TimeInterval = 0.4

    /// Held for the test's duration: `AnimationLink` keeps only a weak reference, and a
    /// deallocated view makes `start` refuse outright — which would silently pass off as the
    /// behaviour under test.
    private var view: NSView!

    override func setUp() {
        super.setUp()
        view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    }

    override func tearDown() {
        view = nil
        super.tearDown()
    }

    private func makeLink() throws -> AnimationLink {
        let link = AnimationLink(view: view)
        guard link.start({ _ in false }) else {
            throw XCTSkip("no display link available (macOS < 14)")
        }
        return link
    }

    func testFreshLinkReportsRunning() throws {
        let link = try makeLink()
        defer { link.stop() }
        XCTAssertTrue(link.isRunning, "a link just created should be considered live")
    }

    func testSilentLinkStopsReportingRunning() throws {
        let link = try makeLink()
        defer { link.stop() }
        Thread.sleep(forTimeInterval: pastStallTimeout)
        XCTAssertFalse(link.isRunning,
                       "a link that has never called back must not read as running — "
                       + "that is what left a pane unable to scroll after a display change")
    }

    func testStartRebuildsASilentLink() throws {
        let link = try makeLink()
        defer { link.stop() }
        Thread.sleep(forTimeInterval: pastStallTimeout)
        XCTAssertFalse(link.isRunning)

        // Restarting has to replace the dead link, not adopt it. Adopting is the bug: the
        // caller believes it started a loop and no frames ever arrive.
        XCTAssertTrue(link.start({ _ in false }))
        XCTAssertTrue(link.isRunning, "start must rebuild a stalled link")
    }

    func testStopClearsRunning() throws {
        let link = try makeLink()
        link.stop()
        XCTAssertFalse(link.isRunning)
        // And a stopped link is not mistaken for a stalled one on the way back up.
        XCTAssertTrue(link.start({ _ in false }))
        XCTAssertTrue(link.isRunning)
        link.stop()
    }
}
