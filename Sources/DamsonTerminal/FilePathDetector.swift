import Foundation

/// Detects a file-path token under a probe column in a single row of terminal text, so a
/// path printed by a tool (e.g. Claude Code's `⏺ Update(docs/DESIGN.md)`, `Sources/x.swift`,
/// `/abs/p.txt`, `file.swift:42`) can be Cmd-clicked to open.
///
/// Pure logic over a row's characters — the view resolves the token against the session cwd
/// and checks existence (so only real files become clickable). Single-row only: paths almost
/// never wrap, and keeping it single-row avoids the false joins URLs need `MultiRowURLDetector` for.
enum FilePathDetector {
    struct Token: Equatable {
        var path: String        // the path token (without any :line suffix)
        var line: Int?          // trailing ":NN" line number, if present
        var column: Int? = nil  // trailing ":NN:CC" column, if present
        var cols: Range<Int>    // columns the path token occupies (excludes :line)
    }

    /// Characters that make up a path token. Stops at whitespace, quotes, parens/brackets,
    /// `:` (handled separately as a line suffix), etc. — the delimiters around a path.
    static func isPathChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || "._/~+-@%".contains(c)
    }

    /// Extract the path token under `col`. `chars[i]` sits at column `cols[i]` (continuation
    /// and wide-spacer cells already excluded by the caller). Returns nil if the cell isn't
    /// on something that looks like a path.
    static func token(at col: Int, chars: [Character], cols: [Int]) -> Token? {
        candidates(at: col, chars: chars, cols: cols).first
    }

    /// Longest Hangul tail tried as a glued-on particle ("에서는", "입니다만", …).
    private static let maxParticle = 6

    /// Every reading of the token under `col`, longest first; the caller takes the first
    /// that exists on disk.
    ///
    /// The first is the whole run of path characters. Hangul is a letter, and a real path
    /// may contain it ("문서/설명.md"), but Korean also glues particles onto the word before
    /// them with no space — "docs/report.md에 있습니다" — so the whole run names a file that
    /// is not there. Only the filesystem can tell the two apart, so the rest are the same
    /// run with its Hangul tail shortened one character at a time ("설명.md에서" → "설명.md에"
    /// → "설명.md"). A shortened reading that no longer covers `col` is dropped: clicking the
    /// particle itself opens nothing.
    static func candidates(at col: Int, chars: [Character], cols: [Int]) -> [Token] {
        guard let idx = cols.firstIndex(of: col), idx < chars.count else { return [] }
        guard isPathChar(chars[idx]) else { return [] }

        var lo = idx, hi = idx
        while lo > 0, isPathChar(chars[lo - 1]) { lo -= 1 }
        while hi + 1 < chars.count, isPathChar(chars[hi + 1]) { hi += 1 }

        // Optional ":NN" line number immediately after the token (also accepts ":NN:CC").
        // Only ASCII digits: `isNumber` also accepts e.g. "½" and full-width digits.
        func number(after colon: Int) -> (value: Int, end: Int)? {
            guard colon < chars.count, chars[colon] == ":" else { return nil }
            var j = colon + 1
            var digits = ""
            while j < chars.count, chars[j].isASCII, chars[j].isNumber { digits.append(chars[j]); j += 1 }
            return Int(digits).map { ($0, j) }
        }
        func make(_ end: Int) -> Token? {
            var hi = end
            // Trim a trailing '.' (sentence punctuation) so "see foo/bar.swift." doesn't include the dot.
            while hi > lo, chars[hi] == "." { hi -= 1 }
            guard idx <= hi else { return nil }
            let token = String(chars[lo...hi])
            guard looksLikePath(token) else { return nil }
            let line = number(after: hi + 1)
            let column = line.flatMap { number(after: $0.end) }
            return Token(path: token, line: line?.value, column: column?.value, cols: cols[lo]..<(cols[hi] + 1))
        }

        var result = make(hi).map { [$0] } ?? []
        // The particle may itself be followed by the sentence's dot: "foo.swift입니다."
        while hi > lo, chars[hi] == "." { hi -= 1 }
        var end = hi
        while end > lo, hi - end < maxParticle, MultiRowURLDetector.isHangul(chars[end]) {
            end -= 1
            if let t = make(end), t != result.last { result.append(t) }
        }
        return result
    }

    /// A token is path-ish if it has a separator, a home/relative prefix, or a short extension.
    /// This gates the (filesystem) existence check the view does, so plain words are ignored.
    static func looksLikePath(_ t: String) -> Bool {
        if t.hasPrefix("/") || t.hasPrefix("~/") || t.hasPrefix("./") || t.hasPrefix("../") { return true }
        if t.contains("/") { return true }
        // Bare filename with a short alphanumeric extension, e.g. README.md, main.swift.
        if let dot = t.lastIndex(of: "."), dot != t.startIndex, t.index(after: dot) != t.endIndex {
            let ext = t[t.index(after: dot)...]
            return ext.count <= 8 && ext.allSatisfy { $0.isLetter || $0.isNumber }
        }
        return false
    }
}
