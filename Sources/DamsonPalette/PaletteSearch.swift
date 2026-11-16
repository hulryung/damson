import Foundation

/// The command palette's matching and ordering, kept free of AppKit so it can be tested.
///
/// Every query word must appear in the title or the detail (menu path, cwd). Results are
/// ordered by how many words hit the title, then by whether the title starts with the
/// first word, then enabled before disabled, then catalogue order — so typing "split"
/// lists Split Right before a pane whose cwd happens to be `~/dev/split`.
public enum PaletteSearch {
    public struct Candidate: Equatable {
        public var title: String
        public var detail: String
        public var isEnabled: Bool
        public init(title: String, detail: String, isEnabled: Bool = true) {
            self.title = title
            self.detail = detail
            self.isEnabled = isEnabled
        }
    }

    /// Indices into `candidates`, matching `query`, best first.
    public static func rank(_ candidates: [Candidate], query: String) -> [Int] {
        let words = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
        let scored: [(index: Int, titleHits: Int, prefix: Bool, enabled: Bool)] =
            candidates.enumerated().compactMap { index, c in
                let title = fold(c.title), detail = fold(c.detail)
                var titleHits = 0
                for w in words {
                    if title.contains(w) { titleHits += 1 } else if !detail.contains(w) { return nil }
                }
                let prefix = words.first.map { startsWord(title, $0) } ?? false
                return (index, titleHits, prefix, c.isEnabled)
            }
        return scored.sorted { a, b in
            if a.titleHits != b.titleHits { return a.titleHits > b.titleHits }
            if a.prefix != b.prefix { return a.prefix }
            if a.enabled != b.enabled { return a.enabled }
            return a.index < b.index
        }.map(\.index)
    }

    /// `word` begins the title or one of its words ("pane" in "Pane: build", "Focus Pane Left").
    private static func startsWord(_ title: String, _ word: String) -> Bool {
        title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(word) }
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
