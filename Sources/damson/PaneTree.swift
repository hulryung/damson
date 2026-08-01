import AppKit
import DamsonTerminal

/// Split direction. horizontal = side by side (vertical divider),
/// vertical = stacked top/bottom (horizontal divider). Naming follows iTerm2 convention.
enum SplitDirection {
    case horizontal  // left/right
    case vertical    // top/bottom
}

/// Split tree node. leaf (a single session) or split (direction + two children + ratio).
/// Class-based since reference semantics are required.
final class PaneNode {
    enum Kind {
        case leaf(session: DamsonSession, surface: DamsonSurfaceView)
        case split(direction: SplitDirection, first: PaneNode, second: PaneNode, ratio: CGFloat)
    }
    var kind: Kind
    weak var parent: PaneNode?

    init(kind: Kind) {
        self.kind = kind
    }

    static func leaf(_ session: DamsonSession) -> PaneNode {
        let surface = DamsonSurfaceView(session: session)
        surface.translatesAutoresizingMaskIntoConstraints = false
        return PaneNode(kind: .leaf(session: session, surface: surface))
    }

    var isLeaf: Bool {
        if case .leaf = kind { return true }
        return false
    }

    /// The leaf PaneNodes in-order (reference identity preserved — used to reuse panes
    /// when re-laying out via a template).
    func leafNodes() -> [PaneNode] {
        switch kind {
        case .leaf: return [self]
        case .split(_, let a, let b, _): return a.leafNodes() + b.leafNodes()
        }
    }

    /// Traverse all leaves in the tree in-order.
    func leaves() -> [(session: DamsonSession, surface: DamsonSurfaceView)] {
        switch kind {
        case .leaf(let s, let v):
            return [(s, v)]
        case .split(_, let a, let b, _):
            return a.leaves() + b.leaves()
        }
    }

    /// Terminate every session under this node.
    func terminateAll() {
        for (s, _) in leaves() { s.terminate() }
    }

    // MARK: - Even splits

    /// How many panes this subtree takes up *along* `direction`. A split on the same axis
    /// contributes its children's slots (it divides the same run); anything else — a leaf,
    /// or a split across the other axis — occupies exactly one slot, however it's carved up
    /// internally.
    func slotCount(along direction: SplitDirection) -> Int {
        if case .split(let dir, let a, let b, _) = kind, dir == direction {
            return a.slotCount(along: direction) + b.slotCount(along: direction)
        }
        return 1
    }

    /// Re-space the run of same-axis splits rooted at this node so every slot in it comes
    /// out the same size: each split's ratio becomes its first child's share of the run.
    /// Nested splits on the other axis are left alone (they're one slot from here).
    ///
    /// A binary tree can't hold "three equal columns" in one node, so thirds are spelled
    /// `⅔ · [½ · ½]` — hence the ratio at each level is a slot count, not a constant.
    func equalizeRatios(along direction: SplitDirection) {
        guard case .split(let dir, let first, let second, _) = kind, dir == direction else { return }
        let firstSlots = first.slotCount(along: direction)
        let total = firstSlots + second.slotCount(along: direction)
        kind = .split(
            direction: dir,
            first: first,
            second: second,
            ratio: CGFloat(firstSlots) / CGFloat(total)
        )
        first.equalizeRatios(along: direction)
        second.equalizeRatios(along: direction)
    }
}
