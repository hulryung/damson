import AppKit
import ApplicationServices

@MainActor
public final class DesktopAccess {
    private var elements: [String: AXUIElement] = [:]
    private let events = DesktopEvents()
    public static let eventTag: Int64 = 0x44414D534F4E

    public init() {}

    public func permissions(prompt: Bool = false, destination: ComputerPrivacySettings? = nil) -> [String: Any] {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt && destination != .screenRecording] as CFDictionary
        let accessibility = AXIsProcessTrustedWithOptions(options)
        let screen = CGPreflightScreenCaptureAccess()
        if prompt, destination != .accessibility, !screen { _ = CGRequestScreenCaptureAccess() }
        return ["accessibility": accessibility, "screenRecording": screen,
                "helperBundle": Bundle.main.bundleIdentifier ?? "unbundled",
                "helperPath": Bundle.main.bundlePath]
    }

    public func apps() -> [[String: Any]] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map {
            ["pid": $0.processIdentifier, "name": $0.localizedName ?? "",
             "bundleID": $0.bundleIdentifier ?? "", "active": $0.isActive]
        }
    }

    public func app(_ pid: Int32) throws -> NSRunningApplication {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.activationPolicy == .regular, app.launchDate != nil else {
            throw ComputerFailure("target_gone", "Target PID is not a live GUI application.")
        }
        return app
    }

    public func identity(_ pid: Int32) throws -> String {
        let running = try app(pid)
        return "\(running.launchDate!.timeIntervalSince1970):\(running.bundleURL?.path ?? "")"
    }

    public func validate(_ session: ComputerSession, foreground: Bool = false) throws {
        guard try identity(session.targetPID) == session.targetStarted else {
            throw ComputerFailure("target_gone", "Target app exited or its PID was reused. Acquire a new session.")
        }
        if foreground, NSWorkspace.shared.frontmostApplication?.processIdentifier != session.targetPID {
            throw ComputerFailure("focus_changed", "Target app is not frontmost. Observe and explicitly focus it before input.")
        }
    }

    public func windows(pid: Int32) -> [[String: Any]] {
        windowRecords().filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
            .compactMap { record in
                guard let id = record[kCGWindowNumber as String] as? UInt32,
                      let bounds = bounds(record) else { return nil }
                return ["id": id, "title": record[kCGWindowName as String] as? String ?? "",
                        "bounds": rect(bounds)]
            }
    }

    public func focus(_ session: ComputerSession) throws {
        try validate(session)
        guard try app(session.targetPID).activate(options: [.activateIgnoringOtherApps]) else {
            throw ComputerFailure("focus_failed", "macOS did not activate the target app.")
        }
    }

    public func inspect(_ session: ComputerSession) throws -> [String: Any] {
        try requireAccessibility()
        try validate(session)
        elements.removeAll()
        let root = AXUIElementCreateApplication(session.targetPID)
        AXUIElementSetMessagingTimeout(root, 0.4)
        var remaining = 300
        let deadline = Date().addingTimeInterval(3)
        let tree = node(root, depth: 0, remaining: &remaining, deadline: deadline)
        return ["tree": tree, "truncated": remaining == 0 || Date() >= deadline,
                "coordinateSystem": "global desktop points; origin at primary display top-left"]
    }

    public func clearElements() { elements.removeAll() }

    public func press(_ reference: String, session: ComputerSession) throws {
        try requireAccessibility()
        try validate(session, foreground: true)
        guard let element = elements[reference] else {
            throw ComputerFailure("stale_element", "Unknown element. Inspect the current session again.")
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == session.targetPID else {
            throw ComputerFailure("stale_element", "Element no longer belongs to the target app.")
        }
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else { throw ComputerFailure("accessibility", "AXPress failed: \(result.rawValue). Inspect before retrying.") }
    }

    public func click(x: Double, y: Double, session: ComputerSession) throws {
        try requireAccessibility()
        try validate(session, foreground: true)
        let point = CGPoint(x: x, y: y)
        guard x.isFinite, y.isFinite, targetAtPoint(point, pid: session.targetPID) else {
            throw ComputerFailure("target_occluded", "The point is not on an exposed window of the target app.")
        }
        for kind: CGEventType in [.leftMouseDown, .leftMouseUp] {
            post(try events.mouse(kind, at: point))
        }
    }

    public func type(_ text: String, session: ComputerSession, authorize: () throws -> Void) async throws {
        try requireAccessibility()
        try validate(session, foreground: true)
        guard text.utf16.count <= 4096 else { throw ComputerFailure("invalid_argument", "Text is limited to 4096 UTF-16 units per call.") }
        // Use Unicode events instead of the clipboard; preserve the user's clipboard.
        // Chunk on Character boundaries, never between a surrogate pair.
        let characters = text.map { Array(String($0).utf16) }
        guard characters.allSatisfy({ $0.count <= 64 }) else {
            throw ComputerFailure("invalid_argument", "A character exceeds the Unicode event limit.")
        }
        for units in characters {
            try authorize()
            try validate(session, foreground: true)
            for down in [true, false] {
                post(try events.unicode(units, down: down))
            }
            // Let the target process input and let physical user input revoke this
            // session between characters instead of queuing thousands of events.
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    public func key(_ name: String, session: ComputerSession) throws {
        try requireAccessibility()
        try validate(session, foreground: true)
        let parts = name.lowercased().split(separator: "+").map(String.init)
        guard let last = parts.last, let code = Self.keys[last] else {
            throw ComputerFailure("invalid_argument", "Unknown key. Use named keys such as enter, left, space, or cmd+a.")
        }
        var flags: CGEventFlags = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd": flags.insert(.maskCommand)
            case "ctrl": flags.insert(.maskControl)
            case "alt", "option": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            default: throw ComputerFailure("invalid_argument", "Unknown key modifier: \(modifier)")
            }
        }
        for down in [true, false] {
            post(try events.key(code, down: down, flags: flags))
        }
    }

    public func scroll(dx: Int32, dy: Int32, session: ComputerSession) throws -> [String: Any] {
        try requireAccessibility()
        try validate(session, foreground: true)
        guard abs(Int64(dx)) <= 2000, abs(Int64(dy)) <= 2000 else {
            throw ComputerFailure("invalid_argument", "Scroll deltas must be within -2000...2000 pixels.")
        }
        let point = CGEvent(source: nil)?.location ?? .zero
        guard targetAtPoint(point, pid: session.targetPID) else {
            throw ComputerFailure("target_occluded", "Place the pointer on the target with a click before scrolling.")
        }
        let event = try events.scroll(dx: dx, dy: dy, at: point)
        // Let WindowServer resolve global coordinates into the hit-tested window.
        post(event)
        return ["dispatched": true, "verificationRequired": true, "x": point.x, "y": point.y]
    }

    private func targetAtPoint(_ point: CGPoint, pid: Int32) -> Bool {
        guard windowRecords().contains(where: {
            $0[kCGWindowOwnerPID as String] as? Int32 == pid && bounds($0)?.contains(point) == true
        }) else { return false }
        // Window-list z-order includes transparent, click-through Dock overlays.
        // Accessibility hit testing reports the element that actually receives input.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.4)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              let element else { return false }
        var owner: pid_t = 0
        if AXUIElementGetPid(element, &owner) == .success && owner == pid { return true }
        // WebKit exposes content through a separate accessibility process. Only
        // accept it when its containing AX window belongs to the leased app.
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return false }
        let window = unsafeBitCast(windowValue, to: AXUIElement.self)
        return AXUIElementGetPid(window, &owner) == .success && owner == pid
    }

    private func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        event.post(tap: .cghidEventTap)
    }

    private func requireAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw ComputerFailure("permission_required", "Enable Accessibility for Damson Computer in System Settings, then retry.")
        }
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    private func node(_ element: AXUIElement, depth: Int, remaining: inout Int, deadline: Date) -> [String: Any] {
        guard remaining > 0, depth < 12, Date() < deadline else { return ["truncated": true] }
        remaining -= 1
        let id = UUID().uuidString
        elements[id] = element
        var result: [String: Any] = ["id": id]
        for key in [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXEnabledAttribute] {
            if let value = attribute(element, key) {
                if let string = value as? String { result[key] = String(string.prefix(1024)) } else if let number = value as? NSNumber { result[key] = number }
            }
        }
        if let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
           let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() {
            var point = CGPoint.zero
            var extent = CGSize.zero
            if AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
               AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &extent) {
                result["bounds"] = rect(CGRect(origin: point, size: extent))
            }
        }
        let secure = result[kAXSubroleAttribute] as? String == kAXSecureTextFieldSubrole
        if !secure, let value = attribute(element, kAXValueAttribute) as? String {
            result["AXValue"] = String(value.prefix(2048))
        }
        var actions: CFArray?
        if AXUIElementCopyActionNames(element, &actions) == .success { result["actions"] = actions as? [String] ?? [] }
        if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            var output: [[String: Any]] = []
            for child in children where remaining > 0 && Date() < deadline {
                output.append(node(child, depth: depth + 1, remaining: &remaining, deadline: deadline))
            }
            result["children"] = output
        }
        return result
    }

    private func windowRecords() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0 }
    }

    private func bounds(_ record: [String: Any]) -> CGRect? {
        guard let value = record[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: value as CFDictionary)
    }

    func rect(_ value: CGRect) -> [String: Double] {
        ["x": value.origin.x, "y": value.origin.y, "width": value.width, "height": value.height]
    }

    private static let keys: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "enter": 36, "tab": 48, "space": 49, "backspace": 51, "esc": 53, "delete": 117,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126
    ]
}
