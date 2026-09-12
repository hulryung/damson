import Foundation

/// The cursor and navigation keys, and what a terminal sends for them when a modifier is
/// held — xterm's `CSI <param> ; <modifier> <final>` form, which every modern TUI reads.
///
/// AppKit never delivers these to a terminal view on its own. Key events go through the
/// text system, which turns Option+Up into a paragraph motion, Shift+Up into a selection
/// command, and hands back a selector that has lost the modifier — or, for most of these
/// combinations, no selector at all. The result was that a modified arrow sent *nothing*:
/// Codex prompting "⌥ + ↑ to answer" could not be answered from damson.
public enum NavKey: Equatable, Sendable {
    case up, down, right, left, home, end, pageUp, pageDown

    /// macOS virtual key codes — the only identification that survives every modifier,
    /// layout and input source. `charactersIgnoringModifiers` does not: an arrow reports a
    /// private-use scalar that shifts around, and an IME can swallow the event entirely.
    public init?(keyCode: UInt16) {
        switch keyCode {
        case 126: self = .up
        case 125: self = .down
        case 124: self = .right
        case 123: self = .left
        case 115: self = .home
        case 119: self = .end
        case 116: self = .pageUp
        case 121: self = .pageDown
        default: return nil
        }
    }

    /// The leading CSI parameter (for the `~`-terminated keys) and the final byte.
    private var form: (parameter: UInt8, final: UInt8) {
        switch self {
        case .up: return (0x31, 0x41)       // 1 A
        case .down: return (0x31, 0x42)     // 1 B
        case .right: return (0x31, 0x43)    // 1 C
        case .left: return (0x31, 0x44)     // 1 D
        case .home: return (0x31, 0x48)     // 1 H
        case .end: return (0x31, 0x46)      // 1 F
        case .pageUp: return (0x35, 0x7E)   // 5 ~
        case .pageDown: return (0x36, 0x7E) // 6 ~
        }
    }

    /// `ESC [ <param> ; <modifier> <final>`, or nil when no modifier is held.
    ///
    /// The modifier is xterm's: 1 plus a bitmask of shift(1), option/meta(2), control(4),
    /// so Option+Up is `ESC [ 1 ; 3 A`. Returning nil for the bare key leaves the caller's
    /// existing unmodified path in charge — that one has to stay free to change, since an
    /// application-cursor-keys mode would send `ESC O A` there and never here: xterm keeps
    /// the CSI form for modified keys whatever the cursor mode is.
    public func sequence(shift: Bool, option: Bool, control: Bool) -> [UInt8]? {
        var modifier = 1
        if shift { modifier += 1 }
        if option { modifier += 2 }
        if control { modifier += 4 }
        guard modifier > 1 else { return nil }
        let (parameter, final) = form
        // Command is deliberately not in the mask, so the code stays one digit (max 8).
        return [0x1B, 0x5B, parameter, 0x3B, UInt8(0x30 + modifier), final]
    }
}
