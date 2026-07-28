import Foundation
import QuartzCore

/// Opt-in tracing for tab-transition frame timing: `DAMSON_SWIPE_LOG=1`.
///
/// A tab transition hands the screen from a still image to a live surface, and whether that
/// looks seamless depends on the order of three things that are not ordered with respect to
/// each other: the CATransaction that removes the cover, the render that encodes the incoming
/// tree's first frame, and the GPU actually presenting it. No profiler correlates those on one
/// axis, so this puts them on a single monotonic clock.
///
/// It exists because guessing here produced a magic constant that was wrong: the trace showed
/// frames reaching the screen 100–250 ms after they were encoded, because starting the next
/// swipe runs a synchronous full-window GPU readback for its snapshot. Keep it for the next
/// person who hits a frame-timing bug in this path.
///
/// Off unless the env var is set to something truthy — one static `Bool` load on the render
/// path, with `@autoclosure` payloads, so it costs nothing when disabled.
public enum SwipeLog {
    public static let enabled: Bool = {
        guard let v = ProcessInfo.processInfo.environment["DAMSON_SWIPE_LOG"] else { return false }
        // Parse the value: the variable is inherited by every process spawned from a Damson
        // terminal, so a stale `export DAMSON_SWIPE_LOG=0` must not turn tracing on.
        return !["0", "", "no", "false", "off"].contains(v.lowercased())
    }()

    private static let start = CACurrentMediaTime()
    /// Writes are serialized here: `frame.ON_SCREEN` is emitted from Metal's presented-handler
    /// thread, concurrently with main-thread lines, and an interleaved timeline is useless
    /// under exactly the load it is meant to measure.
    private static let queue = DispatchQueue(label: "damson.swipelog")

    /// Milliseconds since first use, so lines from the view, the backend and the coordinator
    /// read as one timeline.
    public static func now() -> Double { (CACurrentMediaTime() - start) * 1000 }

    public static func log(_ tag: String, _ message: @autoclosure () -> String = "") {
        guard enabled else { return }
        let line = String(format: "[swipe %10.2fms] %-22@ %@\n",
                          now(), tag as NSString, message() as NSString)
        queue.async {
            // `write(contentsOf:)` throws instead of raising, so a closed stderr (`… | head`)
            // cannot kill the process from a debug path.
            try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
        }
    }
}
