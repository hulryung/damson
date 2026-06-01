import AppKit
import CoreText

/// Rasterizes a single character into a grayscale coverage bitmap sized to the
/// full cell (1 cell wide, or 2 for wide/CJK), at the backing scale for retina
/// crispness.
///
/// **Minimal fallback policy.** The configured base font draws everything it can.
/// The *only* fallback is for East-Asian (CJK) characters the base font lacks —
/// those come from `cjkFallbackFont` (D2Coding 계열). Glyph lookup is a direct
/// per-font cmap query (`CTFontGetGlyphsForCharacters`), which does NOT honor
/// `NSFont.cascadeList`; the CJK fallback is therefore resolved explicitly here so
/// it matches the legacy backend's cascade font exactly. A non-CJK character the
/// base font lacks is left blank (tofu) on purpose, keeping the base font's
/// coverage visible instead of masking it with broad substitution.
///
/// Rasterizing into the full cell (rather than a tight bbox) trades atlas space
/// for simplicity: the render quad is exactly the cell rect, no per-glyph
/// bearing math. Atlas growth/eviction is a later optimization.
final class GlyphRasterizer {
    private let font: NSFont
    private let boldFont: NSFont
    /// CJK-only fallback face (e.g. D2CodingLigature Nerd Font Mono); nil if none
    /// installed. Used solely for East-Asian glyphs the base font lacks.
    private let cjkFont: NSFont?
    private let boldCJKFont: NSFont?
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
        let cjk = cjkFallbackFont(size: font.pointSize)
        self.cjkFont = cjk
        self.boldCJKFont = cjk.map { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) }
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

    /// Coverage bitmap for `ch`, or nil for blanks / unrenderable glyphs.
    ///
    /// Base font first; the only fallback is the CJK face for East-Asian glyphs
    /// the base font lacks (gated on `Cell.isWide`). Any other missing glyph stays
    /// blank (tofu) — see the type doc for the minimal-fallback rationale.
    func raster(_ ch: Character, bold: Bool, wide: Bool) -> Bitmap? {
        if ch == " " || ch == "\u{00A0}" { return nil }
        if let bmp = draw(ch, in: bold ? boldFont : font, wide: wide) {
            return bmp
        }
        // CJK 전용 fallback: base가 못 그린 동아시아 글자만.
        if Cell.isWide(ch), let cjk = bold ? boldCJKFont : cjkFont {
            return draw(ch, in: cjk, wide: wide)
        }
        return nil
    }

    /// Rasterize `ch` with `f`, or nil if `f`'s own cmap lacks the glyph (a direct
    /// per-font query — `NSFont.cascadeList` is intentionally not consulted).
    private func draw(_ ch: Character, in f: NSFont, wide: Bool) -> Bitmap? {
        let ctFont = f as CTFont

        // Normalize to precomposed (NFC). The terminal can receive decomposed
        // Hangul (NFD Jamo) — e.g. syllables with a final consonant (받침) arrive
        // as 초성+중성+종성 — and a per-glyph cmap lookup can't compose Jamo, so it
        // would draw 2–3 separate Jamo or, lacking a 종성 glyph, render nothing.
        // Composing to the single precomposed syllable (U+AC00…D7A3) draws one
        // correct glyph, matching the legacy CTLine/NSAttributedString path.
        let utf16 = Array(String(ch).precomposedStringWithCanonicalMapping.utf16)
        guard !utf16.isEmpty else { return nil }
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        let hasAll = utf16.withUnsafeBufferPointer { buf in
            CTFontGetGlyphsForCharacters(ctFont, buf.baseAddress!, &glyphs, utf16.count)
        }
        guard hasAll else { return nil }   // this font lacks the glyph

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
            ctx.scaleBy(x: scale, y: scale)   // work in points
            ctx.setFillColor(CGColor(gray: 1.0, alpha: 1.0))   // white = full coverage

            // Position each glyph at the baseline (y-up: cellH − baseline from
            // bottom), accumulating advances for multi-glyph clusters.
            var advances = [CGSize](repeating: .zero, count: glyphs.count)
            CTFontGetAdvancesForGlyphs(ctFont, .horizontal, glyphs, &advances, glyphs.count)
            var positions = [CGPoint](repeating: .zero, count: glyphs.count)
            var x: CGFloat = 0
            for i in glyphs.indices {
                positions[i] = CGPoint(x: x, y: cellH - baseline)
                x += advances[i].width
            }
            CTFontDrawGlyphs(ctFont, glyphs, positions, glyphs.count, ctx)
            return true
        }
        guard ok else { return nil }
        if !data.contains(where: { $0 != 0 }) { return nil }
        return Bitmap(bytes: data, width: pw, height: ph)
    }
}
