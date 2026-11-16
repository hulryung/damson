import Foundation

/// The quick terminal's global shortcut: a virtual key code plus modifiers, as Carbon's
/// `RegisterEventHotKey` wants them. Stored as JSON under `storageKey`.
///
/// Modifiers are `NSEvent.ModifierFlags` raw bits (⌘⇧⌥⌃ subset) so the recorder can hand
/// them over unchanged; `carbonModifiers` converts. Foundation only, so the bit values are
/// spelled out here rather than imported from AppKit/Carbon.
public struct QuickTerminalShortcut: Codable, Equatable, Sendable {
    public static let enabledKey = "damson.quickTerminal"
    public static let storageKey = "damson.quickTerminal.shortcut"

    // NSEvent.ModifierFlags raw values.
    public static let shift: UInt = 1 << 17
    public static let control: UInt = 1 << 18
    public static let option: UInt = 1 << 19
    public static let command: UInt = 1 << 20

    public var keyCode: UInt16
    public var modifiers: UInt
    /// How the recorder displayed it ("⌃⌘`"). Layout-dependent, so it is recorded rather
    /// than derived from the key code.
    public var display: String

    public init(keyCode: UInt16, modifiers: UInt, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers & (Self.shift | Self.control | Self.option | Self.command)
        self.display = display
    }

    /// ⌃⌘` (kVK_ANSI_Grave = 50).
    public static let `default` = QuickTerminalShortcut(keyCode: 50, modifiers: control | command, display: "⌃⌘`")

    /// Why this chord cannot be a global shortcut, or nil when it can. A global hotkey is
    /// taken from every app, so it must not be something people type: ⌥ and ⇧ alone produce
    /// characters on most layouts, hence ⌘ or ⌃ is required.
    public var problem: String? {
        guard modifiers & (Self.command | Self.control) != 0 else {
            return "A global shortcut needs ⌘ or ⌃, so it can't swallow ordinary typing."
        }
        return nil
    }

    /// Carbon modifier mask (cmdKey, shiftKey, optionKey, controlKey).
    public var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers & Self.command != 0 { m |= 1 << 8 }
        if modifiers & Self.shift != 0 { m |= 1 << 9 }
        if modifiers & Self.option != 0 { m |= 1 << 11 }
        if modifiers & Self.control != 0 { m |= 1 << 12 }
        return m
    }

    /// The stored shortcut, or the default when nothing (or something unusable) is stored.
    public static func load(from defaults: UserDefaults) -> QuickTerminalShortcut {
        guard let data = defaults.data(forKey: storageKey),
              let s = try? JSONDecoder().decode(QuickTerminalShortcut.self, from: data),
              s.problem == nil else { return .default }
        return s
    }

    public func save(to defaults: UserDefaults) {
        if self == .default { defaults.removeObject(forKey: Self.storageKey); return }
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey) }
    }
}
