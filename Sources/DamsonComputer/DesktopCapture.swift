import AppKit
import ScreenCaptureKit

extension DesktopAccess {
    public func capture(_ session: ComputerSession, windowID: UInt32, authorize: () throws -> Void) async throws -> [String: Any] {
        try validate(session)
        guard CGPreflightScreenCaptureAccess() else {
            throw ComputerFailure("permission_required", "Enable Screen Recording for Damson Computer in System Settings and restart the helper if requested.")
        }
        if #available(macOS 14.0, *) {
            let content: SCShareableContent = try await boundedCapture { done in
                SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true, completionHandler: done)
            }
            try authorize()
            guard let window = content.windows.first(where: {
                $0.windowID == windowID && $0.owningApplication?.processID == session.targetPID
            }) else { throw ComputerFailure("window_gone", "Window is not a visible window of this session's app.") }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let scale = min(Double(filter.pointPixelScale), 4096 / max(filter.contentRect.width, filter.contentRect.height, 1))
            config.width = max(1, Int(filter.contentRect.width * scale))
            config.height = max(1, Int(filter.contentRect.height * scale))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let image: CGImage = try await boundedCapture { done in
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: config, completionHandler: done)
            }
            try authorize()
            try validate(session)
            return try save(image, frame: window.frame, session: session, windowID: windowID)
        } else {
            guard let record = windows(pid: session.targetPID).first(where: { $0["id"] as? UInt32 == windowID }),
                  let frame = record["bounds"] as? [String: Double],
                  let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]) else {
                throw ComputerFailure("capture_failed", "Could not capture this target window.")
            }
            return try save(image, frame: CGRect(x: frame["x"]!, y: frame["y"]!, width: frame["width"]!, height: frame["height"]!),
                            session: session, windowID: windowID)
        }
    }

    private func save(_ image: CGImage, frame: CGRect, session: ComputerSession, windowID: UInt32) throws -> [String: Any] {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ComputerFailure("capture_failed", "Could not encode PNG.")
        }
        let path = URL(fileURLWithPath: session.artifacts).appendingPathComponent("capture-\(UUID().uuidString).png")
        try data.write(to: path, options: .atomic)
        return ["path": path.path, "windowID": windowID, "bounds": rect(frame),
                "pixelWidth": image.width, "pixelHeight": image.height,
                "scaleX": Double(image.width) / frame.width, "scaleY": Double(image.height) / frame.height,
                "coordinateSystem": "global desktop points; click x=bounds.x+pixelX/scaleX, y=bounds.y+pixelY/scaleY"]
    }
}

// A stalled WindowServer must not hold the desktop forever. Late callbacks are
// discarded; cancellation does not start another capture or save an orphan image.
@MainActor
private final class CaptureReply<T> {
    var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func finish(_ value: T?, _ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let value { continuation.resume(returning: value) } else { continuation.resume(throwing: error ?? ComputerFailure("capture_failed", "Capture returned no image.")) }
    }
}

@MainActor
private func boundedCapture<T>(_ start: (@escaping @Sendable (T?, Error?) -> Void) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let reply = CaptureReply(continuation)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            reply.finish(nil, ComputerFailure("capture_timeout", "Screen capture timed out. Observe the helper status before retrying."))
        }
        start { value, error in Task { @MainActor in reply.finish(value, error) } }
    }
}
