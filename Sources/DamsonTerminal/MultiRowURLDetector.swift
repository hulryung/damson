import Foundation

/// Detects plain-text URLs that SPAN MULTIPLE ROWS, joining rows around the probe
/// position before running NSDataDetector. Pure logic over an abstract row provider so
/// it's unit-testable without a view/grid.
///
/// Two kinds of row continuation are joined:
///
/// 1. **Soft wrap** (the row's `wrapped` flag): the terminal itself wrapped one logical
///    line across physical rows. Lossless — always joined, full row text.
///
/// 2. **TUI hard wrap**: a full-screen app (Claude Code etc.) printed a long URL across
///    several rows itself, usually indenting the continuation rows. There is no wrap
///    flag — the rows are separate logical lines — so joining is heuristic: the upper
///    row's trailing blanks and the lower row's leading indent are dropped. A join is only
///    considered when the upper row ran **flush to the right edge** (within 3 cells) — that
///    is the actual signature of a column wrap; a URL that ends mid-line (with trailing
///    blanks after it) was not wrapped and never joins. Given a flush upper row, the pair
///    is joined when it plausibly continues one token:
///      • the upper row's text ends in a "cut mid-URL" character (`/ - _ = & ? % + , .`), or
///      • the lower row's first token carries URL structure (`/ ? = & # % ~`), or
///      • the lower row's first token is long (≥ 8 chars).
///    Ordinary prose ("…see https://a.com" / "    and then…") fails the flush check or all
///    three token rules, so a complete URL that merely ends a line doesn't swallow the next
///    line's words.
enum MultiRowURLDetector {
    /// One row's text content for detection: characters (continuation/wide-spacer cells
    /// excluded), each character's starting column, and the soft-wrap flag.
    struct RowData {
        var chars: [Character]
        var cols: [Int]
        var wrapped: Bool
    }

    /// A detected URL plus, per touched row, the column range it occupies (for hover).
    struct Match {
        var url: URL
        var segments: [(row: Int, cols: Range<Int>)]
    }

    /// Max rows joined in each direction — bounds work and absurd joins (≈ 8×cols chars).
    private static let maxChain = 8

    /// Probe for a URL at (row, col). `rowAt` returns nil for out-of-range rows.
    static func match(
        at row: Int, col: Int,
        totalCols: Int,
        rowAt: (Int) -> RowData?
    ) -> Match? {
        guard let probe = rowAt(row) else { return nil }
        _ = probe

        // 1. Decide the chain of joined rows around the probe row.
        var start = row
        while row - start < maxChain,
              let upper = rowAt(start - 1), let lower = rowAt(start),
              joins(upper: upper, lower: lower, totalCols: totalCols) {
            start -= 1
        }
        var end = row
        while end - row < maxChain,
              let upper = rowAt(end), let lower = rowAt(end + 1),
              joins(upper: upper, lower: lower, totalCols: totalCols) {
            end += 1
        }

        // 2. Build the joined text with a per-character (row, col) map. At a soft
        //    boundary the upper row contributes everything; at a hard boundary the
        //    upper row is trimmed of trailing blanks and the lower of leading blanks.
        var text = ""
        var pos: [(row: Int, col: Int)] = []
        for r in start...end {
            guard let data = rowAt(r) else { continue }
            var lo = 0
            var hi = data.chars.count
            let hardFromPrev = r > start && !(rowAt(r - 1)?.wrapped ?? false)
            let hardToNext = r < end && !data.wrapped
            if hardFromPrev {
                while lo < hi, data.chars[lo] == " " { lo += 1 }
            }
            if hardToNext || r == end {
                while hi > lo, data.chars[hi - 1] == " " { hi -= 1 }
            }
            guard lo < hi else { continue }
            for i in lo..<hi {
                text.append(data.chars[i])
                pos.append((r, data.cols[i]))
            }
        }
        guard !text.isEmpty else { return nil }

        // 3. The probe position's character index (the char at or just before `col` on
        //    the probe row — covers clicking the trailing cell of a wide char).
        var probeIndex: Int?
        for (i, p) in pos.enumerated() where p.row == row && p.col <= col {
            probeIndex = i
        }
        guard let charIndex = probeIndex else { return nil }

        // 4. Detect and pick the match containing the probe.
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return nil }
        // NSRange is UTF-16-based; our index is in Characters. Map through the string.
        let chars = Array(text)
        for m in detector.matches(in: text, options: [],
                                  range: NSRange(text.startIndex..<text.endIndex, in: text)) {
            guard let r = Range(m.range, in: text), let url = m.url else { continue }
            let mStart = text.distance(from: text.startIndex, to: r.lowerBound)
            let mEnd = text.distance(from: text.startIndex, to: r.upperBound)
            guard mStart <= charIndex, charIndex < mEnd else { continue }
            _ = chars
            // 5. Map the match back to per-row column segments.
            var segments: [(row: Int, cols: Range<Int>)] = []
            var i = mStart
            while i < mEnd {
                let segRow = pos[i].row
                let lower = pos[i].col
                var upper = pos[i].col
                while i < mEnd, pos[i].row == segRow {
                    upper = pos[i].col
                    i += 1
                }
                segments.append((segRow, lower..<(upper + 1)))
            }
            return Match(url: url, segments: segments)
        }
        return nil
    }

    /// Should `lower` be treated as a continuation of `upper`?
    private static func joins(upper: RowData, lower: RowData, totalCols: Int) -> Bool {
        if upper.wrapped { return true }   // soft wrap — lossless
        // Hard (TUI) wrap heuristics.
        var hi = upper.chars.count
        while hi > 0, upper.chars[hi - 1] == " " { hi -= 1 }
        guard hi > 0 else { return false }
        let lastChar = upper.chars[hi - 1]
        let lastCol = upper.cols[hi - 1]
        // A hard wrap only happens when the upper row was actually FULL — its last non-blank
        // cell must sit at (within a couple cells of) the right edge. A URL that ends
        // mid-line (trailing blanks after it) was NOT wrapped, so it never swallows the next
        // line, even when it ends in a "cut" char like '/'. (Fixes a trailing-'/' URL pulling
        // in the following line's leading '-'.)
        guard lastCol >= totalCols - 3 else { return false }

        var lo = 0
        while lo < lower.chars.count, lower.chars[lo] == " " { lo += 1 }
        guard lo < lower.chars.count else { return false }
        var token = ""
        var t = lo
        while t < lower.chars.count, lower.chars[t] != " " { token.append(lower.chars[t]); t += 1 }
        guard !token.isEmpty, !token.contains("://") else { return false }

        if "/-_=&?%+,.".contains(lastChar) { return true }
        if token.contains(where: { "/?=&#%~".contains($0) }) { return true }
        if token.count >= 8 { return true }
        return false
    }
}
