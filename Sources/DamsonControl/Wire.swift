import Foundation

/// NDJSON wire-format types for damson-cli ↔ damson server.
/// Encoding/decoding is implemented manually. (The format derives from the CLI
/// spec in Rust halite's `docs/CLI.md`, but is now damson's own format.)

public enum SplitDir: String, Codable, Sendable {
    case horizontal
    case vertical
}

public enum ControlCommandKind: Equatable, Sendable {
    case newTab
    case split(SplitDir)
    case switchTab(index: Int)
    case closeTab
    case listTabs
}

/// An incoming command. JSON: `{"cmd":"new-tab"}`, `{"cmd":"split","args":{"dir":"horizontal"}}`, etc.
public struct ControlCommand: Decodable, Equatable, Sendable {
    public let kind: ControlCommandKind

    public init(kind: ControlCommandKind) { self.kind = kind }

    enum CodingKeys: String, CodingKey { case cmd, args }
    private struct SplitArgs: Decodable { let dir: SplitDir }
    private struct SwitchArgs: Decodable { let index: Int }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .cmd)
        switch name {
        case "new-tab":
            self.kind = .newTab
        case "close-tab":
            self.kind = .closeTab
        case "list-tabs":
            self.kind = .listTabs
        case "split":
            let a = try c.decode(SplitArgs.self, forKey: .args)
            self.kind = .split(a.dir)
        case "switch-tab":
            let a = try c.decode(SwitchArgs.self, forKey: .args)
            self.kind = .switchTab(index: a.index)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .cmd, in: c,
                debugDescription: "unknown command: \(name)"
            )
        }
    }
}

/// Serializes a command → JSON on the CLI side. Produces output identical to the Rust `cmd_to_json` (down to key order).
public func encodeCommand(_ kind: ControlCommandKind) -> String {
    switch kind {
    case .newTab: return #"{"cmd":"new-tab"}"#
    case .closeTab: return #"{"cmd":"close-tab"}"#
    case .listTabs: return #"{"cmd":"list-tabs"}"#
    case .split(let d):
        return #"{"cmd":"split","args":{"dir":"\#(d.rawValue)"}}"#
    case .switchTab(let i):
        return #"{"cmd":"switch-tab","args":{"index":\#(i)}}"#
    }
}

/// A single list-tabs result row.
public struct TabInfo: Codable, Equatable, Sendable {
    public let index: Int
    public let pane_count: Int
    public init(index: Int, pane_count: Int) {
        self.index = index
        self.pane_count = pane_count
    }
}

/// The response. Success: `{"ok":true}` (+ optional tabs), failure: `{"ok":false,"err":"..."}`.
public struct ControlResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let err: String?
    public let tabs: [TabInfo]?

    public init(ok: Bool, err: String? = nil, tabs: [TabInfo]? = nil) {
        self.ok = ok
        self.err = err
        self.tabs = tabs
    }

    public static func ok() -> Self { .init(ok: true) }
    public static func err(_ msg: String) -> Self { .init(ok: false, err: msg) }
    public static func tabs(_ list: [TabInfo]) -> Self {
        .init(ok: true, tabs: list)
    }

    enum CodingKeys: String, CodingKey { case ok, err, tabs }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ok, forKey: .ok)
        if let err = err { try c.encode(err, forKey: .err) }
        if let tabs = tabs { try c.encode(tabs, forKey: .tabs) }
    }
}
