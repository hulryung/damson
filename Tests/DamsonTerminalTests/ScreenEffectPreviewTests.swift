import AppKit
import XCTest
@testable import DamsonTerminal

/// Visual preview sheets for the animated screen effects (rain / snow /
/// underwater): render a code-like grid through the real pipeline + post-fx
/// pass at a few frozen shader clocks and write PNGs for eyeballing. Asserts
/// only that the effect actually changed pixels vs. the plain render and that
/// frames at different times differ (i.e. the effect animates).
///
/// Output: `$DAMSON_SHOT_DIR` (default /tmp) — damson_fx_<effect>_t<n>.png
final class ScreenEffectPreviewTests: XCTestCase {

    private func measuredLineHeight(_ font: NSFont) -> CGFloat {
        let lm = NSLayoutManager()
        let storage = NSTextStorage(string: "M\nM\nM", attributes: [.font: font])
        storage.addLayoutManager(lm)
        let container = NSTextContainer(size: NSSize(width: 10000, height: 10000))
        lm.addTextContainer(container)
        lm.ensureLayout(for: container)
        return lm.usedRect(for: container).height / 3.0
    }

    private func put(_ grid: Grid, _ s: String) { for ch in s { grid.putChar(ch) } }

    /// A grid that looks like a working terminal — prompt lines, code, ls
    /// columns — so refraction/fog effects have realistic content to distort.
    private func makeGrid(cols: Int, rows: Int) -> Grid {
        let grid = Grid(cols: cols, rows: rows, pen: CellAttrs(fg: .default))
        let lines = [
            "$ swift build -c release",
            "Building for production...",
            "[42/42] Compiling DamsonTerminal Grid.swift",
            "Build complete! (3.21s)",
            "$ ls -la Sources/DamsonTerminal/MetalRender/",
            "-rw-r--r--  GlyphAtlas.swift     GlyphRasterizer.swift",
            "-rw-r--r--  MetalShaders.swift   ScreenEffect.swift",
            "-rw-r--r--  ScrollModel.swift    RenderTypes.swift",
            "$ git log --oneline -3",
            "605085b Fix circled digits rendering half-clipped",
            "79f03bc docs: translate all Korean docs to English",
            "$ echo \"한글 width ④ fallback 😀 emoji\"",
            "한글 width ④ fallback 😀 emoji",
            "$ ",
        ]
        for (i, s) in lines.enumerated() where i < rows {
            grid.setCursor(row: i, col: 0)
            if s.hasPrefix("$") { grid.applySGR([1, 32]) }   // bold green prompt
            put(grid, s)
            grid.applySGR([0])
        }
        grid.setCursorVisible(false)
        return grid
    }

    private func render(effect: ScreenEffect, time: Float?,
                        cols: Int = 64, rows: Int = 14) throws -> CGImage {
        let config = DamsonConfig(fontFamily: "Menlo", fontSize: 13,
                                  screenEffect: effect, screenEffectIntensity: 1.0)
        let backend = try XCTUnwrap(MetalTerminalBackend(config: config))
        backend.effectTimeOverride = time
        let grid = makeGrid(cols: cols, rows: rows)
        let font = fontWithNerdFallback(family: config.fontFamily, size: config.fontSize)
        let metrics = CellMetrics(
            width: max(("M" as NSString).size(withAttributes: [.font: font]).width, 1),
            height: max(measuredLineHeight(font), 1))
        return try XCTUnwrap(backend.renderToCGImage(
            grid: grid, config: config, state: RenderState(),
            metrics: metrics, cols: cols, rows: rows, scale: 2))
    }

    private func pngWrite(_ cg: CGImage, _ name: String) throws -> String {
        let dir = ProcessInfo.processInfo.environment["DAMSON_SHOT_DIR"] ?? "/tmp"
        let rep = NSBitmapImageRep(cgImage: cg)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let path = "\(dir)/\(name)"
        try png.write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Mean absolute per-channel difference across a sampled pixel grid.
    private func meanDiff(_ a: CGImage, _ b: CGImage) -> Double {
        let ra = NSBitmapImageRep(cgImage: a), rb = NSBitmapImageRep(cgImage: b)
        var sum = 0.0, count = 0
        let stepX = max(1, a.width / 160), stepY = max(1, a.height / 160)
        for y in stride(from: 0, to: min(a.height, b.height), by: stepY) {
            for x in stride(from: 0, to: min(a.width, b.width), by: stepX) {
                guard let ca = ra.colorAt(x: x, y: y), let cb = rb.colorAt(x: x, y: y)
                else { continue }
                sum += abs(ca.redComponent - cb.redComponent)
                    + abs(ca.greenComponent - cb.greenComponent)
                    + abs(ca.blueComponent - cb.blueComponent)
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : 0
    }

    func testAnimatedEffectSheets() throws {
        guard MetalDevice.shared != nil else {
            throw XCTSkip("Metal device unavailable (headless CI)")
        }
        let plain = try render(effect: .none, time: nil)
        var paths: [String] = []
        for effect in ScreenEffect.allCases where effect.isAnimated {
            var frames: [CGImage] = []
            for (i, t) in [Float(0.8), 2.9, 5.3].enumerated() {
                let cg = try render(effect: effect, time: t)
                frames.append(cg)
                paths.append(try pngWrite(cg, "damson_fx_\(effect.rawValue)_t\(i).png"))
            }
            // The effect must visibly change the frame…
            XCTAssertGreaterThan(meanDiff(plain, frames[0]), 0.004,
                                 "\(effect) had no visible influence")
            // …and must move over time (animated, not a static overlay).
            XCTAssertGreaterThan(meanDiff(frames[0], frames[1]), 0.0008,
                                 "\(effect) did not animate between clocks")
        }
        print("DAMSON_FX_SHEETS:\n" + paths.joined(separator: "\n"))
    }
}
