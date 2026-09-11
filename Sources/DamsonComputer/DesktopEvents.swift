import CoreGraphics

/// Event construction is separate from posting so modifier and coordinate
/// regressions can be checked without taking over the user's desktop.
struct DesktopEvents {
    private let source = CGEventSource(stateID: .privateState)

    func mouse(_ kind: CGEventType, at point: CGPoint) throws -> CGEvent {
        guard let event = CGEvent(mouseEventSource: source, mouseType: kind,
                                  mouseCursorPosition: point, mouseButton: .left) else {
            throw ComputerFailure("input", "Cannot create mouse event.")
        }
        event.flags = []
        return event
    }

    func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = []) throws -> CGEvent {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
            throw ComputerFailure("input", "Cannot create keyboard event.")
        }
        event.flags = down ? flags : []
        return event
    }

    func unicode(_ units: [UniChar], down: Bool) throws -> CGEvent {
        guard !units.isEmpty, units.count <= 64 else {
            throw ComputerFailure("invalid_argument", "Unicode events require 1...64 UTF-16 units.")
        }
        let event = try key(0, down: down)
        units.withUnsafeBufferPointer {
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress!)
        }
        return event
    }

    func scroll(dx: Int32, dy: Int32, at point: CGPoint) throws -> CGEvent {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: dy, wheel2: dx, wheel3: 0) else {
            throw ComputerFailure("input", "Cannot create scroll event.")
        }
        event.location = point
        event.flags = []
        return event
    }
}
