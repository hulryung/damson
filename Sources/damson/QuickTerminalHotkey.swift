import AppKit
import Carbon
import DamsonSettings

/// Carbon hotkeys receive only the registered chord and require no input monitoring, so
/// ordinary typing never reaches this. `QuickTerminalShortcut.problem` additionally keeps
/// chords people type (no ⌘/⌃) from being registered at all.
final class QuickTerminalHotkey {
    private static let hotKeyID = EventHotKeyID(signature: 0x44414D53, id: 1)   // 'DAMS'
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// What is registered right now (nil = nothing).
    private(set) var registered: QuickTerminalShortcut?
    var toggle: (() -> Void)?

    enum Failure: Error {
        case notAllowed(String)
        /// Another app (or the system) already owns this chord.
        case inUse
        case failed(OSStatus)

        var message: String {
            switch self {
            case .notAllowed(let why): return why
            // macOS reports this only for chords it or this app already holds; another app's
            // ordinary registration of the same chord is NOT refused, which is why the
            // shortcut is configurable.
            case .inUse: return "This shortcut is already registered. Choose a different one in Settings → Window → Quick Terminal."
            case .failed(let status): return "macOS refused to register the shortcut (error \(status)). Choose a different one in Settings → Window → Quick Terminal."
            }
        }
    }

    /// Register `shortcut`, replacing whatever was registered. On failure nothing is registered.
    func register(_ shortcut: QuickTerminalShortcut) -> Result<Void, Failure> {
        if registered == shortcut { return .success(()) }
        disable()
        if let why = shortcut.problem { return .failure(.notAllowed(why)) }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let context = Unmanaged.passUnretained(self).toOpaque()
            let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let got = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                            nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard got == noErr, id.signature == QuickTerminalHotkey.hotKeyID.signature,
                      id.id == QuickTerminalHotkey.hotKeyID.id else { return OSStatus(eventNotHandledErr) }
                Unmanaged<QuickTerminalHotkey>.fromOpaque(context).takeUnretainedValue().toggle?()
                return noErr
            }, 1, &type, context, &handler)
            guard installed == noErr else { handler = nil; return .failure(.failed(installed)) }
        }
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, Self.hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr else {
            hotKey = nil
            disable()
            return .failure(status == OSStatus(eventHotKeyExistsErr) ? .inUse : .failed(status))
        }
        registered = shortcut
        return .success(())
    }

    func disable() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        registered = nil
    }
    deinit { disable() }
}
