import DamsonTerminal
import XCTest
@testable import DamsonAgents

/// Pane ids exist so something outside damson can name a pane and still be right a minute
/// later, after splits, closes, reorders and cross-window drags have renumbered everything.
/// So the tests are about identity surviving churn — and about the one way this class could
/// be silently, dangerously wrong: handing a NEW pane a DEAD pane's id.
final class PaneRegistryTests: XCTestCase {
    private var registry: PaneRegistry!

    override func setUp() {
        super.setUp()
        registry = PaneRegistry.shared
        registry.resetForTesting()
    }

    override func tearDown() {
        registry.resetForTesting()
        super.tearDown()
    }

    /// A backend that starts nothing. The registry keys on session IDENTITY only, so these
    /// tests need hundreds of sessions and zero processes — injecting this is what makes
    /// that possible (the real `PTYHost` would fork a shell for every one).
    private final class InertBackend: SessionIOBackend {
        var onData: ((Data) -> Void)?
        var onExit: ((Int32) -> Void)?
        func spawn(argv: [String], env: [String: String], cwd: String?, cols: Int, rows: Int) throws {}
        func write(_ data: Data) {}
        func resize(cols: Int, rows: Int) {}
        func terminate() {}
        var childWorkingDirectory: String? { nil }
        var isRunningForegroundJob: Bool { false }
    }

    private func makeSession() -> DamsonSession {
        DamsonSession(config: DamsonConfig(), backend: InertBackend())
    }

    func testMintsOnceAndIsStableForTheSameSession() {
        let s = makeSession()
        let id = registry.id(for: s)
        XCTAssertEqual(registry.id(for: s), id)
        XCTAssertEqual(registry.id(for: s), id)
        XCTAssertTrue(registry.session(for: id) === s)
    }

    func testDistinctSessionsGetDistinctIDs() {
        let a = makeSession(), b = makeSession()
        XCTAssertNotEqual(registry.id(for: a), registry.id(for: b))
    }

    func testExistingIDDoesNotMint() {
        let s = makeSession()
        XCTAssertNil(registry.existingID(for: s))
        let id = registry.id(for: s)
        XCTAssertEqual(registry.existingID(for: s), id)
    }

    /// The property the whole class exists for: an id is bound to the pane, not to where it
    /// sits, so churning many other panes around it changes nothing.
    func testIDSurvivesHeavyChurn() {
        let tracked = makeSession()
        let id = registry.id(for: tracked)
        var others: [DamsonSession] = []
        for _ in 0..<60 {
            let s = makeSession()
            registry.id(for: s)
            others.append(s)
        }
        others.removeAll()               // simulate a wave of pane closes
        for _ in 0..<60 { registry.id(for: makeSession()) }
        XCTAssertEqual(registry.id(for: tracked), id)
        XCTAssertTrue(registry.session(for: id) === tracked)
    }

    func testClosedPaneStopsResolving() {
        var doomedID = UUID()
        autoreleasepool {
            let doomed = makeSession()
            doomedID = registry.id(for: doomed)
            XCTAssertNotNil(registry.session(for: doomedID))
        }
        // Force the opportunistic sweep.
        for _ in 0..<80 { registry.id(for: makeSession()) }
        XCTAssertNil(registry.session(for: doomedID), "a closed pane must not resolve")
    }

    /// The trap this class is written around. The forward map is keyed on
    /// `ObjectIdentifier`, which is the object's ADDRESS — and a deallocated session's
    /// address is reused by a later allocation. Pruning that map in place would eventually
    /// hand a brand-new pane the id of a pane that is long gone, and a driver addressing
    /// "pane X" would silently talk to the wrong terminal.
    func testFreshPaneNeverInheritsAClosedPanesID() {
        var deadIDs: Set<UUID> = []
        autoreleasepool {
            var doomed: [DamsonSession] = []
            for _ in 0..<40 {
                let s = makeSession()
                deadIDs.insert(registry.id(for: s))
                doomed.append(s)
            }
            doomed.removeAll()
        }
        for _ in 0..<120 {
            let fresh = makeSession()
            XCTAssertFalse(deadIDs.contains(registry.id(for: fresh)),
                           "a new pane inherited a closed pane's id — address reuse was not handled")
        }
    }

    /// How a restored layout reattaches a saved id, so an external binding survives a restart.
    func testAdoptBindsASavedID() {
        let s = makeSession()
        let saved = UUID()
        registry.adopt(s, as: saved)
        XCTAssertEqual(registry.id(for: s), saved)
        XCTAssertTrue(registry.session(for: saved) === s)
    }

    func testAdoptWillNotStealALiveID() {
        let owner = makeSession()
        let id = registry.id(for: owner)
        let intruder = makeSession()
        registry.adopt(intruder, as: id)
        XCTAssertTrue(registry.session(for: id) === owner, "a live id must not be reassigned")
        XCTAssertNotEqual(registry.id(for: intruder), id)
    }
}
