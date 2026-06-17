import AppKit

/// Inline find overlay — invoked with Cmd+F. A single NSTextField + a match-count label.
/// DamsonSurfaceView receives query/dismiss via callbacks.
final class FindOverlayView: NSView, NSTextFieldDelegate {
    let textField: NSTextField
    let countLabel: NSTextField

    private let onQueryChange: (String) -> Void
    private let onDismiss: () -> Void
    private let onNext: () -> Void
    private let onPrev: () -> Void

    init(
        initialQuery: String,
        onQueryChange: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void,
        onNext: @escaping () -> Void = {},
        onPrev: @escaping () -> Void = {}
    ) {
        self.textField = NSTextField()
        self.countLabel = NSTextField(labelWithString: "")
        self.onQueryChange = onQueryChange
        self.onDismiss = onDismiss
        self.onNext = onNext
        self.onPrev = onPrev
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 30))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.95).cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 0.3, alpha: 1.0).cgColor

        textField.stringValue = initialQuery
        textField.placeholderString = "Find"
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.textColor = NSColor.white
        textField.font = NSFont.systemFont(ofSize: 13)
        textField.focusRingType = .none
        textField.delegate = self
        addSubview(textField)
        textField.frame = NSRect(x: 8, y: 6, width: 200, height: 18)

        countLabel.font = NSFont.systemFont(ofSize: 11)
        countLabel.textColor = NSColor(white: 0.7, alpha: 1.0)
        countLabel.alignment = .right
        addSubview(countLabel)
        countLabel.frame = NSRect(x: 210, y: 7, width: 60, height: 16)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateCount(matched: Int, current: Int? = nil) {
        if matched == 0 {
            countLabel.stringValue = ""
        } else if let cur = current {
            countLabel.stringValue = "\(cur)/\(matched)"
        } else {
            countLabel.stringValue = "\(matched) match\(matched == 1 ? "" : "es")"
        }
    }

    func focus() {
        window?.makeFirstResponder(textField)
    }

    func controlTextDidChange(_ obj: Notification) {
        onQueryChange(textField.stringValue)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onDismiss()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Enter — go to the next match. Shift+Enter doesn't arrive as insertBacktab / a
            // separate selector, so determine it directly from NSEvent modifierFlags.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                onPrev()
            } else {
                onNext()
            }
            return true
        }
        return false
    }
}
