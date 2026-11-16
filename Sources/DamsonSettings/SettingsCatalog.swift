import Foundation

/// A page of the Settings window's sidebar.
public enum SettingsPage: String, CaseIterable, Identifiable, Sendable {
    case appearance, window, panes, effects, terminal, keys, agents, advanced

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .window: return "Window"
        case .panes: return "Panes"
        case .effects: return "Effects"
        case .terminal: return "Terminal"
        case .keys: return "Keys"
        case .agents: return "Agents"
        case .advanced: return "Advanced"
        }
    }

    /// SF Symbol for the sidebar.
    public var symbol: String {
        switch self {
        case .appearance: return "paintbrush"
        case .window: return "macwindow"
        case .panes: return "rectangle.split.2x1"
        case .effects: return "sparkles"
        case .terminal: return "terminal"
        case .keys: return "keyboard"
        case .agents: return "person.2"
        case .advanced: return "gearshape"
        }
    }
}

/// A setting's default, which also fixes the type its stored value must have.
public enum SettingDefault: Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    /// A string whose default is computed at runtime (the font family depends on what is
    /// installed). Any stored value counts as modified.
    case dynamicString
    /// An opaque blob (custom theme colors, key bindings) with no fixed default. Any
    /// stored value counts as modified.
    case data
}

/// One setting: where it lives in the window, how to find it, and its default.
public struct SettingItem: Identifiable, Equatable, Sendable {
    public let key: String
    public let title: String
    public let page: SettingsPage
    public let section: String
    /// Extra words search matches on, beyond the title, section and page.
    public let keywords: [String]
    public let defaultValue: SettingDefault

    public var id: String { key }

    init(_ key: String, _ title: String, _ page: SettingsPage, _ section: String,
         _ defaultValue: SettingDefault, keywords: [String] = []) {
        self.key = key
        self.title = title
        self.page = page
        self.section = section
        self.keywords = keywords
        self.defaultValue = defaultValue
    }
}

/// Every setting the Settings window shows, in display order.
///
/// The defaults here must match the `@AppStorage` defaults in the app's SettingsView —
/// `SettingsCatalogSourceTests` reads that file and fails on any key that is missing here
/// or whose literal default differs.
public enum SettingsCatalog {
    public static let all: [SettingItem] = [
        // Appearance
        SettingItem("damson.fontSize", "Font size", .appearance, "Font", .double(13),
                    keywords: ["text", "zoom", "글꼴", "폰트", "크기"]),
        SettingItem("damson.fontFamily", "Font family", .appearance, "Font", .dynamicString,
                    keywords: ["typeface", "nerd", "monospace", "글꼴", "폰트"]),
        SettingItem("damson.ligatures", "Ligatures", .appearance, "Font", .bool(false),
                    keywords: ["fira", "합자"]),
        SettingItem("damson.ambiguousWide", "Ambiguous-width symbols as double width", .appearance,
                    "Font", .bool(false), keywords: ["cjk", "east asian", "width", "전각"]),
        SettingItem("damson.theme", "Theme", .appearance, "Theme", .string("Default Dark"),
                    keywords: ["color", "colour", "dark", "light", "테마", "색상"]),
        SettingItem("damson.customTheme", "Custom theme colors", .appearance, "Theme", .data,
                    keywords: ["ansi", "palette", "background", "foreground"]),

        // Window
        SettingItem("damson.tabBarStyle", "Tab bar", .window, "Window", .string("compact"),
                    keywords: ["tabs", "탭"]),
        SettingItem("damson.tabBarTransparent", "Transparent tab bar", .window, "Window", .bool(false),
                    keywords: ["frosted", "translucent", "탭", "투명"]),
        SettingItem("damson.showScrollbar", "Always show scrollbar", .window, "Window", .bool(false),
                    keywords: ["scroller", "스크롤바"]),
        SettingItem("damson.tabTransition", "Tab transition", .window, "Window", .string("slide"),
                    keywords: ["animation", "switch", "탭", "전환"]),
        SettingItem("damson.focusFollowsMouse", "Focus follows mouse", .window, "Window", .bool(true),
                    keywords: ["hover", "pointer", "pane", "포커스", "마우스"]),
        SettingItem("damson.evenSplits", "Even splits", .window, "Window", .bool(true),
                    keywords: ["split", "equal", "pane", "분할"]),
        SettingItem("damson.newTabDirectory", "New tab directory", .window, "Window", .string("home"),
                    keywords: ["cwd", "folder", "working directory", "디렉터리", "폴더"]),
        SettingItem("damson.paddingH", "Horizontal padding", .window, "Padding", .double(4),
                    keywords: ["margin", "inset", "여백"]),
        SettingItem("damson.paddingV", "Vertical padding", .window, "Padding", .double(4),
                    keywords: ["margin", "inset", "여백"]),
        SettingItem("damson.backgroundOpacity", "Background opacity", .window, "Transparency",
                    .double(1), keywords: ["transparent", "alpha", "투명", "불투명도"]),
        SettingItem("damson.backgroundBlur", "Background blur", .window, "Transparency", .bool(false),
                    keywords: ["frosted glass", "vibrancy", "블러", "흐림"]),
        SettingItem(QuickTerminalShortcut.enabledKey, "Global quick-terminal shortcut", .window,
                    "Quick Terminal", .bool(false),
                    keywords: ["hotkey", "global", "dropdown", "visor", "단축키"]),
        SettingItem(QuickTerminalShortcut.storageKey, "Quick-terminal shortcut", .window,
                    "Quick Terminal", .data, keywords: ["hotkey", "global", "단축키"]),

        // Panes
        SettingItem("damson.activePaneIndicator", "Active pane indicator", .panes, "Active Pane",
                    .string("accentBorder"), keywords: ["focus", "highlight", "split", "활성", "패인"]),
        SettingItem("damson.paneDimStrength", "Dim strength", .panes, "Active Pane", .double(0.4),
                    keywords: ["darken", "inactive", "scrim", "흐리게", "어둡게"]),
        SettingItem("damson.paneDimTint", "Dim color", .panes, "Active Pane", .string("auto"),
                    keywords: ["darken", "inactive", "tint", "흐리게"]),
        SettingItem("damson.paneAccentColor", "Custom accent color", .panes, "Active Pane",
                    .string(""), keywords: ["border", "outline", "highlight", "강조", "색상"]),
        SettingItem("damson.paneBorderWidth", "Border width", .panes, "Active Pane", .double(1),
                    keywords: ["outline", "thickness", "테두리", "두께"]),
        SettingItem("damson.dimInactiveWindows", "Dim inactive windows", .panes, "Inactive Windows",
                    .bool(false), keywords: ["background window", "unfocused", "darken", "흐리게"]),
        SettingItem("damson.paneDividerColor", "Custom divider color", .panes, "Dividers", .string(""),
                    keywords: ["separator", "split line", "구분선"]),
        SettingItem("damson.paneDividerWidth", "Divider width", .panes, "Dividers", .double(1),
                    keywords: ["separator", "thickness", "구분선", "두께"]),

        // Effects
        SettingItem("damson.screenEffect", "Screen effect", .effects, "Screen Effect", .string("none"),
                    keywords: ["crt", "bloom", "phosphor", "rain", "snow", "효과"]),
        SettingItem("damson.screenEffectIntensity", "Effect intensity", .effects, "Screen Effect",
                    .double(1), keywords: ["strength", "강도"]),
        SettingItem("damson.glyphAppear", "Typing animation", .effects, "Text Animation", .string("none"),
                    keywords: ["appear", "glyph", "type", "애니메이션"]),
        SettingItem("damson.glyphDisappear", "Delete animation", .effects, "Text Animation",
                    .string("none"), keywords: ["disappear", "glyph", "erase", "애니메이션"]),

        // Terminal
        SettingItem("damson.scrollbackLines", "Scrollback lines", .terminal, "Scrollback", .int(10_000),
                    keywords: ["history", "buffer", "스크롤백"]),
        SettingItem("damson.restoreScrollback", "Restore scrollback on relaunch", .terminal,
                    "Scrollback", .bool(false), keywords: ["history", "save", "복원"]),
        SettingItem("damson.keepSessionsOnRestart", "Keep sessions running across restarts",
                    .terminal, "Sessions", .bool(false), keywords: ["keeper", "update", "restart", "세션"]),
        SettingItem("damson.cursorShape", "Cursor shape", .terminal, "Cursor", .string("block"),
                    keywords: ["block", "bar", "underline", "beam", "커서"]),
        SettingItem("damson.cursorBlink", "Cursor blink", .terminal, "Cursor", .bool(false),
                    keywords: ["flash", "커서", "깜빡임"]),
        SettingItem("damson.cursorMotion", "Cursor motion", .terminal, "Cursor", .string("none"),
                    keywords: ["trail", "smooth", "slide", "커서"]),
        SettingItem("damson.animations", "Animations", .terminal, "Cursor", .bool(true),
                    keywords: ["motion", "reduce motion", "애니메이션"]),
        SettingItem("damson.imeStyle", "IME composition style", .terminal, "IME Composition",
                    .string("none"), keywords: ["korean", "japanese", "chinese", "input", "한글", "입력기"]),
        SettingItem("damson.copyOnSelect", "Copy on select", .terminal, "Selection", .bool(true),
                    keywords: ["clipboard", "복사", "선택"]),
        SettingItem("damson.wordSeparators", "Word separators", .terminal, "Selection", .string(""),
                    keywords: ["double-click", "word", "선택"]),
        SettingItem("damson.scrollSpeed", "TUI scroll speed", .terminal, "Scroll", .double(1),
                    keywords: ["trackpad", "mouse", "tmux", "스크롤", "속도"]),
        SettingItem("damson.pressAndHold", "Press and hold for accents", .terminal, "Keyboard",
                    .bool(false), keywords: ["key repeat", "accent", "키 반복"]),

        // Keys
        SettingItem("damson.keybindings", "Keyboard shortcuts", .keys, "Shortcuts", .data,
                    keywords: ["hotkey", "keybinding", "rebind", "단축키"]),

        // Agents
        SettingItem("damson.orchestration.agentCommand", "Agent command", .agents, "Agent",
                    .string("claude"), keywords: ["codex", "crew", "에이전트"]),
        SettingItem("damson.orchestration.skipPermissions", "Skip permission prompts", .agents,
                    "Agent", .bool(true), keywords: ["dangerously", "approval", "권한"]),
        SettingItem("damson.orchestration.openRunsInNewWindow", "Open each run in a new window",
                    .agents, "Windows", .bool(false), keywords: ["crew", "run", "창"]),
        SettingItem("damson.orchestration.notifyOnWaiting", "Notify when an agent is blocked",
                    .agents, "Notifications", .bool(true), keywords: ["waiting", "알림"]),
        SettingItem("damson.orchestration.focusOnWaiting", "Bring a blocked agent's tab forward",
                    .agents, "Notifications", .bool(false), keywords: ["waiting", "focus", "알림"]),
        SettingItem("damson.orchestration.notifyOnFinished", "Notify when an agent finishes",
                    .agents, "Notifications", .bool(true), keywords: ["done", "idle", "알림"]),
        SettingItem("damson.orchestration.stallMinutes", "Quiet agent alert", .agents,
                    "Notifications", .int(5), keywords: ["stall", "stuck", "minutes", "알림"]),
        SettingItem("damson.orchestration.worktreeRoot", "Worktree root folder", .agents, "Worktrees",
                    .string(""), keywords: ["git", "worktree", "워크트리"]),
        SettingItem("damson.orchestration.trustNewWorktrees", "Trust new worktrees automatically",
                    .agents, "Worktrees", .bool(true), keywords: ["git", "claude.json", "워크트리"]),

        // Advanced
        SettingItem("damson.autoUpdate", "Automatic updates", .advanced, "Updates", .bool(false),
                    keywords: ["sparkle", "version", "업데이트"]),
    ]

    private static let byKey: [String: SettingItem] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    public static func item(_ key: String) -> SettingItem? { byKey[key] }

    /// Section titles of a page, in display order.
    public static func sections(of page: SettingsPage) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for i in all where i.page == page && seen.insert(i.section).inserted { out.append(i.section) }
        return out
    }

    public static func items(page: SettingsPage, section: String? = nil) -> [SettingItem] {
        all.filter { $0.page == page && (section == nil || $0.section == section) }
    }

    // MARK: Search

    /// Items matching every whitespace-separated word of `query` (case- and
    /// diacritic-insensitive, prefix or substring) against the title, section, page and
    /// keywords. Title hits rank before keyword-only hits; catalogue order breaks ties.
    public static func search(_ query: String) -> [SettingItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
        guard !words.isEmpty else { return [] }
        let scored: [(SettingItem, Int)] = all.compactMap { item in
            let title = fold(item.title)
            let rest = ([item.section, item.page.title] + item.keywords).map(fold).joined(separator: " ")
            var titleHits = 0
            for w in words {
                if title.contains(w) { titleHits += 1 } else if !rest.contains(w) { return nil }
            }
            return (item, titleHits)
        }
        return scored.enumerated()
            .sorted { a, b in a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset }
            .map { $0.element.0 }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    // MARK: Modified / reset

    /// The stored value differs from the default. A key that was never written (or was
    /// reset) is not modified; neither is one set back to exactly its default.
    public static func isModified(_ item: SettingItem, in defaults: UserDefaults) -> Bool {
        guard let stored = defaults.object(forKey: item.key) else { return false }
        return !matchesDefault(stored, item.defaultValue)
    }

    public static func modifiedItems(page: SettingsPage, section: String? = nil,
                                     in defaults: UserDefaults) -> [SettingItem] {
        items(page: page, section: section).filter { isModified($0, in: defaults) }
    }

    /// Back to defaults by removing the stored values, so every reader — `@AppStorage`
    /// included — falls back to its own default rather than to a copy of it.
    public static func reset(page: SettingsPage, section: String? = nil, in defaults: UserDefaults) {
        for i in items(page: page, section: section) { defaults.removeObject(forKey: i.key) }
    }

    static func matchesDefault(_ stored: Any, _ d: SettingDefault) -> Bool {
        switch d {
        case .bool(let b): return asBool(stored) == b
        case .int(let i): return asNumber(stored).map { $0.doubleValue == Double(i) } ?? false
        case .double(let x): return asNumber(stored).map { abs($0.doubleValue - x) < 1e-9 } ?? false
        case .string(let s): return (stored as? String) == s
        case .dynamicString, .data: return false
        }
    }

    // MARK: Export / import

    public static let fileFormat = "damson-settings"
    public static let fileVersion = 1

    public enum ImportError: Error, Equatable, LocalizedError {
        case notASettingsFile
        case newerVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .notASettingsFile: return "This file is not a Damson settings file."
            case .newerVersion(let v):
                return "This file was saved by a newer Damson (format \(v)). Update Damson to import it."
            }
        }
    }

    public struct ImportResult: Equatable {
        /// Keys whose value was written (or reset because the file had the default).
        public var applied: [String] = []
        /// Keys in the file this build doesn't know, or whose value had the wrong type.
        public var skipped: [String] = []
    }

    /// A property list of every setting's effective value (stored, else default), so
    /// importing it reproduces this Mac's setup rather than merging into the other one.
    public static func exportData(from defaults: UserDefaults) throws -> Data {
        var settings: [String: Any] = [:]
        for i in all {
            if let v = defaults.object(forKey: i.key), isValid(v, for: i.defaultValue) {
                settings[i.key] = v
            } else if let v = plistValue(i.defaultValue) {
                settings[i.key] = v
            }
        }
        let root: [String: Any] = ["format": fileFormat, "version": fileVersion, "settings": settings]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    /// Apply an exported file. Only known keys with correctly typed values are written;
    /// a value equal to the default is stored as "unset" so it doesn't show as modified.
    /// Settings missing from the file are left as they are.
    @discardableResult
    public static func importData(_ data: Data, into defaults: UserDefaults) throws -> ImportResult {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              root["format"] as? String == fileFormat,
              let settings = root["settings"] as? [String: Any]
        else { throw ImportError.notASettingsFile }
        let version = (root["version"] as? Int) ?? 0
        guard version <= fileVersion else { throw ImportError.newerVersion(version) }

        var result = ImportResult()
        for key in settings.keys.sorted() {
            guard let item = byKey[key], let value = settings[key], isValid(value, for: item.defaultValue) else {
                result.skipped.append(key)
                continue
            }
            if matchesDefault(value, item.defaultValue) {
                defaults.removeObject(forKey: key)
            } else {
                defaults.set(value, forKey: key)
            }
            result.applied.append(key)
        }
        return result
    }

    static func isValid(_ v: Any, for d: SettingDefault) -> Bool {
        switch d {
        case .bool: return asBool(v) != nil
        case .int, .double: return asNumber(v) != nil
        case .string, .dynamicString: return v is String
        case .data: return v is Data
        }
    }

    private static func plistValue(_ d: SettingDefault) -> Any? {
        switch d {
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let x): return x
        case .string(let s): return s
        case .dynamicString, .data: return nil
        }
    }

    /// Booleans and numbers both bridge to NSNumber; tell them apart by CF type so a
    /// `true` can't satisfy a numeric setting or `1` a boolean one.
    private static func asBool(_ v: Any) -> Bool? {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    private static func asNumber(_ v: Any) -> NSNumber? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n
    }
}
