import AppKit
import HaliteTerminal

/// PaneNode 트리를 화면에 배치하는 NSView. divider drag로 ratio 조정 + leaf 클릭으로
/// active pane 선택. Cmd+D / Cmd+Shift+D 로 split, Cmd+W 로 active pane 닫기.
final class PaneTreeView: NSView {
    private(set) var root: PaneNode
    private(set) var activeLeaf: PaneNode

    /// 마지막 leaf가 닫혔을 때 호출 (호스트 — 탭 컨트롤러 — 가 탭/윈도우를 닫음).
    var onAllPanesClosed: (() -> Void)?

    /// PaneTreeView 안의 active pane 가시 표시. 1px border.
    private let activeBorderColor = NSColor.systemBlue.withAlphaComponent(0.6)
    private let inactiveBorderColor = NSColor.clear

    private let dividerThickness: CGFloat = 4

    init(rootSession: HaliteSession) {
        let leaf = PaneNode.leaf(rootSession)
        self.root = leaf
        self.activeLeaf = leaf
        super.init(frame: .zero)
        wantsLayer = true
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        root.terminateAll()
    }

    // MARK: - Public actions

    func split(direction: SplitDirection) {
        guard case .leaf = activeLeaf.kind else { return }
        let newSession = HaliteSession(config: HaliteConfig.fromUserDefaults())
        let newLeaf = PaneNode.leaf(newSession)
        let oldKind = activeLeaf.kind
        // activeLeaf의 kind를 split으로 교체. activeLeaf 인스턴스는 그대로 (parent 링크 보존).
        let oldLeafCopy = PaneNode(kind: oldKind)
        oldLeafCopy.parent = activeLeaf
        newLeaf.parent = activeLeaf
        activeLeaf.kind = .split(
            direction: direction,
            first: oldLeafCopy,
            second: newLeaf,
            ratio: 0.5
        )
        activeLeaf = newLeaf
        rebuild()
    }

    func closeActive() {
        guard case .leaf = activeLeaf.kind else { return }
        // session terminate.
        if case .leaf(let s, _) = activeLeaf.kind {
            s.terminate()
        }
        // 부모의 다른 child가 그 부모 자리로 promote.
        guard let parent = activeLeaf.parent,
              case .split(_, let first, let second, _) = parent.kind
        else {
            // root leaf 닫은 경우 — 전체 종료.
            onAllPanesClosed?()
            return
        }
        let sibling = (first === activeLeaf) ? second : first
        parent.kind = sibling.kind
        // sibling이 split이었으면 그 자식들의 parent를 갱신.
        if case .split(_, let a, let b, _) = parent.kind {
            a.parent = parent
            b.parent = parent
        }
        // 새 active를 promote된 sub-tree의 첫 leaf로 설정.
        activeLeaf = firstLeaf(of: parent)
        rebuild()
    }

    /// 마우스 클릭 등으로 외부에서 active pane 변경 호출.
    func setActive(_ leaf: PaneNode) {
        guard case .leaf = leaf.kind else { return }
        activeLeaf = leaf
        updateBorderColors()
        if case .leaf(_, let surface) = leaf.kind {
            window?.makeFirstResponder(surface)
        }
    }

    // MARK: - Tree → NSView 재구성

    private func rebuild() {
        for sub in subviews { sub.removeFromSuperview() }
        addSubviewsForNode(root, into: self)
        updateBorderColors()
        if case .leaf(_, let surface) = activeLeaf.kind {
            window?.makeFirstResponder(surface)
        }
        needsLayout = true
    }

    private func addSubviewsForNode(_ node: PaneNode, into container: NSView) {
        switch node.kind {
        case .leaf(_, let surface):
            // leaf 컨테이너 — border 표시용 wrapper. frame + autoresizing 으로 fill.
            let wrapper = PaneLeafWrapper(leaf: node, owner: self)
            wrapper.translatesAutoresizingMaskIntoConstraints = true
            wrapper.autoresizingMask = [.width, .height]
            wrapper.frame = container.bounds
            container.addSubview(wrapper)
            // surface는 autolayout으로 wrapper를 1pt border 안쪽으로 fill.
            surface.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(surface)
            NSLayoutConstraint.activate([
                surface.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 1),
                surface.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -1),
                surface.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 1),
                surface.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -1),
            ])

        case .split(let dir, let first, let second, _):
            // split — 두 sub-area + divider. SplitContainer의 layout()이 frame 계산.
            let splitContainer = SplitContainer(node: node, owner: self)
            splitContainer.translatesAutoresizingMaskIntoConstraints = true
            splitContainer.autoresizingMask = [.width, .height]
            splitContainer.frame = container.bounds
            container.addSubview(splitContainer)
            // 재귀 — split의 firstContainer/secondContainer 자체도 autoresizing OFF
            // (SplitContainer.layout이 frame을 직접 set).
            addSubviewsForNode(first, into: splitContainer.firstContainer)
            addSubviewsForNode(second, into: splitContainer.secondContainer)
            _ = dir // suppress unused
        }
    }

    // MARK: - Border 색 갱신

    private func updateBorderColors() {
        func walk(_ view: NSView) {
            if let wrapper = view as? PaneLeafWrapper {
                wrapper.isActive = (wrapper.leaf === activeLeaf)
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(self)
    }

    /// node가 leaf면 그대로, split이면 첫 leaf까지 내려감.
    private func firstLeaf(of node: PaneNode) -> PaneNode {
        switch node.kind {
        case .leaf: return node
        case .split(_, let a, _, _): return firstLeaf(of: a)
        }
    }
}

/// Leaf wrapper view — 1px border로 active 표시.
private final class PaneLeafWrapper: NSView {
    let leaf: PaneNode
    weak var owner: PaneTreeView?
    var isActive: Bool = false {
        didSet { needsDisplay = true }
    }

    init(leaf: PaneNode, owner: PaneTreeView) {
        self.leaf = leaf
        self.owner = owner
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        (isActive ? NSColor.systemBlue.withAlphaComponent(0.6) : NSColor.clear).setStroke()
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        owner?.setActive(leaf)
        super.mouseDown(with: event)
    }
}

/// Split container — 두 sub-area + 가운데 divider. divider drag로 ratio 조정.
private final class SplitContainer: NSView {
    let node: PaneNode
    weak var owner: PaneTreeView?
    let firstContainer = NSView()
    let secondContainer = NSView()
    private let divider = DividerView()
    private let dividerThickness: CGFloat = 4

    init(node: PaneNode, owner: PaneTreeView) {
        self.node = node
        self.owner = owner
        super.init(frame: .zero)
        for v in [firstContainer, secondContainer, divider] {
            v.wantsLayer = true
            addSubview(v)
        }
        divider.onDrag = { [weak self] delta in self?.applyDrag(delta) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard case .split(let dir, _, _, let ratio) = node.kind else { return }
        switch dir {
        case .horizontal:  // 좌우 분할
            let total = bounds.width
            let firstW = max(0, total * ratio - dividerThickness / 2)
            let secondW = max(0, total - firstW - dividerThickness)
            firstContainer.frame = NSRect(x: 0, y: 0, width: firstW, height: bounds.height)
            divider.frame = NSRect(x: firstW, y: 0, width: dividerThickness, height: bounds.height)
            secondContainer.frame = NSRect(
                x: firstW + dividerThickness, y: 0,
                width: secondW, height: bounds.height
            )
            divider.orientation = .vertical
        case .vertical:    // 위아래 분할
            let total = bounds.height
            let secondH = max(0, total * (1 - ratio) - dividerThickness / 2)
            let firstH = max(0, total - secondH - dividerThickness)
            // bottom-up 좌표계 — first가 위, second가 아래로 보이도록.
            secondContainer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: secondH)
            divider.frame = NSRect(x: 0, y: secondH, width: bounds.width, height: dividerThickness)
            firstContainer.frame = NSRect(
                x: 0, y: secondH + dividerThickness,
                width: bounds.width, height: firstH
            )
            divider.orientation = .horizontal
        }
    }

    private func applyDrag(_ delta: CGFloat) {
        guard case .split(let dir, let a, let b, let ratio) = node.kind else { return }
        let total: CGFloat
        let deltaRatio: CGFloat
        switch dir {
        case .horizontal:
            total = bounds.width
            deltaRatio = delta / max(total, 1)
        case .vertical:
            total = bounds.height
            deltaRatio = -delta / max(total, 1)  // bottom-up coord
        }
        let newRatio = min(0.95, max(0.05, ratio + deltaRatio))
        node.kind = .split(direction: dir, first: a, second: b, ratio: newRatio)
        needsLayout = true
    }
}

/// 드래그 가능한 divider.
private final class DividerView: NSView {
    enum Orientation { case horizontal, vertical }
    var orientation: Orientation = .vertical {
        didSet { updateCursor() }
    }
    var onDrag: ((CGFloat) -> Void)?
    private var dragStart: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.gridColor.withAlphaComponent(0.4).cgColor
        updateCursor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func updateCursor() {
        // 트래킹 영역 + cursor — 마우스 hover 시 적절한 drag cursor.
        let opts: NSTrackingArea.Options = [
            .activeInActiveApp, .inVisibleRect, .cursorUpdate,
        ]
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(rect: .zero, options: opts, owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func cursorUpdate(with event: NSEvent) {
        switch orientation {
        case .vertical: NSCursor.resizeLeftRight.set()
        case .horizontal: NSCursor.resizeUpDown.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = window?.mouseLocationOutsideOfEventStream
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart,
              let now = window?.mouseLocationOutsideOfEventStream
        else { return }
        let delta: CGFloat
        switch orientation {
        case .vertical: delta = now.x - start.x
        case .horizontal: delta = now.y - start.y
        }
        dragStart = now
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }
}
