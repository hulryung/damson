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

    func testLineAndColumnSuffix() {
        let t = tok("error: Sources/Foo.swift:42:7: bad", 8)
        XCTAssertEqual(t?.path, "Sources/Foo.swift")
        XCTAssertEqual(t?.line, 42)
        XCTAssertEqual(t?.column, 7)
        XCTAssertEqual(tok("Sources/Foo.swift:42: bad", 0)?.line, 42)
        XCTAssertNil(tok("Sources/Foo.swift:42: bad", 0)?.column)
        XCTAssertNil(tok("Sources/Foo.swift: bad", 0)?.line)
    }

    func testNonASCIIDigitsAreNotALine() {
        XCTAssertNil(tok("Sources/Foo.swift:４２", 0)?.line)
    }

    func testUnicodePath() {
        XCTAssertEqual(tok("열기 문서/설명.md 끝", 4)?.path, "문서/설명.md")
    }

    private func paths(_ s: String, _ col: Int) -> [String] {
        let chars = Array(s)
        return FilePathDetector.candidates(at: col, chars: chars, cols: Array(0..<chars.count)).map(\.path)
    }

    func testKoreanParticleAfterPath() {
        // The whole run comes first (a path may really end in Hangul); the particle-free
        // reading follows, for the caller to pick by existence.
        let s = "표는 docs/30_max_temperature_2026-11-26.md에 있습니다."
        XCTAssertEqual(paths(s, 5), ["docs/30_max_temperature_2026-11-26.md에",
                                     "docs/30_max_temperature_2026-11-26.md"])
        let t = FilePathDetector.candidates(at: 5, chars: Array(s), cols: Array(0..<s.count))
        XCTAssertEqual(t.last?.cols, 3..<40)
    }

    func testLongerParticleAndHangulPath() {
        XCTAssertEqual(paths("문서/설명.md에서 확인", 0),
                       ["문서/설명.md에서", "문서/설명.md에", "문서/설명.md"])
        // A period between path and particle: "README.md.입니다" is not expected, but
        // "foo/bar.swift입니다." must still shed the sentence dot first.
        XCTAssertEqual(paths("foo/bar.swift입니다.", 0).last, "foo/bar.swift")
    }

    func testClickOnParticleOpensNothingShorter() {
        // Probe on "에": only the whole run covers it.
        XCTAssertEqual(paths("docs/a.md에 있다", 9), ["docs/a.md에"])
    }

    func testNoHangulTailMeansOneCandidate() {
        XCTAssertEqual(paths("see docs/a.md now", 4), ["docs/a.md"])
    }
}
