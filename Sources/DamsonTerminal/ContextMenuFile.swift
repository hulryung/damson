import Foundation
import UniformTypeIdentifiers

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

    /// The local file a file URI names, plus a `:line[:col]` suffix that compilers and
    /// grep print after it (`file:///x/main.swift:12:5`). The suffix is only split off
    /// when the whole path does not exist, so a file whose name ends in `:12` still wins.
    static func location(for url: URL) -> FileLocation? {
        if let local = localURL(url) { return FileLocation(url: local) }
        guard url.isFileURL else { return nil }
        var path = url.path
        var numbers: [Int] = []
        while numbers.count < 2, let colon = path.lastIndex(of: ":") {
            let tail = path[path.index(after: colon)...]
            guard !tail.isEmpty, tail.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(tail) else { break }
            numbers.insert(n, at: 0)
            path = String(path[..<colon])
            var base = URLComponents(url: url, resolvingAgainstBaseURL: false)
            base?.path = path
            if let candidate = base?.url, let local = localURL(candidate) {
                return FileLocation(url: local, line: numbers.first, column: numbers.count > 1 ? numbers[1] : nil)
            }
        }
        return nil
    }

    /// Resolves a path printed in the terminal — `/abs`, `~/home`, or relative to the
    /// pane's working directory — to an existing file or directory.
    static func resolve(path: String, cwd: String?) -> URL? {
        var p = path
        if p == "~" || p.hasPrefix("~/") { p = (p as NSString).expandingTildeInPath }
        let url: URL
        if p.hasPrefix("/") {
            url = URL(fileURLWithPath: p)
        } else if let cwd, cwd.hasPrefix("/") {
            url = URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(p)
        } else {
            return nil
        }
        return FileManager.default.fileExists(atPath: url.path) ? url.standardizedFileURL : nil
    }

    /// Whether "Open in Editor" makes sense: a regular file whose type is text, or whose
    /// type is unknown (Makefile, dotfiles) and whose first bytes contain no NUL.
    static func isLikelyText(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        let type = UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .text) || type.conforms(to: .sourceCode) { return true }
        if let type, !type.isDynamic, type != .data { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        return !head.contains(0)
    }
}
