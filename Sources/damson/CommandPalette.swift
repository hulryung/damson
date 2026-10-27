import AppKit

/// A transient searchable action list. Actions capture their original destination,
/// rather than dispatching into the search field's responder chain.
final class CommandPalette: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    struct Entry {
        let id: String
        let title: String
        let detail: String
        let run: () -> Void
        init(title: String, detail: String, id: String? = nil, run: @escaping () -> Void) {
            self.id = id ?? title + detail
            self.title = title
            self.detail = detail
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
        let terms = search.stringValue.lowercased().split(whereSeparator: \.isWhitespace)
        filtered = entries.filter { entry in
            let text = (entry.title + " " + entry.detail).lowercased()
            return terms.allSatisfy { text.contains($0) }
        }
        table.reloadData()
        if !filtered.isEmpty {
            let row = filtered.firstIndex { $0.id == selected } ?? 0
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let title = NSTextField(labelWithString: filtered[row].title)
        let detail = NSTextField(labelWithString: filtered[row].detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
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
    @objc private func activate() {
        guard filtered.indices.contains(table.selectedRow) else { NSSound.beep(); return }
        let action = filtered[table.selectedRow].run
        dismiss()
        action()
    }

    static func menuEntries(_ menu: NSMenu, origin: NSWindow?, path: String = "") -> [Entry] {
        menu.update()
        return menu.items.flatMap { item -> [Entry] in
            guard !item.isHidden, !item.isSeparatorItem else { return [] }
            if let submenu = item.submenu {
                return menuEntries(submenu, origin: origin, path: path + submenu.title + " › ")
            }
            guard item.isEnabled, let action = item.action,
                  action != NSSelectorFromString("showCommandPalette:"),
                  let target = NSApp.target(forAction: action, to: item.target, from: item) as AnyObject? else { return [] }
            if let validator = target as? NSMenuItemValidation, !validator.validateMenuItem(item) { return [] }
            var modifiers = ""
            let flags = item.keyEquivalentModifierMask
            if flags.contains(.control) { modifiers += "⌃" }
            if flags.contains(.option) { modifiers += "⌥" }
            if flags.contains(.shift) { modifiers += "⇧" }
            if flags.contains(.command) { modifiers += "⌘" }
            let shortcut = item.keyEquivalent.isEmpty ? "" : "  " + modifiers + item.keyEquivalent.uppercased()
            return [Entry(title: item.title, detail: path + shortcut) { [weak origin, weak target] in
                guard let target else { NSSound.beep(); return }
                origin?.makeKeyAndOrderFront(nil)
                NSApp.sendAction(action, to: target, from: item)
            }]
        }
    }
}
