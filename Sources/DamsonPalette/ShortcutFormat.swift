import Foundation

/// Renders an `NSMenuItem` shortcut (`keyEquivalent` + modifier mask) the way the menu bar
/// does: "⌥⌘←", "⇧⌘D", "⌃⇥". A raw `keyEquivalent` for an arrow or function key is a
/// private-use character (U+F700…) that draws as a box, and tab/return are control chars.
public enum ShortcutFormat {
    // NSEvent.ModifierFlags raw values, so this target needs no AppKit.
    public static let shift: UInt = 1 << 17
    public static let control: UInt = 1 << 18
    public static let option: UInt = 1 << 19
    public static let command: UInt = 1 << 20

    public static func display(keyEquivalent: String, modifiers: UInt) -> String {
        guard let scalar = keyEquivalent.unicodeScalars.first, keyEquivalent.unicodeScalars.count == 1 else {
            return keyEquivalent.isEmpty ? "" : prefix(modifiers) + keyEquivalent.uppercased()
        }
        var mods = modifiers
        let key: String
        if let named = special[scalar.value] {
            key = named
        } else if let f = functionKeyNumber(scalar.value) {
            key = "F\(f)"
        } else {
            let s = String(scalar)
            // AppKit treats an uppercase letter key equivalent as implying Shift.
            if s != s.lowercased() && s == s.uppercased() { mods |= shift }
            key = s.uppercased()
        }
        return prefix(mods) + key
    }

    private static func prefix(_ m: UInt) -> String {
        var s = ""
        if m & control != 0 { s += "⌃" }
        if m & option != 0 { s += "⌥" }
        if m & shift != 0 { s += "⇧" }
        if m & command != 0 { s += "⌘" }
        return s
    }

    private static let special: [UInt32: String] = [
        0xF700: "↑", 0xF701: "↓", 0xF702: "←", 0xF703: "→",
        0xF729: "↖", 0xF72B: "↘", 0xF72C: "⇞", 0xF72D: "⇟", 0xF728: "⌦",
        0x1B: "⎋", 0x09: "⇥", 0x19: "⇥", 0x0D: "↩", 0x03: "⌤",
        0x08: "⌫", 0x7F: "⌫", 0x20: "Space",
    ]

    /// NSF1FunctionKey (0xF704) … NSF35FunctionKey.
    private static func functionKeyNumber(_ v: UInt32) -> Int? {
        (0xF704...0xF726).contains(v) ? Int(v - 0xF704) + 1 : nil
    }
}
