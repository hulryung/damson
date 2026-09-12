// Isolated native target for computer-use acceptance. Never opens user documents.
import AppKit

final class Fixture: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    var window: NSWindow!
    let field = NSTextField(string: "")
    let label = NSTextField(labelWithString: "Count: 0")
    var count = 0
    var scrollPosition: CGFloat = 0
    var scrollEvents: [[String: Any]] = []
    var eventMonitor: Any?
    var inputMonitor: Any?
    var inputEvents: [[String: Any]] = []
    var timer: Timer?
    var lastSaved: Data?
    let output = ProcessInfo.processInfo.environment["DAMSON_COMPUTER_FIXTURE_STATE"] ?? "/tmp/damson-computer-fixture-state.json"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bare AppKit fixture has no standard Edit menu. Supply the real
        // responder-chain action so Cmd+A is meaningful for nonempty text.
        let menu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 160, y: 180, width: 520, height: 440),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Damson Computer Acceptance"
        let content = window.contentView!
        let button = NSButton(title: "Increment", target: self, action: #selector(increment))
        button.frame = NSRect(x: 30, y: 350, width: 160, height: 36)
        button.setAccessibilityIdentifier("increment")
        content.addSubview(button)
        label.frame = NSRect(x: 220, y: 355, width: 200, height: 24)
        content.addSubview(label)
        field.frame = NSRect(x: 30, y: 290, width: 440, height: 30)
        field.placeholderString = "Type here"
        field.setAccessibilityIdentifier("input")
        field.delegate = self
        content.addSubview(field)
        let scroll = NSScrollView(frame: NSRect(x: 30, y: 25, width: 440, height: 230))
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 2200))
        text.string = (1...100).map { "Acceptance line \($0)" }.joined(separator: "\n")
        text.isEditable = false
        scroll.documentView = text
        content.addSubview(scroll)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in self?.save(scroll: scroll.contentView.bounds.origin.y) }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.scrollEvents.append(["dy": event.scrollingDeltaY, "dx": event.scrollingDeltaX,
                                       "x": event.locationInWindow.x, "y": event.locationInWindow.y,
                                       "phase": event.phase.rawValue])
            self?.save()
            return event
        }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown]) { [weak self] event in
            self?.inputEvents.append(["type": event.type.rawValue, "keyCode": event.type == .leftMouseDown ? -1 : Int(event.keyCode),
                                      "flags": event.modifierFlags.rawValue])
            if let self, self.inputEvents.count > 50 { self.inputEvents.removeFirst() }
            self?.save()
            return event
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.save() }
        save()
    }
    @objc func increment() { count += 1; label.stringValue = "Count: \(count)"; save() }
    func controlTextDidChange(_ obj: Notification) { save() }
    func save(scroll: CGFloat? = nil) {
        if let scroll { scrollPosition = scroll }
        let value: [String: Any] = ["count": count, "text": field.stringValue, "pid": getpid(),
                                    "scroll": scrollPosition, "scrollEvents": scrollEvents,
                                    "editing": field.currentEditor() != nil, "inputEvents": inputEvents,
                                    "selectionLength": field.currentEditor()?.selectedRange.length ?? -1]
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        if data == lastSaved { return }
        try! data.write(to: URL(fileURLWithPath: output), options: .atomic)
        lastSaved = data
    }
}
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let fixture = Fixture()
application.delegate = fixture
application.run()
