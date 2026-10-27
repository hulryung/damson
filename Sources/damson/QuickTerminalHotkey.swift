import AppKit
import Carbon

/// Carbon hotkeys receive only the registered chord and require no input monitoring.
final class QuickTerminalHotkey {
    static let enabledKey = "damson.quickTerminal"
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var toggle: (() -> Void)?
    func enable() -> Bool {
        if hotKey != nil { return true }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            Unmanaged<QuickTerminalHotkey>.fromOpaque(context).takeUnretainedValue().toggle?()
            return noErr
        }, 1, &type, context, &handler)
        guard installed == noErr else { return false }
        let id = EventHotKeyID(signature: 0x44414D53, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_Grave), UInt32(cmdKey | controlKey), id,
                                        GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { disable(); return false }
        return true
    }
    func disable() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
    deinit { disable() }
}
