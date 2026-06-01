import AppKit
import Metal

/// On-demand glyph coverage atlas: an R8 texture packed shelf-style, with a
/// `(char, bold) → UV region` cache. Rasterizes a glyph on first use and uploads
/// it. Tied to one font + cell size + scale; the backend rebuilds the atlas when
/// any of those change.
///
/// Phase 1: a single fixed-size page, no eviction. Growth/LRU is a later step;
/// if the page fills, further new glyphs are skipped (logged) rather than wrong.
final class GlyphAtlas {
    let texture: MTLTexture
    private let width: Int
    private let height: Int
    private let shelfHeight: Int   // == cell height in px (uniform shelves)
    private let rasterizer: GlyphRasterizer

    /// nil value = rasterized but nothing to draw (blank). Cached to avoid retry.
    private var regions: [GlyphKey: GlyphInstanceUV?] = [:]
    private var cursorX = 0
    private var cursorY = 0
    private var full = false

    private struct GlyphKey: Hashable {
        var ch: Character
        var bold: Bool
    }

    struct GlyphInstanceUV {
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
    }

    init?(device: MTLDevice, font: NSFont, cellW: CGFloat, cellH: CGFloat, scale: CGFloat) {
        let side = 2048
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: side, height: side, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .managed
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        self.texture = tex
        self.width = side
        self.height = side
        self.shelfHeight = max(1, Int(ceil(cellH * max(scale, 1))))
        self.rasterizer = GlyphRasterizer(font: font, cellW: cellW, cellH: cellH, scale: scale)
    }

    /// UV region for a glyph, rasterizing+packing on first use. nil = draw nothing.
    func region(for ch: Character, bold: Bool, wide: Bool) -> GlyphInstanceUV? {
        let key = GlyphKey(ch: ch, bold: bold)
        if let cached = regions[key] { return cached }   // includes cached-nil blanks
        guard !full, let bmp = rasterizer.raster(ch, bold: bold, wide: wide) else {
            regions[key] = .some(nil)
            return nil
        }
        // Shelf pack (all shelves are one cell-height tall).
        if cursorX + bmp.width > width {
            cursorX = 0
            cursorY += shelfHeight
        }
        if cursorY + bmp.height > height {
            full = true
            NSLog("Halite: glyph atlas full")
            regions[key] = .some(nil)
            return nil
        }
        bmp.bytes.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(cursorX, cursorY, bmp.width, bmp.height),
                mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: bmp.width)
        }
        let uv = GlyphInstanceUV(
            origin: SIMD2<Float>(Float(cursorX) / Float(width), Float(cursorY) / Float(height)),
            size: SIMD2<Float>(Float(bmp.width) / Float(width), Float(bmp.height) / Float(height)))
        cursorX += bmp.width
        regions[key] = .some(uv)
        return uv
    }
}
