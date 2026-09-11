// Isolated native target for computer-use acceptance. Never opens user documents.
import AppKit

final class Fixture: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    var window: NSWindow!
    let field = NSTextField(string: "")
    let label = NSTextField(labelWithString: "Count: 0")
    var count = 0
    let output = ProcessInfo.processInfo.environment["DAMSON_COMPUTER_FIXTURE_STATE"] ?? "/tmp/damson-computer-fixture-state.json"

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        save()
    }
    @objc func increment() { count += 1; label.stringValue = "Count: \(count)"; save() }
    func controlTextDidChange(_ obj: Notification) { save() }
    func save(scroll: CGFloat? = nil) {
        var value: [String: Any] = ["count": count, "text": field.stringValue, "pid": getpid()]
        if let scroll { value["scroll"] = scroll }
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try! data.write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let fixture = Fixture()
application.delegate = fixture
application.run()
