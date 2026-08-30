import AppKit

/// The header that sits in front of a group's tabs: a coloured dot, the group's name, and —
/// when the group is folded — how many tabs are inside it.
///
/// Clicking folds and unfolds. Double-clicking the name renames, the same interaction a tab
/// already has, so there is one thing to learn rather than two.
final class TabGroupHeaderView: NSView, ImmediateTitlebarClick {
    var onToggle: (() -> Void)?
    var onRename: ((String) -> Void)?
    /// Drag-to-reorder the whole group. `dx` is the cursor's horizontal offset from the
    /// grab point, matching what a tab reports.
    var onDragBegan: (() -> Void)?
    var onDragMoved: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?

    private var dragStartX: CGFloat?
    private var didDrag = false

    private let dot = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    /// Shown only while folded: something inside needs the user. Folding must never be the
    /// reason someone misses a blocked agent, so the header carries what the hidden tabs
    /// would have shown.
    private let attentionLabel = NSTextField(labelWithString: "")
    private var editor: NSTextField?

    private static let dotSize: CGFloat = 7
    private static let inset: CGFloat = 8
    private static let gap: CGFloat = 5

    init(name: String, colorIndex: Int?, collapsed: Bool, memberCount: Int, attention: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5

        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotSize / 2
        addSubview(dot)

        nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        countLabel.font = .systemFont(ofSize: 10)
        countLabel.textColor = .tertiaryLabelColor
        addSubview(countLabel)

        attentionLabel.font = .systemFont(ofSize: 10)
        addSubview(attentionLabel)

        configure(name: name, colorIndex: colorIndex, collapsed: collapsed,
                  memberCount: memberCount, attention: attention)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Reuse rather than rebuild, for the same reason the tab buttons are reused: a refresh
    /// landing between mouseDown and mouseUp would otherwise remove the view mid-click.
    func configure(name: String, colorIndex: Int?, collapsed: Bool,
                   memberCount: Int, attention: Bool) {
        nameLabel.stringValue = name
        nameLabel.textColor = collapsed ? .labelColor : .secondaryLabelColor
        dot.layer?.backgroundColor = Self.color(for: colorIndex).cgColor
        countLabel.stringValue = collapsed ? "\(memberCount)" : ""
        countLabel.isHidden = !collapsed
        // Only while folded: an expanded group's own tabs already carry their badges, and
        // duplicating them on the header is the noise that teaches people to ignore it.
        attentionLabel.stringValue = (collapsed && attention) ? "◑" : ""
        attentionLabel.textColor = .systemOrange
        attentionLabel.isHidden = attentionLabel.stringValue.isEmpty
        layer?.backgroundColor = collapsed
            ? NSColor.labelColor.withAlphaComponent(0.10).cgColor
            : NSColor.labelColor.withAlphaComponent(0.05).cgColor
        needsLayout = true
    }

    /// A palette rather than a stored colour, so a theme change moves the hue with it.
    static func color(for index: Int?) -> NSColor {
        let palette: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple,
                                  .systemPink, .systemTeal, .systemYellow, .systemRed]
        guard let index else { return .systemGray }
        return palette[((index % palette.count) + palette.count) % palette.count]
    }

    /// How wide this header wants to be. The bar subtracts this from the space the tabs
    /// share, so a header can never overlap the first tab of its own group.
    var preferredWidth: CGFloat {
        nameLabel.sizeToFit()
        countLabel.sizeToFit()
        attentionLabel.sizeToFit()
        var w = Self.inset * 2 + Self.dotSize + Self.gap + min(nameLabel.frame.width, 110)
        if !countLabel.isHidden { w += Self.gap + countLabel.frame.width }
        if !attentionLabel.isHidden { w += Self.gap + attentionLabel.frame.width }
        return ceil(w)
    }

    override func layout() {
        super.layout()
        var x = Self.inset
        dot.frame = NSRect(x: x, y: (bounds.height - Self.dotSize) / 2,
                           width: Self.dotSize, height: Self.dotSize)
        x += Self.dotSize + Self.gap

        var trailing = bounds.width - Self.inset
        if !countLabel.isHidden {
            countLabel.sizeToFit()
            countLabel.frame.origin = NSPoint(x: trailing - countLabel.frame.width,
                                              y: (bounds.height - countLabel.frame.height) / 2)
            trailing -= countLabel.frame.width + Self.gap
        }
        if !attentionLabel.isHidden {
            attentionLabel.sizeToFit()
            attentionLabel.frame.origin = NSPoint(x: trailing - attentionLabel.frame.width,
                                                  y: (bounds.height - attentionLabel.frame.height) / 2)
            trailing -= attentionLabel.frame.width + Self.gap
        }
        nameLabel.sizeToFit()
        nameLabel.frame = NSRect(x: x, y: (bounds.height - nameLabel.frame.height) / 2,
                                 width: max(0, trailing - x), height: nameLabel.frame.height)
    }

    // MARK: - Interaction

    // A press is a drag until it turns out not to be: folding happens on mouse-UP, so a
    // grab that moves reorders the group instead of collapsing it under the cursor.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { beginRename(); return }
        dragStartX = convert(event.locationInWindow, from: nil).x
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartX else { return }
        let dx = convert(event.locationInWindow, from: nil).x - start
        if !didDrag {
            // A few pixels of slop, so a click with an unsteady hand still folds.
            guard abs(dx) > 3 else { return }
            didDrag = true
            onDragBegan?()
        }
        onDragMoved?(dx)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStartX = nil; didDrag = false }
        guard dragStartX != nil else { return }
        if didDrag { onDragEnded?() } else { onToggle?() }
    }

    private func beginRename() {
        guard editor == nil else { return }
        let field = NSTextField(string: nameLabel.stringValue)
        field.font = nameLabel.font
        field.frame = nameLabel.frame
        field.isBordered = false
        field.focusRingType = .none
        field.target = self
        field.action = #selector(commitRename)
        field.delegate = self
        addSubview(field)
        editor = field
        window?.makeFirstResponder(field)
        nameLabel.isHidden = true
    }

    @objc private func commitRename() {
        guard let field = editor else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        editor = nil
        field.removeFromSuperview()
        nameLabel.isHidden = false
        // An empty rename is a no-op, not a group named "". A group with a blank header
        // cannot be pointed at, by a person or by `damson-cli group`.
        if !value.isEmpty, value != nameLabel.stringValue { onRename?(value) }
    }
}

extension TabGroupHeaderView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) { commitRename() }
}
