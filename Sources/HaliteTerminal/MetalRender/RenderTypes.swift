import simd

/// CPU↔GPU shared layouts. Field order/types must match `MetalShaders.source`.
/// We render in POINTS with a top-left origin; the vertex shader flips Y to NDC,
/// so the drawable's pixel size never enters the geometry math.

/// Per-frame uniforms. Just the viewport size (points) for the NDC transform.
struct Uniforms {
    var viewportSize: SIMD2<Float>
}

/// One filled rectangle: cell background, selection, find highlight, block
/// cursor (as an inverse-bg rect). Origin/size in points, top-left origin.
struct BgInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var color: SIMD4<Float>
}

/// One glyph quad: cell rect (points) + atlas UV (0–1) + foreground color. The
/// fragment shader samples the R8 coverage atlas and modulates `color.a`.
struct GlyphInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var uvOrigin: SIMD2<Float>
    var uvSize: SIMD2<Float>
    var color: SIMD4<Float>
}
