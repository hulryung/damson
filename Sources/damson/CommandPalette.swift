import AppKit
import DamsonPalette

/// A transient searchable action list. Actions capture their original destination,
/// rather than dispatching into the search field's responder chain.
///
/// Unavailable menu commands are listed greyed out rather than hidden: a palette that drops
/// "Close Pane" when there is one pane reads as "no such command", while a greyed row says
/// "not here". They sort below available matches of equal relevance, and Return beeps.
final class CommandPalette: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
                            NSSearchFieldDelegate, NSWindowDelegate {
    struct Entry {
        let id: String
        let title: String
        let detail: String
        let shortcut: String
        let isEnabled: Bool
        let run: () -> Void
        init(title: String, detail: String, shortcut: String = "", isEnabled: Bool = true,
             id: String? = nil, run: @escaping () -> Void) {
            self.id = id ?? title + detail
            self.title = title
            self.detail = detail
            self.shortcut = shortcut
            self.isEnabled = isEnabled
            self.run = run
        }
    }
    private let search = NSSearchField()
    private let table = NSTableView()
    private var entries: [Entry] = []
    private var filtered: [Entry] = []
    private weak var origin: NSWindow?
    private var refresh: (() -> [Entry])?
    private var timer: Timer?

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        search.placeholderString = "Search commands, tabs, or folders…"
        search.delegate = self
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action")))
        table.headerView = nil
        table.rowHeight = 48
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(activate)
        // Keep typing focus in the search field even after a row is clicked, so Return,
        // Escape and the arrows keep going through `control(_:textView:doCommandBy:)`.
        table.refusesFirstResponder = true
        scroll.documentView = table
        let stack = NSStackView(views: [search, scroll])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.widthAnchor.constraint(equalTo: search.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(title: String, entries: [Entry], refresh: (() -> [Entry])? = nil) {
        timer?.invalidate()
        origin = NSApp.keyWindow === window ? origin : NSApp.keyWindow
        self.entries = entries
        self.refresh = refresh
        search.stringValue = ""
        window?.title = title
        updateResults()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(search)
        if refresh != nil {
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
                guard let self, self.window?.isVisible == true else { timer.invalidate(); return }
                self.entries = self.refresh?() ?? []
                self.updateResults()
            }
        }
    }
    func controlTextDidChange(_ obj: Notification) { updateResults() }
    private func updateResults() {
        let selected = filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow].id : nil
        let candidates = entries.map {
            PaletteSearch.Candidate(title: $0.title, detail: $0.detail, isEnabled: $0.isEnabled)
        }
        filtered = PaletteSearch.rank(candidates, query: search.stringValue).map { entries[$0] }
        table.reloadData()
        if !filtered.isEmpty {
            let row = filtered.firstIndex { $0.id == selected } ?? 0
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = filtered[row]
        let title = NSTextField(labelWithString: entry.title)
        title.textColor = entry.isEnabled ? .labelColor : .tertiaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: entry.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = entry.isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let shortcut = NSTextField(labelWithString: entry.shortcut)
        shortcut.textColor = entry.isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
        shortcut.setContentHuggingPriority(.required, for: .horizontal)
        shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [text, shortcut])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
        return row
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !filtered.isEmpty else { return true }
            let step = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = max(0, min(filtered.count - 1, table.selectedRow + step))
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.insertNewline(_:)): activate(); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        default: return false
        }
    }
    private func dismiss() {
        timer?.invalidate()
        window?.orderOut(nil)
        origin?.makeKeyAndOrderFront(nil)
    }
    /// If the palette is key, hand key status back to the window it was opened over, so a
    /// caller about to read `NSApp.keyWindow` (re-opening the palette from itself) resolves
    /// commands against the user's window, not the palette and its field editor.
    func returnFocusToOrigin() {
        guard let window, window.isKeyWindow else { return }
        dismiss()
    }
    /// The title-bar close button bypasses `cancelOperation`; it must restore focus too.
    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        origin?.makeKeyAndOrderFront(nil)
    }
    @objc private func activate() {
        guard filtered.indices.contains(table.selectedRow) else { NSSound.beep(); return }
        let entry = filtered[table.selectedRow]
        guard entry.isEnabled else { NSSound.beep(); return }
        dismiss()
        entry.run()
    }

    static func menuEntries(_ menu: NSMenu, origin: NSWindow?, path: String = "") -> [Entry] {
        menu.update()
        return menu.items.flatMap { item -> [Entry] in
            guard !item.isHidden, !item.isSeparatorItem else { return [] }
            if let submenu = item.submenu {
                return menuEntries(submenu, origin: origin, path: path.isEmpty ? submenu.title : path + " › " + submenu.title)
            }
            guard let action = item.action, action != NSSelectorFromString("showCommandPalette:") else { return [] }
            // Resolved now, while the origin window is still key: this is the responder the
            // menu item would have reached, and the palette's own chain never sees the action.
            let target = NSApp.target(forAction: action, to: item.target, from: item) as AnyObject?
            var enabled = item.isEnabled && target != nil
            if enabled, let validator = target as? NSMenuItemValidation, !validator.validateMenuItem(item) {
                enabled = false
            }
            let shortcut = ShortcutFormat.display(keyEquivalent: item.keyEquivalent,
                                                  modifiers: item.keyEquivalentModifierMask.rawValue)
            return [Entry(title: item.title, detail: path, shortcut: shortcut, isEnabled: enabled) { [weak origin, weak target] in
                guard let target else { NSSound.beep(); return }
                origin?.makeKeyAndOrderFront(nil)
                NSApp.sendAction(action, to: target, from: item)
            }]
        }
    }
}
