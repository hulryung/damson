#!/usr/bin/env swift
// gen-dmg-background.swift — generates the installer window artwork for the .dmg.
//
// Writes Resources/dmg/background.png (640×420), @2x, and the multi-resolution
// background.tiff that Finder reads. No external dependencies beyond tiffutil.
//
// build: swift scripts/gen-dmg-background.swift
//
// Palette and lightness are not free choices. Finder draws the icon labels in the
// VIEWER's appearance — black in light mode, white in dark mode — and gives them no
// backdrop, so a dark background hides the labels for light-mode users and a light
// one hides them in dark mode. The field the two icons stand on therefore stays a
// mid-tone (relative luminance ≈0.19), which keeps both label colors above a 4.3:1
// contrast ratio. The dark header is the one place no label is ever drawn, so the
// brand's Tokyo Night plum lives there.

import AppKit

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
// Damson-1024.png is a local build product (gitignored); Damson.icns is committed,
// so a fresh clone can still regenerate the artwork.
let iconURL: URL = {
    let png = repoRoot.appendingPathComponent("Resources/Damson-1024.png")
    return FileManager.default.fileExists(atPath: png.path)
        ? png : repoRoot.appendingPathComponent("Resources/Damson.icns")
}()
let outDir = repoRoot.appendingPathComponent("Resources/dmg")

// Window content size, in points. The .DS_Store window bounds must match.
let W: CGFloat = 640, H: CGFloat = 400
let headerH: CGFloat = 120          // dark band across the top
// Icon slot centres, measured from the TOP-left like Finder's icon positions.
let appSlot = CGPoint(x: 168, y: 214)
let appsSlot = CGPoint(x: 472, y: 214)

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255.0,
            green: CGFloat((v >> 8) & 0xff) / 255.0,
            blue: CGFloat(v & 0xff) / 255.0, alpha: a)
}

let plum = hex(0x1a1b26)            // app icon background / brand dark
let headerTop = hex(0x232232)
let headerBottom = hex(0x191a24)
let fieldTop = hex(0x8681a8)        // mid-tone field: labels read in both appearances
let fieldBottom = hex(0x736e96)
let accent = hex(0xab88e6)
let leaf = hex(0x9ece6a)
let ink = hex(0x1e1c2b)             // captions drawn on the field

/// Vertical gradient drawn as exact one-device-pixel rows. NSGradient dithers,
/// which looks the same but leaves the artwork incompressible — this repo would
/// carry ~800 KB of noise instead of ~100 KB of picture.
func verticalGradient(_ rect: NSRect, from top: NSColor, to bottom: NSColor, scale: CGFloat) {
    let t = top.usingColorSpace(.sRGB)!, b = bottom.usingColorSpace(.sRGB)!
    let step = 1 / scale
    var y = rect.minY
    while y < rect.maxY {
        let f = (y - rect.minY) / rect.height          // 0 at the bottom, 1 at the top
        NSColor(srgbRed: b.redComponent + (t.redComponent - b.redComponent) * f,
                green: b.greenComponent + (t.greenComponent - b.greenComponent) * f,
                blue: b.blueComponent + (t.blueComponent - b.blueComponent) * f,
                alpha: 1).setFill()
        NSRect(x: rect.minX, y: y, width: rect.width, height: step).fill()
        y += step
    }
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let pw = Int(W * scale), ph = Int(H * scale)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)   // so 1pt of drawing = `scale` pixels

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // AppKit draws from the bottom-left; the layout above is written top-down.
    func flip(_ y: CGFloat) -> CGFloat { H - y }

    // The field the icons stand on.
    verticalGradient(NSRect(x: 0, y: 0, width: W, height: flip(headerH)),
                     from: fieldTop, to: fieldBottom, scale: scale)

    // Faint graph paper, echoing the pixel-art icon. Lines, not filled cells — a
    // checkerboard at this scale reads as a transparency grid.
    let cell: CGFloat = 20
    NSColor(white: 1, alpha: 0.045).setFill()
    var x: CGFloat = cell
    while x < W {
        NSRect(x: x, y: 0, width: 1, height: flip(headerH)).fill()
        x += cell
    }
    var y = flip(headerH) - cell
    while y > 0 {
        NSRect(x: 0, y: y, width: W, height: 1).fill()
        y -= cell
    }

    // Header band.
    verticalGradient(NSRect(x: 0, y: flip(headerH), width: W, height: headerH),
                     from: headerTop, to: headerBottom, scale: scale)
    // A hairline of brand colour where the header meets the field.
    accent.withAlphaComponent(0.85).setFill()
    NSRect(x: 0, y: flip(headerH) - 1, width: W, height: 2).fill()

    // Wordmark: the app icon, then the name, centred as one block.
    let mark: CGFloat = 46
    let title = "Damson"
    let titleFont = NSFont(name: "HelveticaNeue-Bold", size: 34)!
    let titleSize = (title as NSString).size(withAttributes: [.font: titleFont])
    let blockW = mark + 16 + titleSize.width
    let blockX = (W - blockW) / 2
    if let icon = NSImage(contentsOf: iconURL) {
        let r = NSRect(x: blockX, y: flip(30 + mark), width: mark, height: mark)
        ctx.saveGState()
        NSBezierPath(roundedRect: r, xRadius: mark * 180 / 1024, yRadius: mark * 180 / 1024).addClip()
        icon.draw(in: r)
        ctx.restoreGState()
    }
    (title as NSString).draw(
        at: NSPoint(x: blockX + mark + 16, y: flip(32 + titleSize.height)),
        withAttributes: [.font: titleFont, .foregroundColor: NSColor.white])

    let tagline = "The terminal built only for macOS"
    let tagFont = NSFont(name: "HelveticaNeue-Medium", size: 13)!
    let tagW = (tagline as NSString).size(withAttributes: [.font: tagFont]).width
    (tagline as NSString).draw(
        at: NSPoint(x: (W - tagW) / 2, y: flip(headerH - 16)),
        withAttributes: [.font: tagFont, .foregroundColor: accent])

    // Pixel-art arrow between the slots, drawn in blocks like the icon.
    let unit: CGFloat = 11
    let ax = (appSlot.x + appsSlot.x) / 2, ay = appSlot.y
    // Shaft: 5 blocks wide, 1 tall. Head: a stepped triangle.
    func block(_ cx: CGFloat, _ cy: CGFloat, _ color: NSColor, _ alpha: CGFloat = 1) {
        color.withAlphaComponent(alpha).setFill()
        NSRect(x: ax + cx * unit, y: flip(ay + cy * unit) - unit, width: unit, height: unit).fill()
    }
    for i in -5...0 {                                        // shaft, 3 blocks thick
        for dy in -1...1 { block(CGFloat(i), CGFloat(dy), .white, 0.92) }
    }
    for (i, h) in [(1, 3), (2, 2), (3, 1), (4, 0)] {         // stepped head, narrowing right
        for dy in -h...h { block(CGFloat(i), CGFloat(dy), .white, 0.92) }
    }
    for dy in -1...1 { block(-6, CGFloat(dy), leaf, 0.95) }   // a green tail block

    let caption = "Drag to install"
    let capFont = NSFont(name: "HelveticaNeue-Medium", size: 12)!
    let capW = (caption as NSString).size(withAttributes: [.font: capFont]).width
    (caption as NSString).draw(
        at: NSPoint(x: ax - capW / 2 + unit / 2, y: flip(ay + 64)),
        withAttributes: [.font: capFont, .foregroundColor: ink.withAlphaComponent(0.78)])

    // Footer: the one thing worth saying that the icons do not already say.
    let footer = "Requires macOS 13 or later  ·  damson.app"
    let footerFont = NSFont(name: "HelveticaNeue-Medium", size: 11.5)!
    let footerW = (footer as NSString).size(withAttributes: [.font: footerFont]).width
    (footer as NSString).draw(
        at: NSPoint(x: (W - footerW) / 2, y: flip(H - 26)),
        withAttributes: [.font: footerFont, .foregroundColor: ink.withAlphaComponent(0.6)])

    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for (scale, name) in [(CGFloat(1), "background.png"), (CGFloat(2), "background@2x.png")] {
    let url = outDir.appendingPathComponent(name)
    try! render(scale: scale).representation(using: .png, properties: [:])!.write(to: url)
    print("==> \(url.path)")
}

// Finder picks the right scale out of a multi-resolution TIFF.
let tiff = Process()
tiff.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiff.arguments = ["-cathidpicheck",
                  outDir.appendingPathComponent("background.png").path,
                  outDir.appendingPathComponent("background@2x.png").path,
                  "-out", outDir.appendingPathComponent("background.tiff").path]
try! tiff.run()
tiff.waitUntilExit()
print("==> \(outDir.appendingPathComponent("background.tiff").path)")
