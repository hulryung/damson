import AppKit

/// Builds an NSFont from the main font + size, adding fallbacks to cascadeList in priority order:
///   1. User-selected font (primary)
///   2. Nerd Font — for Powerline glyphs (PUA U+E0A0+)
///      (skipped if primary is already a Nerd Font)
///   3. Apple SD Gothic Neo — for Hangul
///      (pinned explicitly rather than relying on the macOS system fallback chain, so the same
///       Hangul font renders in every environment.)
///
/// The macOS system fallback chain handles language glyphs (Hangul, Hanzi, etc.) automatically, but
/// does not fall back for Powerline / Nerd Font glyphs in the PUA range. Also, the Hangul font the
/// system picks can vary by macOS version, which can produce subtle line-height differences → pin it explicitly.
public func fontWithNerdFallback(family: String, size: CGFloat) -> NSFont {
    let primary = NSFont(name: family, size: size)
        ?? NSFont.userFixedPitchFont(ofSize: size)
        ?? NSFont.systemFont(ofSize: size)

    var cascade: [NSFontDescriptor] = []

    // (2) Nerd Font fallback — only when primary isn't already a Nerd Font.
    if !isNerdFont(family), let nerd = anyInstalledNerdFont() {
        cascade.append(NSFontDescriptor(name: nerd, size: size))
    }

    // (3) CJK (Hangul) fallback — draws only East Asian characters the base font lacks with this font.
    //     Unified through cjkFallbackFont so it uses the **same** font as the Metal GlyphRasterizer.
    if let cjk = cjkFallbackFont(size: size) {
        cascade.append(NSFontDescriptor(name: cjk.fontName, size: size))
    }

    guard !cascade.isEmpty else { return primary }
    let descriptor = primary.fontDescriptor.addingAttributes([
        NSFontDescriptor.AttributeName.cascadeList: cascade,
    ])
    return NSFont(descriptor: descriptor, size: size) ?? primary
}

/// Resolves the CJK (mainly Hangul) fallback font in one place — ensures the legacy cascade and the
/// Metal GlyphRasterizer use the **same** font.
///
/// D2Coding family preferred: Hangul renders at twice the ASCII width (East-Asian Wide), which fits
/// the terminal cell grid (Hangul = 2 cells) and is the Korean-developer standard.
///
/// ⚠️ Avoid the Nerd Font **"Mono"** variant — it forces every glyph to one cell width, squashing
/// even Hangul into half a cell (Hangul/A ratio 1.0). Non-Mono (`Nerd Font`) / `Propo` variants keep
/// Hangul at the proper double width (ratio 2.0), so prefer those. If none exist, NanumGothicCoding,
/// and finally Apple SD Gothic Neo (proportional).
public func cjkFallbackFont(size: CGFloat) -> NSFont? {
    let candidates = [
        "D2Coding",                          // original TTF (Hangul double width)
        "D2CodingLigature",
        "D2Coding Nerd Font",                // non-Mono: Hangul a proper 2 cells
        "D2CodingLigature Nerd Font",
        "D2Coding Nerd Font Propo",
        "D2CodingLigature Nerd Font Propo",
        "NanumGothicCoding",
        "Apple SD Gothic Neo",
        "AppleSDGothicNeo-Regular",
    ]
    for name in candidates {
        if let f = NSFont(name: name, size: size) { return f }
    }
    return nil
}

/// Treated as a Nerd Font if the font family name contains a keyword like "Nerd Font".
public func isNerdFont(_ family: String) -> Bool {
    let lower = family.lowercased()
    return lower.contains("nerd font")
        || family.contains(" NF")
        || family.contains(" NFM")
        || family.contains(" NFP")
}

/// Returns an arbitrary one of the monospace Nerd Fonts installed on the system, for fallback use.
/// Prefers the "Mono" variant (one-cell-width glyphs).
private var cachedNerdFallback: String??
public func anyInstalledNerdFont() -> String? {
    if let cached = cachedNerdFallback { return cached }
    let mgr = NSFontManager.shared
    let mono = mgr.availableFontFamilies.filter { name in
        guard isNerdFont(name) else { return false }
        guard let f = NSFont(name: name, size: 12) else { return false }
        return f.isFixedPitch
    }
    // Prefer the "Mono" variant.
    let monoFirst = mono.sorted { a, b in
        let aMono = a.lowercased().contains("nerd font mono") || a.contains(" NFM")
        let bMono = b.lowercased().contains("nerd font mono") || b.contains(" NFM")
        if aMono != bMono { return aMono }
        return a < b
    }
    let chosen = monoFirst.first
    cachedNerdFallback = .some(chosen)
    return chosen
}
