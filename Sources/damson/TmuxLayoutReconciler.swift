import AppKit
import DamsonTerminal

/// Converts a tmux **N-ary** layout tree (`TmuxLayoutTree`) into a Damson **BINARY**
/// `PaneNode` tree (docs §5.1). An N-ary split group `{a,b,c}` becomes a right-leaning
/// chain of binary splits `split(a, split(b, c))`; each split's ratio is the first child's
/// extent along the split axis over the sum of the remaining children's extents, so the
/// on-screen proportions match tmux's cell sizes.
///
/// Leaf nodes are supplied by `leafFor(paneID)` so the caller can **reuse existing**
/// `PaneNode`s (preserving each pane's session/surface/grid) and only mint new ones for
/// pane ids that just appeared. Pane id is the stable identity that makes reconcile
/// idempotent (docs §5.1).
enum TmuxLayoutReconciler {

    /// Build the binary `PaneNode` tree for `layout`, taking each leaf from `leafFor`.
    static func build(_ layout: TmuxLayoutTree,
                      leafFor: (TmuxPaneID) -> PaneNode) -> PaneNode {
        switch layout {
        case let .leaf(pane, _, _, _, _):
            return leafFor(pane)
        case let .split(orientation, _, _, _, _, children):
            let dir: SplitDirection = orientation == .horizontal ? .horizontal : .vertical
            return chain(children, dir: dir, leafFor: leafFor)
        }
    }

    /// Fold `children` (≥1) into a right-leaning binary chain of splits along `dir`.
    private static func chain(_ children: [TmuxLayoutTree], dir: SplitDirection,
                              leafFor: (TmuxPaneID) -> PaneNode) -> PaneNode {
        // A well-formed split always has ≥2 children, but stay defensive.
        if children.count == 1 { return build(children[0], leafFor: leafFor) }
        let first = build(children[0], leafFor: leafFor)
        let rest = chain(Array(children.dropFirst()), dir: dir, leafFor: leafFor)
        let firstExtent = extent(children[0], along: dir)
        let restExtent = children.dropFirst().reduce(0) { $0 + extent($1, along: dir) }
        let ratio = CGFloat(firstExtent) / CGFloat(max(1, firstExtent + restExtent))
        let node = PaneNode(kind: .split(direction: dir, first: first, second: rest, ratio: ratio))
        first.parent = node
        rest.parent = node
        return node
    }

    /// A cell's extent along the split axis: width for a horizontal (left/right) split,
    /// height for a vertical (top/bottom) split.
    private static func extent(_ t: TmuxLayoutTree, along dir: SplitDirection) -> Int {
        let g = t.geometry
        return dir == .horizontal ? g.width : g.height
    }
}
