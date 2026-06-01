import AppKit
import CoreText

/// Rasterizes a single character into a grayscale coverage bitmap sized to the
/// full cell (1 cell wide, or 2 for wide/CJK), at the backing scale for retina
/// crispness. Uses CoreText (`CTLine`), so font substitution for CJK/Nerd-Font
/// glyphs the base font lacks happens automatically.
///
/// Rasterizing into the full cell (rather than a tight bbox) trades atlas space
/// for simplicity: the render quad is exactly the cell rect, no per-glyph
/// bearing math. Atlas growth/eviction is a later optimization.
final class GlyphRasterizer {
    private let font: NSFont
    private let boldFont: NSFont
    private let cellW: CGFloat
    private let cellH: CGFloat
    private let scale: CGFloat
    /// Baseline distance from the cell's top, in points.
    private let baseline: CGFloat
    private let gray = CGColorSpaceCreateDeviceGray()

    struct Bitmap {
        var bytes: [UInt8]
        var width: Int
        var height: Int
    }

    init(font: NSFont, cellW: CGFloat, cellH: CGFloat, scale: CGFloat) {
        self.font = font
        self.boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        self.cellW = cellW
        self.cellH = cellH
        self.scale = max(scale, 1)
        // Center the ascent+descent box vertically in the cell; baseline sits
        // ascent below the box top. Approximates NSTextView; pixel-tunable.
        let ascent = font.ascender
        let descent = -font.descender
        let topGap = max(0, (cellH - (ascent + descent)) / 2)
        self.baseline = (topGap + ascent).rounded()
    }

    /// Coverage bitmap for `ch`, or nil for blanks / un-rasterizable glyphs.
    func raster(_ ch: Character, bold: Bool, wide: Bool) -> Bitmap? {
        if ch == " " || ch == "\u{00A0}" { return nil }
        let f = bold ? boldFont : font
        let glyphCellW = wide ? cellW * 2 : cellW
        let pw = Int(ceil(glyphCellW * scale))
        let ph = Int(ceil(cellH * scale))
        guard pw > 0, ph > 0 else { return nil }

        var data = [UInt8](repeating: 0, count: pw * ph)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: pw, height: ph, bitsPerComponent: 8,
                bytesPerRow: pw, space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.setShouldAntialias(true)
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldSmoothFonts(false)   // grayscale coverage, not subpixel
            ctx.scaleBy(x: scale, y: scale)   // henceforth work in points
            // White glyph on black → byte value == coverage.
            let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.white]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: String(ch), attributes: attrs))
            // y-up context of height `cellH` points: baseline from bottom.
            ctx.textPosition = CGPoint(x: 0, y: cellH - baseline)
            CTLineDraw(line, ctx)
            return true
        }
        guard ok else { return nil }
        // Skip fully-empty rasters (e.g. zero-width / unsupported) so the atlas
        // caches them as "nothing to draw".
        if !data.contains(where: { $0 != 0 }) { return nil }
        return Bitmap(bytes: data, width: pw, height: ph)
    }
}
