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
}
