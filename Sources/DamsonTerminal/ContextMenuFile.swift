import Foundation

/// Finder actions require an existing local file, never a remote file URI whose
/// path happens to also exist on this Mac. Keep the original URI for copying.
enum ContextMenuFile {
    /// NSDataDetector's web-link rules trim Hangul; file URIs need to preserve it.
    static func uri(at col: Int, cells: [Cell]) -> (url: URL, cols: Range<Int>)? {
        guard cells.indices.contains(col) else { return nil }
        func delimiter(_ c: Cell) -> Bool {
            !c.isContinuation && (c.char.isWhitespace || "\"'<>[]()".contains(c.char))
        }
        guard !delimiter(cells[col]) else { return nil }
        var start = col
        var end = col + 1
        while start > 0 && !delimiter(cells[start - 1]) { start -= 1 }
        while end < cells.count && !delimiter(cells[end]) { end += 1 }
        let text = String(cells[start..<end].filter { !$0.isContinuation && !$0.isWideSpacer }.map(\.char))
        guard text.lowercased().hasPrefix("file://"), let url = parseURI(text) else { return nil }
        return (url, start..<end)
    }

    static func parseURI(_ text: String) -> URL? {
        // Encode Unicode without double-encoding existing percent escapes.
        let allowed = CharacterSet.urlFragmentAllowed.union(CharacterSet(charactersIn: "%#[]"))
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: encoded)
    }

    static func localURL(_ url: URL) -> URL? {
        guard url.isFileURL,
              url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
              !url.path.isEmpty else { return nil }
        let local = URL(fileURLWithPath: url.path).standardizedFileURL
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }
}
