import DamsonControl
import XCTest
@testable import DamsonCrew

final class ResolvingDamsonClientTests: XCTestCase {
    func testFocusAndLookupFollowTheNewSocketAfterRestart() throws {
        var socket = "old.sock"
        var destinations: [String] = []
        let client = ResolvingDamsonClient(resolve: { .success(socket) }) { path, kind, _ in
            destinations.append(path)
            if case .paneInfo = kind {
                return .success(.pane(PaneInfo(index: 0, cols: 80, rows: 24,
                                               active: false, id: "A", tab: 1)))
            }
            return .success(.panes([]))
        }
        _ = try client.send(.listAgents).get()
        socket = "new.sock"
        XCTAssertNil(PaneFocuser(client: client).reveal(paneID: "A"))
        _ = Coordinator(client: client).reattach([CrewTask(name: "review")])
        XCTAssertEqual(destinations, ["old.sock", "new.sock", "new.sock"])
    }

    func testFailedRequestsAreNotAutomaticallyReplayed() {
        var calls = 0
        let client = ResolvingDamsonClient(resolve: { .success("app.sock") }) { _, _, _ in
            calls += 1
            return .failure(CrewError("timeout"))
        }
        XCTAssertThrowsError(try client.send(.closeGroup("run")).get())
        XCTAssertEqual(calls, 1)
    }

    func testDiscoveryFailureDoesNotSendARequest() {
        let client = ResolvingDamsonClient(resolve: { .failure(CrewError("no instance")) }) { _, _, _ in
            XCTFail("transport called without a destination")
            return .success(.ok())
        }
        XCTAssertThrowsError(try client.send(.listAgents).get())
    }
}
