import AppKit
import DamsonTerminal

/// One-shot pane layouts. Each template builds a fixed arrangement of `paneCount` panes
/// with preset split ratios, applied in a single action (no manual splitting/dragging).
enum PaneLayoutTemplate: String, CaseIterable {
    case columns2060            // 20% | 60% | 20%  (the headline example)
    case columns2               // 50% | 50%
    case columns3               // 33% | 33% | 33%
    case rows2                  // top / bottom
    case grid2x2                // 2×2
    case mainRight              // main 70% | right 30%
    case mainLeftStack          // left 60% | right column stacked (2 rows)

    var title: String {
        switch self {
        case .columns2060:    return "Columns 20 / 60 / 20"
        case .columns2:       return "Two Columns"
        case .columns3:       return "Three Columns"
        case .rows2:          return "Two Rows"
        case .grid2x2:        return "2×2 Grid"
        case .mainRight:      return "Main + Right"
        case .mainLeftStack:  return "Main + Stacked Right"
        }
    }

    var paneCount: Int {
        switch self {
        case .columns2, .rows2, .mainRight: return 2
        case .columns2060, .columns3, .mainLeftStack: return 3
        case .grid2x2: return 4
        }
    }

    /// The rebindable key action that triggers this layout.
    var actionID: AppAction.ID {
        switch self {
        case .columns2060:   return .layoutColumns2060
        case .columns2:      return .layoutColumns2
        case .columns3:      return .layoutColumns3
        case .rows2:         return .layoutRows2
        case .grid2x2:       return .layoutGrid2x2
        case .mainRight:     return .layoutMainRight
        case .mainLeftStack: return .layoutMainLeftStack
        }
    }

    static func forAction(_ id: AppAction.ID) -> PaneLayoutTemplate? {
        allCases.first { $0.actionID == id }
    }

    /// Build a tree arranging exactly `paneCount` leaves (parent links set).
    func build(_ leaves: [PaneNode]) -> PaneNode {
        switch self {
        case .columns2:
            return split(.horizontal, leaves[0], leaves[1], 0.5)
        case .rows2:
            return split(.vertical, leaves[0], leaves[1], 0.5)
        case .mainRight:
            return split(.horizontal, leaves[0], leaves[1], 0.7)
        case .columns3:
            return split(.horizontal, leaves[0],
                         split(.horizontal, leaves[1], leaves[2], 0.5), 1.0 / 3.0)
        case .columns2060:
            // left 20%; the remaining 80% holds middle 60% (= 0.75 of 0.8) and right 20%.
            return split(.horizontal, leaves[0],
                         split(.horizontal, leaves[1], leaves[2], 0.75), 0.2)
        case .mainLeftStack:
            // left 60% main; right 40% column split into two stacked rows.
            return split(.horizontal, leaves[0],
                         split(.vertical, leaves[1], leaves[2], 0.5), 0.6)
        case .grid2x2:
            let top = split(.horizontal, leaves[0], leaves[1], 0.5)
            let bottom = split(.horizontal, leaves[2], leaves[3], 0.5)
            return split(.vertical, top, bottom, 0.5)
        }
    }

    private func split(_ dir: SplitDirection, _ a: PaneNode, _ b: PaneNode, _ ratio: CGFloat) -> PaneNode {
        let node = PaneNode(kind: .split(direction: dir, first: a, second: b, ratio: ratio))
        a.parent = node
        b.parent = node
        return node
    }
}
