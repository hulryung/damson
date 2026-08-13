import XCTest
@testable import DamsonAgents

/// `AgentBadge` is the only place Claude Code's status vocabulary is written down, and it
/// is a vocabulary damson does not own. These pin the property that matters more than any
/// individual mapping: an unrecognized status must produce NO badge rather than a
/// neighbouring one. A stale "idle" pill on an agent that is actually blocked is worse
/// than no pill, because the user acts on it.
final class AgentBadgeTests: XCTestCase {

    func testKnownVocabularyMaps() {
        // Verified against Claude Code 2.1.228, read out of the CLI itself.
        XCTAssertEqual(AgentBadge(status: "busy"), .busy)
        XCTAssertEqual(AgentBadge(status: "shell"), .shell)
        XCTAssertEqual(AgentBadge(status: "idle"), .idle)
        XCTAssertEqual(AgentBadge(status: "waiting"), .waiting)
    }

    func testUnknownStatusProducesNoBadge() {
        // The forward-compatibility contract: a future release adding a state degrades to
        // quiet, never to wrong.
        for unknown in ["thinking", "paused", "compacting", "", "BUSY", "idle ", "unknown"] {
            XCTAssertNil(AgentBadge(status: unknown),
                         "\(unknown.debugDescription) must not map to a badge")
        }
    }

    func testOnlyWaitingAsksForAttention() {
        // Everything else is ambient. If more than one state escalated, the badges become
        // noise the user learns to ignore — and then misses the one that mattered.
        XCTAssertTrue(AgentBadge.waiting.isAttention)
        for quiet: AgentBadge in [.busy, .shell, .idle] {
            XCTAssertFalse(quiet.isAttention, "\(quiet) must stay quiet")
        }
    }

    func testEveryBadgeHasDistinctLabelAndSpokenForm() {
        let all: [AgentBadge] = [.busy, .shell, .idle, .waiting]
        XCTAssertEqual(Set(all.map(\.label)).count, all.count, "labels must be distinguishable")
        XCTAssertEqual(Set(all.map(\.describedAs)).count, all.count)
        for b in all {
            // VoiceOver reads `describedAs`; a glyph there would be useless.
            XCTAssertFalse(b.describedAs.isEmpty)
            XCTAssertFalse(b.label.isEmpty)
        }
    }
}
