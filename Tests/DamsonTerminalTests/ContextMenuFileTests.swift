import XCTest
@testable import DamsonTerminal

final class ContextMenuFileTests: XCTestCase {
    func testEncodedLocalFileAndMissingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("한글 file.txt")
        try Data().write(to: file)
        let uri = try XCTUnwrap(URL(string: file.absoluteString))
        XCTAssertEqual(ContextMenuFile.localURL(uri)?.path, file.path)
        XCTAssertNotNil(ContextMenuFile.localURL(directory))
        try FileManager.default.removeItem(at: file)
        XCTAssertNil(ContextMenuFile.localURL(uri))
    }

    func testRemoteFileMustNotResolveToLocalRoot() throws {
        XCTAssertNil(ContextMenuFile.localURL(try XCTUnwrap(URL(string: "file://remote.example/"))))
        XCTAssertNil(ContextMenuFile.localURL(try XCTUnwrap(URL(string: "https://example.com/"))))
        XCTAssertNotNil(ContextMenuFile.localURL(try XCTUnwrap(URL(string: "file://localhost/"))))
    }

    func testFileURIWithHangulAndEncodedSpacesAtEveryCell() throws {
        let text = "file:///tmp/한글%20file.txt"
        var cells = [Cell(char: "(", attrs: CellAttrs(fg: .default))]
        for char in text {
            cells.append(Cell(char: char, attrs: CellAttrs(fg: .default)))
            if Cell.isWide(char) {
                cells.append(Cell(char: " ", attrs: CellAttrs(fg: .default), isContinuation: true))
            }
        }
        let end = cells.count
        cells.append(Cell(char: ")", attrs: CellAttrs(fg: .default)))
        for col in 1..<end {
            let match = try XCTUnwrap(ContextMenuFile.uri(at: col, cells: cells))
            XCTAssertEqual(match.url.path, "/tmp/한글 file.txt")
            XCTAssertEqual(match.cols, 1..<end)
        }
        XCTAssertNil(ContextMenuFile.uri(at: 0, cells: cells))
        XCTAssertNil(ContextMenuFile.uri(at: end, cells: cells))
    }
}
