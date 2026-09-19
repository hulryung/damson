import AppKit
import XCTest
@testable import DamsonTerminal

/// A box drawn by a TUI must look the same no matter how many lines have scrolled
/// off above it.
///
/// The renderer snaps each row's CONTENT position to the device-pixel grid, then
/// subtracts `scrollY`. With a font whose cell height is not a whole number of
/// device pixels (Sarasa Mono K 14 → 35.96px at 2×), a followed TUI's rest position
/// (`scrollback.count * cellH + inset`) is itself fractional, so the subtraction
/// throws the snapped positions back off the pixel grid — by a DIFFERENT fraction
/// for every scrolled line. The 1px-thick strokes of box-drawing glyphs then get
/// resampled across two pixel rows, and their peak coverage drops by half: the
/// border visibly thins out and looks like it is disappearing as the screen scrolls.
final class ScrollPixelAlignmentTests: XCTestCase {

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

    /// A font whose cell height is NOT a whole number of device pixels — the
    /// precondition for the misalignment. Menlo's metrics are integral at every
    /// size, so it can never show this.
    private func fractionalCellFont(scale: CGFloat) -> (NSFont, CGFloat)? {
        let candidates: [(String, CGFloat)] = [
            ("Sarasa Mono K", 14), ("D2Coding", 14), ("Menlo", 14.5), ("Monaco", 13.5),
        ]
        for (name, size) in candidates {
            guard let f = NSFont(name: name, size: size) else { continue }
            let h = measuredLineHeight(f)
            let px = h * scale
            if abs(px - px.rounded()) > 0.05 { return (f, h) }
        }
        return nil
    }

    /// Peak per-pixel-row coverage of a horizontal box rule, at a series of
    /// followed-TUI rest positions (one per line scrolled off the top).
    func testBoxRuleKeepsItsCoverageAsLinesScrollOff() throws {
        guard MetalDevice.shared != nil else { throw XCTSkip("Metal device unavailable") }
        let scale: CGFloat = 2
        guard let (font, cellH) = fractionalCellFont(scale: scale) else {
            throw XCTSkip("no font with a fractional device-pixel cell height installed")
        }
        let config = DamsonConfig(fontFamily: font.familyName ?? font.fontName,
                                  fontSize: font.pointSize)
        guard let backend = MetalTerminalBackend(config: config) else {
            throw XCTSkip("Metal backend init failed")
        }
        let cellW = max(("M" as NSString).size(withAttributes: [.font: font]).width, 1)
        // The host quantises the row height to whole device pixels before handing
        // metrics to a backend — mirror that here so the image matches the app.
        let rowH = CellMetrics.deviceAlignedHeight(cellH, scale: scale)
        let metrics = CellMetrics(width: cellW, height: rowH)
        let inset = config.padding.height

        let cols = 24, rows = 8
        let ruleRow = 2          // viewport row holding the box's top rule

        var peaks: [CGFloat] = []
        var spans: [Int] = []
        for scrolled in 0..<10 {
            let grid = Grid(cols: cols, rows: rows, pen: CellAttrs(fg: .default))
            // Push `scrolled` lines off the top, exactly as output scrolling does.
            grid.setCursor(row: rows, col: 1)
            for _ in 0..<scrolled { grid.lineFeed() }
            // A box, the way a TUI draws one.
            grid.setCursor(row: ruleRow + 1, col: 1)
            put(grid, "┌" + String(repeating: "─", count: cols - 2) + "┐")
            grid.setCursor(row: ruleRow + 2, col: 1)
            put(grid, "│" + String(repeating: " ", count: cols - 2) + "│")
            grid.setCursor(row: ruleRow + 3, col: 1)
            put(grid, "└" + String(repeating: "─", count: cols - 2) + "┘")
            grid.setCursorVisible(false)

            // The rest position a followed TUI is pinned to.
            let scrollY = CGFloat(grid.scrollback.count) * rowH + inset
            let image = backend.renderToCGImage(grid: grid, config: config, state: RenderState(),
                                                metrics: metrics, cols: cols, rows: rows,
                                                scale: scale, scrollY: scrollY)
            let cg = try XCTUnwrap(image)
            let rep = NSBitmapImageRep(cgImage: cg)

            // Scan the pixel rows covering the rule's cell and take the strongest
            // one. A pixel-aligned stroke lands wholly inside one row; a
            // half-pixel-offset one is split across two and peaks at about half.
            let bg = config.theme.background.usingColorSpace(.sRGB)!
            let x = Int(((CGFloat(cols) / 2) * cellW + config.padding.width) * scale)
            let top = Int((CGFloat(ruleRow) * rowH) * scale)
            let bot = min(cg.height - 1, Int((CGFloat(ruleRow + 1) * rowH) * scale))
            var peak: CGFloat = 0
            var lit = 0
            for y in top...bot {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let d = abs(c.redComponent - bg.redComponent)
                    + abs(c.greenComponent - bg.greenComponent)
                    + abs(c.blueComponent - bg.blueComponent)
                peak = max(peak, d)
                if d > 0.15 { lit += 1 }
            }
            peaks.append(peak)
            spans.append(lit)
        }

        let best = peaks.max() ?? 0
        let worst = peaks.min() ?? 0
        print(String(format: "box-rule peak coverage per scrolled line: %@  (best %.3f, worst %.3f)",
                     peaks.map { String(format: "%.2f", $0) }.joined(separator: " "), best, worst))
        print("box-rule pixel rows lit per scrolled line: \(spans)")
        XCTAssertGreaterThan(best, 0.05, "the rule never drew at all — test is measuring nothing")
        // Every rest position must render the rule IDENTICALLY. Before the fix the
        // stroke drifted across the pixel grid line by line: peaks spread over
        // 2.34…2.57 and the stroke smeared across 4 pixel rows instead of 3.
        XCTAssertLessThan(best - worst, 0.02,
                          "the box rule changes weight as lines scroll off: \(peaks)")
        XCTAssertEqual(Set(spans).count, 1,
                       "the box rule changes thickness as lines scroll off: \(spans)")
    }
}
