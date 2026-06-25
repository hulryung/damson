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
        guard let idx = cols.firstIndex(of: col), idx < chars.count else { return nil }
        guard isPathChar(chars[idx]) else { return nil }

        var lo = idx, hi = idx
        while lo > 0, isPathChar(chars[lo - 1]) { lo -= 1 }
        while hi + 1 < chars.count, isPathChar(chars[hi + 1]) { hi += 1 }

        // Trim a trailing '.' (sentence punctuation) so "see foo/bar.swift." doesn't include the dot.
        while hi > lo, chars[hi] == "." { hi -= 1 }

        let token = String(chars[lo...hi])
        guard looksLikePath(token) else { return nil }

        // Optional ":NN" line number immediately after the token (also accepts ":NN:CC").
        var line: Int?
        if hi + 1 < chars.count, chars[hi + 1] == ":" {
            var j = hi + 2
            var digits = ""
            while j < chars.count, chars[j].isNumber { digits.append(chars[j]); j += 1 }
            if !digits.isEmpty { line = Int(digits) }
        }

        return Token(path: token, line: line, cols: cols[lo]..<(cols[hi] + 1))
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
