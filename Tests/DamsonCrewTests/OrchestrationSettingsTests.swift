import XCTest
@testable import DamsonCrew

/// The settings UI and the CLI are separate processes writing and reading the same keys. A
/// mismatch fails silently — the CLI just never sees anything the user changed — so the
/// defaults, the fallbacks and the key names are all pinned here.
final class OrchestrationSettingsTests: XCTestCase {

    private var domain: String!
    private var defaults: UserDefaults!

    override func setUp() {
        domain = "damson.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: domain)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: domain)
    }

    /// A coordinator has to run whether or not the app has ever been opened to write a
    /// preference, so an empty domain must give the documented defaults rather than nothing.
    func testAnEmptyDomainGivesTheDefaults() {
        let s = OrchestrationSettings.load(domain: domain)
        XCTAssertEqual(s, .default)
        XCTAssertEqual(s.agentCommand, ["claude"])
        XCTAssertTrue(s.skipPermissions, "skipping permission prompts is the default")
        XCTAssertTrue(s.notifyOnWaiting)
        XCTAssertFalse(s.focusOnWaiting)
    }

    /// `bool(forKey:)` returns false for a missing key, so a plain read would turn every
    /// unset toggle off — silently flipping two defaults the moment someone set any one of
    /// the others.
    func testAnUnsetToggleKeepsItsDefaultRatherThanBecomingFalse() {
        defaults.set("codex", forKey: OrchestrationSettings.Keys.agentCommand)
        let s = OrchestrationSettings.load(domain: domain)
        XCTAssertEqual(s.agentCommand, ["codex"])
        XCTAssertTrue(s.skipPermissions, "an unset toggle was read as off")
        XCTAssertTrue(s.notifyOnWaiting, "an unset toggle was read as off")
    }

    func testStoredValuesAreRead() {
        defaults.set("claude --model opus", forKey: OrchestrationSettings.Keys.agentCommand)
        defaults.set(false, forKey: OrchestrationSettings.Keys.skipPermissions)
        defaults.set(true, forKey: OrchestrationSettings.Keys.focusOnWaiting)
        defaults.set("/tmp/trees", forKey: OrchestrationSettings.Keys.worktreeRoot)

        let s = OrchestrationSettings.load(domain: domain)
        XCTAssertEqual(s.agentCommand, ["claude", "--model", "opus"])
        XCTAssertFalse(s.skipPermissions)
        XCTAssertTrue(s.focusOnWaiting)
        XCTAssertEqual(s.worktreeRoot, "/tmp/trees")
    }

    /// A blank command field must not produce an empty argv — that is a spawn with nothing
    /// to run, which damson rejects and which would look like the setting had broken.
    func testABlankCommandFallsBackToTheDefault() {
        for raw in ["", "   "] {
            defaults.set(raw, forKey: OrchestrationSettings.Keys.agentCommand)
            XCTAssertEqual(OrchestrationSettings.load(domain: domain).agentCommand, ["claude"])
        }
    }
}
