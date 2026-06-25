import XCTest
@testable import DamsonTerminal

final class FilePathDetectorTests: XCTestCase {
    private func tok(_ s: String, _ col: Int) -> FilePathDetector.Token? {
        let chars = Array(s)
        return FilePathDetector.token(at: col, chars: chars, cols: Array(0..<chars.count))
    }

    func testPathInsideParens() {
        // "Update(docs/DESIGN.md)" — cursor anywhere within the path token.
        let line = "Update(docs/DESIGN.md)"
        for col in [7, 11, 14, 19] {
            XCTAssertEqual(tok(line, col)?.path, "docs/DESIGN.md", "col \(col)")
        }
    }

    func testWordIsNotAPath() {
        XCTAssertNil(tok("Update(docs/DESIGN.md)", 0))   // 'Update'
        XCTAssertNil(tok("hello world", 0))
    }

    func testAbsolutePath() {
        let s = "see /Users/x/main.swift now"
        XCTAssertEqual(tok(s, s.distance(from: s.startIndex, to: s.firstIndex(of: "U")!))?.path,
                       "/Users/x/main.swift")
    }

    func testLineNumberSuffix() {
        let s = "at Sources/Foo.swift:42 ok"
        let t = tok(s, 3)
        XCTAssertEqual(t?.path, "Sources/Foo.swift")
        XCTAssertEqual(t?.line, 42)
    }

    func testBareFilenameWithExtension() {
        XCTAssertEqual(tok("open README.md please", 5)?.path, "README.md")
        XCTAssertNil(tok("just a word here", 7))       // 'word' — no extension/sep
    }

    func testTrailingPeriodTrimmed() {
        let s = "edit foo/bar.swift."
        XCTAssertEqual(tok(s, 5)?.path, "foo/bar.swift")
    }

    func testRelativeAndHomePrefixes() {
        XCTAssertEqual(tok("./build/run.sh", 2)?.path, "./build/run.sh")
        XCTAssertEqual(tok("~/notes.txt", 0)?.path, "~/notes.txt")
    }
}
