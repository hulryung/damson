import AppKit

/// Compact 모드 전용 커스텀 탭 바. NSWindow 네이티브 탭을 끄고
/// (tabbingMode = .disallowed) 이걸 contentView 최상단에 배치 → 신호등과
/// 같은 row에 탭이 보임.
///
/// 구조:
///   [80pt 비워둠 (신호등 영역)][탭 1][탭 2]...[탭 N][+ 새 탭][여백]
final class CompactTabBarView: NSView {
    var onTabSelected: ((Int) -> Void)?
    var onTabClosed: ((Int) -> Void)?
    var onNewTab: (() -> Void)?

    private var tabButtons: [TabButton] = []
    private let newTabButton = NSButton()
    private var selectedIndex: Int = 0

    private let leadingReservation: CGFloat = 80   // 신호등 자리
    private let trailingReservation: CGFloat = 12
    private let tabSpacing: CGFloat = 2
    private let maxTabWidth: CGFloat = 200
    private let minTabWidth: CGFloat = 80
    private let tabHeight: CGFloat = 24

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // 투명 — 뒤의 NSVisualEffectView가 보이도록.
        layer?.backgroundColor = NSColor.clear.cgColor

        newTabButton.title = "+"
        newTabButton.bezelStyle = .inline
        newTabButton.isBordered = false
        newTabButton.font = NSFont.systemFont(ofSize: 16, weight: .light)
        newTabButton.contentTintColor = .secondaryLabelColor
        newTabButton.target = self
        newTabButton.action = #selector(newTabClicked)
        addSubview(newTabButton)

        // dev 빌드면 우측에 git hash 표시 (정식과 구분).
        if BuildInfo.isDevBuild {
            devLabel = NSTextField(labelWithString: "dev \(BuildInfo.gitHash ?? "")")
            devLabel?.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            devLabel?.textColor = NSColor.systemOrange
            devLabel?.alignment = .right
            if let l = devLabel { addSubview(l) }
        }
    }

    private var devLabel: NSTextField?

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(titles: [String], selectedIndex: Int) {
        self.selectedIndex = selectedIndex
        // 기존 버튼 제거 후 재생성. 탭 수가 자주 변하지 않으므로 OK.
        tabButtons.forEach { $0.removeFromSuperview() }
        tabButtons.removeAll()
        for (i, title) in titles.enumerated() {
            let btn = TabButton(title: title.isEmpty ? "halite" : title,
                                isSelected: i == selectedIndex)
            btn.onClick = { [weak self] in self?.onTabSelected?(i) }
            btn.onClose = { [weak self] in self?.onTabClosed?(i) }
            addSubview(btn)
            tabButtons.append(btn)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let btnSize: CGFloat = 24
        // dev 라벨 — 우측 끝. newTabButton은 그 왼쪽.
        var rightEdge = bounds.width - trailingReservation
        if let dev = devLabel {
            dev.sizeToFit()
            let w = dev.frame.width
            dev.frame = NSRect(x: rightEdge - w, y: (bounds.height - dev.frame.height) / 2,
                               width: w, height: dev.frame.height)
            rightEdge -= w + 8
        }
        newTabButton.frame = NSRect(
            x: max(leadingReservation, rightEdge - btnSize),
            y: (bounds.height - btnSize) / 2,
            width: btnSize, height: btnSize
        )

        guard !tabButtons.isEmpty else { return }
        let count = CGFloat(tabButtons.count)
        let available = bounds.width - leadingReservation - trailingReservation - btnSize - 4
            - tabSpacing * (count - 1)
        let perTab = max(minTabWidth, min(maxTabWidth, available / count))
        let tabY = (bounds.height - tabHeight) / 2

        for (i, btn) in tabButtons.enumerated() {
            btn.frame = NSRect(
                x: leadingReservation + CGFloat(i) * (perTab + tabSpacing),
                y: tabY,
                width: perTab,
                height: tabHeight
            )
        }
        // new tab 버튼은 마지막 탭 오른쪽에 붙여둠.
        if let last = tabButtons.last {
            let nx = last.frame.maxX + 6
            if nx + btnSize + trailingReservation <= bounds.width {
                newTabButton.frame.origin.x = nx
            }
        }
    }

    @objc private func newTabClicked() {
        onNewTab?()
    }
}

/// 탭 하나. 제목 + 우측 close X.
private final class TabButton: NSView {
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var isSelected: Bool

    init(title: String, isSelected: Bool) {
        self.isSelected = isSelected
        super.init(frame: .zero)
        wantsLayer = true
        updateBackground()

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 11)
        titleLabel.textColor = isSelected ? .labelColor : .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        closeButton.title = "✕"
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.font = NSFont.systemFont(ofSize: 9)
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),
        ])

        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self, userInfo: nil
        )
        addTrackingArea(tracking)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func updateBackground() {
        layer?.cornerRadius = 5
        layer?.backgroundColor = isSelected
            ? NSColor.white.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        // close 영역 클릭은 closeButton이 받음 → 여기 도달 안 함.
        onClick?()
    }

    @objc private func closeClicked() {
        onClose?()
    }
}
