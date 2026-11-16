import XCTest
@testable import DamsonTabGroups

/// Workspace presets (#46): the file is versioned, a layout round-trips with its ratios,
/// folders and tab names, and opening one never carries a command, keeper session, pane id
/// or scrollback — even from an edited file.
final class WorkspacePresetTests: XCTestCase {
    private func leaf(_ cwd: String?, zoom: Double? = nil) -> RestorablePane {
        .leaf(cwd: cwd, scrollbackID: nil, sessionID: nil, preamble: nil, fontZoom: zoom)
    }

    private var sample: RestorableWindow {
        RestorableWindow(
            tabs: [
                .split(direction: "horizontal", ratio: 0.2,
                       first: leaf("/src/api"),
                       second: .split(direction: "vertical", ratio: 0.75,
                                      first: leaf("/src/web", zoom: 1.25), second: leaf("/tmp"))),
                leaf("/src/docs"),
            ],
            selectedTab: 1, tabTitles: ["servers", nil])
    }

    func testRoundTripPreservesRatiosDirectoriesAndTitles() throws {
        let presets = [WorkspacePreset(name: "Project", window: sample)]
        let decoded = try WorkspacePresetFile.decode(WorkspacePresetFile.encode(presets))
        XCTAssertEqual(decoded, presets)
        XCTAssertEqual(decoded[0].window.tabs[0].directories, ["/src/api", "/src/web", "/tmp"])
        XCTAssertEqual(decoded[0].window.tabTitles ?? [], ["servers", nil])
    }

    func testFileIsVersioned() throws {
        let json = try JSONSerialization.jsonObject(with: WorkspacePresetFile.encode([])) as? [String: Any]
        XCTAssertEqual(json?["version"] as? Int, WorkspacePresetFile.currentVersion)
    }

    func testNewerVersionIsReportedEvenWhenItsShapeChanged() {
        let newer = Data(#"{"version": 2, "workspaces": {"a": 1}}"#.utf8)
        XCTAssertThrowsError(try WorkspacePresetFile.decode(newer)) {
            XCTAssertEqual($0 as? WorkspacePresetFile.LoadError, .newerVersion(2))
        }
    }

    func testCorruptOrForeignFilesAreUnreadable() {
        for text in ["not json", "[]", #"{"presets": []}"#, #"{"version": 0, "presets": []}"#,
                     #"{"version": 1, "presets": [{"name": "x"}]}"#] {
            XCTAssertThrowsError(try WorkspacePresetFile.decode(Data(text.utf8)), text) {
                XCTAssertEqual($0 as? WorkspacePresetFile.LoadError, .unreadable, text)
            }
        }
    }

    func testFreshWorkspaceStripsEverythingThatWouldReplayOrReattach() {
        let edited = RestorablePane.split(
            direction: "sideways", ratio: .nan,
            first: .leaf(cwd: "/a", scrollbackID: "sb", sessionID: "keeper", preamble: "AAAA",
                         paneID: UUID().uuidString, argv: ["rm", "-rf", "/"], fontZoom: 2),
            second: .split(direction: "vertical", ratio: 7, first: leaf("/b"), second: leaf("/c")))
        XCTAssertEqual(edited.freshWorkspace, .split(
            direction: "horizontal", ratio: 0.5,
            first: leaf("/a", zoom: 2),
            second: .split(direction: "vertical", ratio: 0.95, first: leaf("/b"), second: leaf("/c"))))
    }

    func testFreshWorkspaceKeepsRatiosADividerDragCanProduce() {
        let pane = RestorablePane.split(direction: "horizontal", ratio: 0.07, first: leaf("/a"), second: leaf("/b"))
        guard case .split(_, let ratio, _, _) = pane.freshWorkspace else { return XCTFail() }
        XCTAssertEqual(ratio, 0.07)
    }

    func testFreshWindowRepairsTitlesSelectionAndRole() {
        var w = sample
        w.selectedTab = 9
        w.tabTitles = ["only one"]
        w.quickTerminal = true
        w.quickTerminalHidden = true
        let fresh = w.freshWorkspace
        XCTAssertEqual(fresh.selectedTab, 0)
        XCTAssertEqual(fresh.tabTitles ?? [], ["only one", nil])
        XCTAssertNil(fresh.quickTerminal)
        XCTAssertNil(fresh.quickTerminalHidden)
    }

    func testUpsertReplacesSameNameCaseInsensitivelyAndKeepsIdentity() {
        var presets = [WorkspacePreset(name: "API", window: sample)]
        let id = presets[0].id
        let replacement = RestorableWindow(tabs: [leaf("/new")], selectedTab: 0)
        XCTAssertTrue(presets.upsert(name: "  api ", window: replacement))
        XCTAssertEqual(presets.count, 1)
        XCTAssertEqual(presets[0].id, id)
        XCTAssertEqual(presets[0].name, "api")
        XCTAssertEqual(presets[0].window, replacement)
        XCTAssertFalse(presets.upsert(name: "Docs", window: sample))
        XCTAssertEqual(presets.map(\.name), ["api", "Docs"])
    }

    /// A session-restore blob from before the quick-terminal fields must still decode, and an
    /// ordinary window must encode without them (so older builds read it unchanged).
    func testWindowWithoutQuickTerminalFieldsIsUnchanged() throws {
        let old = Data(#"{"tabs":[{"leaf":{"cwd":"/a"}}],"selectedTab":0}"#.utf8)
        let w = try JSONDecoder().decode(RestorableWindow.self, from: old)
        XCTAssertNil(w.quickTerminal)
        let text = String(decoding: try JSONEncoder().encode(w), as: UTF8.self)
        XCTAssertFalse(text.contains("quickTerminal"))
    }
}
