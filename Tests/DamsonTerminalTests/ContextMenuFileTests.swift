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

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctx \(UUID().uuidString) 한글")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testFileURIWithLineAndColumnSuffix() throws {
        let directory = try makeDirectory()
        let file = directory.appendingPathComponent("main file.swift")
        try Data("x".utf8).write(to: file)
        let base = file.absoluteString
        let located = try XCTUnwrap(ContextMenuFile.location(for: XCTUnwrap(URL(string: base + ":12:5"))))
        XCTAssertEqual(located.url.path, file.standardizedFileURL.path)
        XCTAssertEqual(located.line, 12)
        XCTAssertEqual(located.column, 5)
        XCTAssertEqual(ContextMenuFile.location(for: try XCTUnwrap(URL(string: base + ":3")))?.line, 3)
        XCTAssertNil(try XCTUnwrap(ContextMenuFile.location(for: file)).line)
        XCTAssertNil(ContextMenuFile.location(for: try XCTUnwrap(URL(string: base + ":x"))))
        XCTAssertNil(ContextMenuFile.location(for: try XCTUnwrap(URL(string: base + ":1:2:3"))))
        XCTAssertNil(ContextMenuFile.location(for: directory.appendingPathComponent("gone.swift:4")))
    }

    func testFileNamedWithColonSuffixWinsOverLineSplit() throws {
        let directory = try makeDirectory()
        let odd = directory.appendingPathComponent("log:12")
        try Data().write(to: odd)
        let located = try XCTUnwrap(ContextMenuFile.location(for: odd))
        XCTAssertEqual(located.url.lastPathComponent, "log:12")
        XCTAssertNil(located.line)
    }

    func testPercentEncodedURIWithSuffix() throws {
        let directory = try makeDirectory()
        let file = directory.appendingPathComponent("a b.txt")
        try Data().write(to: file)
        let text = "file://" + file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + ":9"
        let url = try XCTUnwrap(ContextMenuFile.parseURI(text))
        XCTAssertEqual(ContextMenuFile.location(for: url)?.line, 9)
        XCTAssertEqual(ContextMenuFile.location(for: url)?.url.lastPathComponent, "a b.txt")
    }

    func testRelativePathsResolveAgainstPaneDirectory() throws {
        let directory = try makeDirectory()
        let sub = directory.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = sub.appendingPathComponent("설명.md")
        try Data().write(to: file)
        let expected = file.standardizedFileURL.path
        XCTAssertEqual(ContextMenuFile.resolve(path: "Sources/설명.md", cwd: directory.path)?.path, expected)
        XCTAssertEqual(ContextMenuFile.resolve(path: "./Sources/설명.md", cwd: directory.path)?.path, expected)
        XCTAssertEqual(ContextMenuFile.resolve(path: "../Sources/설명.md", cwd: sub.path)?.path, expected)
        XCTAssertEqual(ContextMenuFile.resolve(path: file.path, cwd: nil)?.path, expected)
        XCTAssertNil(ContextMenuFile.resolve(path: "Sources/설명.md", cwd: nil))
        XCTAssertNil(ContextMenuFile.resolve(path: "Sources/missing.md", cwd: directory.path))
        XCTAssertNil(ContextMenuFile.resolve(path: "~nobody-here/x", cwd: directory.path))
        XCTAssertEqual(ContextMenuFile.resolve(path: "~", cwd: nil)?.path,
                       URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path)
    }

    func testEditorOnlyForTextLikeFiles() throws {
        let directory = try makeDirectory()
        func write(_ name: String, _ bytes: [UInt8]) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data(bytes).write(to: url)
            return url
        }
        XCTAssertTrue(ContextMenuFile.isLikelyText(try write("main.swift", [0x61])))
        XCTAssertTrue(ContextMenuFile.isLikelyText(try write("Makefile", Array("all:\n".utf8))))
        XCTAssertTrue(ContextMenuFile.isLikelyText(try write("notes.zzunknown", Array("hi".utf8))))
        XCTAssertFalse(ContextMenuFile.isLikelyText(try write("tool", [0xCF, 0xFA, 0xED, 0xFE, 0, 0])))
        XCTAssertFalse(ContextMenuFile.isLikelyText(try write("image.png", [0x89, 0x50])))
        XCTAssertFalse(ContextMenuFile.isLikelyText(directory))
        XCTAssertFalse(ContextMenuFile.isLikelyText(directory.appendingPathComponent("missing.txt")))
    }
}
