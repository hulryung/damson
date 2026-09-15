import Foundation

/// How the cursor gets from one cell to the next.
///
/// A style rather than a switch because the two animated options differ in cost and in how
/// loud they are: `smooth` is the same single quad the cursor already drew, moved; `trail`
/// adds a handful of fading copies behind it. macOS Reduce Motion turns both off, as it does
/// every other animation here.
public enum CursorMotionStyle: String, CaseIterable, Sendable {
    /// Jump, as a terminal cursor always has.
    case none
    /// Slide to the new cell.
    case smooth
    /// Slide, leaving a fading smear along the path.
    case trail

    public var displayName: String {
        switch self {
        case .none:   return "Jump"
        case .smooth: return "Smooth"
        case .trail:  return "Smooth with trail"
        }
    }

    /// Whether the cursor animates at all.
    public var animates: Bool { self != .none }

    /// Ghost copies drawn behind the moving cursor. Five is enough to read as a smear at
    /// 0.11s without turning the line into a bar.
    public var trailGhosts: Int { self == .trail ? 5 : 0 }
}
