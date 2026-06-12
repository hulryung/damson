/// Metal shader source, compiled at runtime via `device.makeLibrary(source:)`.
///
/// Embedding the source (rather than a precompiled `default.metallib` resource)
/// sidesteps the unproven `Bundle.module` shader-load path for this library
/// target — Phase 1 prioritizes getting Metal on screen. A precompiled
/// `.metallib` resource is a later optimization (avoids the one-time runtime
/// compile at launch).
///
/// Struct field order/types must match `RenderTypes.swift`.
enum MetalShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float2 viewportSize; };
    struct BgInstance { float2 origin; float2 size; float4 color; };

    struct BgVOut {
        float4 position [[position]];
        float4 color;
    };

    // Instanced unit-quad fill. Coordinates are in POINTS, top-left origin;
    // we map to NDC here (flipping Y) so pixel/backing scale never matters.
    vertex BgVOut bg_vertex(uint vid [[vertex_id]],
                            uint iid [[instance_id]],
                            constant Uniforms& u [[buffer(0)]],
                            const device BgInstance* insts [[buffer(1)]]) {
        float2 corners[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
        float2 corner = corners[vid];
        BgInstance inst = insts[iid];
        float2 px = inst.origin + corner * inst.size;
        float2 ndc = float2(px.x / u.viewportSize.x * 2.0 - 1.0,
                            1.0 - px.y / u.viewportSize.y * 2.0);
        BgVOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.color = inst.color;
        return out;
    }

    // Premultiplied output (paired with a .one / .oneMinusSourceAlpha blend).
    // For opaque fills (a==1) this is identical to the old src-over path; for
    // translucent fills (window background-opacity < 1) it composites correctly
    // over the (also premultiplied) cleared background and the layer's backdrop.
    fragment float4 bg_fragment(BgVOut in [[stage_in]]) {
        return float4(in.color.rgb * in.color.a, in.color.a);
    }

    struct GlyphInstance {
        float2 origin; float2 size; float2 uvOrigin; float2 uvSize; float4 color; float4 fx;
    };
    struct GlyphVOut {
        float4 position [[position]];
        float2 uv;
        float4 color;
        float4 fx;
        // Glyph's atlas rect, for fx that displace the sample uv (glitch) — the
        // displaced coordinate must clamp inside this glyph's atlas cell so slices
        // never bleed pixels from a neighboring glyph. [[flat]]: no interpolation.
        float2 uvOrigin [[flat]];
        float2 uvSize [[flat]];
    };

    static inline float hash21(float2 p) {
        float q = sin(dot(p, float2(127.1, 311.7))) * 43758.5453;
        return fract(q);
    }

    vertex GlyphVOut glyph_vertex(uint vid [[vertex_id]],
                                  uint iid [[instance_id]],
                                  constant Uniforms& u [[buffer(0)]],
                                  const device GlyphInstance* insts [[buffer(1)]]) {
        float2 corners[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
        float2 corner = corners[vid];
        GlyphInstance inst = insts[iid];
        float2 px = inst.origin + corner * inst.size;
        float2 ndc = float2(px.x / u.viewportSize.x * 2.0 - 1.0,
                            1.0 - px.y / u.viewportSize.y * 2.0);
        GlyphVOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.uv = inst.uvOrigin + corner * inst.uvSize;
        out.color = inst.color;
        out.fx = inst.fx;
        out.uvOrigin = inst.uvOrigin;
        out.uvSize = inst.uvSize;
        return out;
    }

    // Glyph fx channels: fx.x = dissolve erosion, fx.y = glitch amount,
    // fx.z = burn (ember rim on the erosion edge; pairs with fx.x), fx.w reserved.
    fragment float4 glyph_fragment(GlyphVOut in [[stage_in]],
                                   texture2d<float> atlas [[texture(0)]],
                                   sampler samp [[sampler(0)]]) {
        float2 uv = in.uv;
        float glitch = in.fx.y;
        if (glitch > 0.0) {
            // Horizontal slice displacement: 3px bands shear sideways. Seeding the
            // hash with the (animating) amount re-rolls the slices every frame, so
            // the tear visibly crawls instead of freezing.
            float band = floor(in.position.y / 3.0);
            float n = hash21(float2(band, glitch * 41.0));
            uv.x += (n - 0.5) * glitch * in.uvSize.x * 0.9;
            uv = clamp(uv, in.uvOrigin, in.uvOrigin + in.uvSize);
        }
        float coverage = atlas.sample(samp, uv).r;
        float a = in.color.a * coverage;
        float3 rgb = in.color.rgb;
        // Dissolve: per-pixel noise vanishes as the dissolve amount rises.
        float diss = in.fx.x;
        if (diss > 0.0) {
            float n = hash21(floor(in.position.xy));
            a *= smoothstep(diss, diss + 0.18, n);
            // Burn: pixels just about to erode glow ember-orange, so the glyph
            // appears to char away from its edges.
            if (in.fx.z > 0.0) {
                float rim = 1.0 - smoothstep(diss + 0.05, diss + 0.30, n);
                rgb = mix(rgb, float3(1.0, 0.45, 0.08), rim * in.fx.z);
            }
        }
        if (glitch > 0.0) {
            // Per-slice dropout + RGB-split tint (some slices go magenta/cyan-ish).
            float band = floor(in.position.y / 3.0);
            float n2 = hash21(float2(band * 1.7, 13.0 + glitch * 23.0));
            a *= mix(1.0, step(0.15, n2), glitch);
            float3 split = (n2 < 0.5) ? float3(1.0, 0.6, 1.2) : float3(1.2, 1.0, 0.6);
            rgb *= mix(float3(1.0), split, glitch);
        }
        return float4(rgb, a);
    }

    // Color emoji: sample the premultiplied BGRA color page as-is, ignoring fg.
    // Paired with a premultiplied (.one / .oneMinusSourceAlpha) blend.
    fragment float4 glyph_color_fragment(GlyphVOut in [[stage_in]],
                                         texture2d<float> atlas [[texture(0)]],
                                         sampler samp [[sampler(0)]]) {
        return atlas.sample(samp, in.uv);
    }

    // ---- Post-processing (screen effects) ----------------------------------
    // A fullscreen pass that samples the rendered terminal (offscreen scene
    // texture) and applies a screen effect. Static effects have no time input,
    // so they only run on the frames the terminal already redraws (zero idle
    // cost). Animated effects (coeffs4.y > 0) read coeffs4.x as time; the
    // backend keeps a display-link redraw loop running while one is active.
    struct PostFXParams {
        float2 screenSize;   // drawable size in pixels
        float4 coeffs;       // x=scanline, y=glow, z=vignette, w=glowRadiusPx
        float4 tint;         // rgb phosphor tint (a unused)
        float4 coeffs2;      // x=curvature, y=monochrome amount, z=aberration px, w=grain
        float4 coeffs3;      // x=invert, y=pixelate block px, z=aperture grille, w reserved
        float4 coeffs4;      // x=time s, y=anim mode (1 rain, 2 snow, 3 underwater), z=intensity
        float4 bgColor;      // terminal bg (premultiplied) — bezel = dimmed bg
    };
    struct PostFXVOut {
        float4 position [[position]];
        float2 uv;
    };

    // Fullscreen triangle from 3 vertex ids — no vertex buffer.
    vertex PostFXVOut postfx_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        PostFXVOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(p.x, 1.0 - p.y);   // scene stores rows top-down
        return out;
    }

    static inline float2 hash22(float2 p) {
        float n = sin(dot(p, float2(41.3, 289.1))) * 21753.715;
        return fract(float2(n, n * 1.6180339));
    }

    // ---- Animated effects ---------------------------------------------------
    // All droplet/flake math runs in aspect-corrected uv ("auv": x *= aspect) so
    // shapes stay round regardless of window proportions. Each helper is a pure
    // function of (auv, time) — no state, the motion lives in the math.

    // One layer of raindrops sliding down a grid of tall cells. Each occupied
    // cell runs its own drop on its own clock: the drop accelerates down the
    // cell, swaying slightly, leaving a thin wet streak above it. Returns
    // float4(refraction offset in auv units, wet mask, specular highlight).
    static inline float4 rain_layer(float2 auv, float t, float2 cells, float seed) {
        float2 st = auv * cells + float2(seed * 13.7, seed * 7.31);
        float2 id = floor(st);
        float2 f = fract(st);
        float2 rnd = hash22(id);
        float n = rnd.x;
        if (n < 0.14) { return float4(0.0); }   // some cells stay dry
        // Per-cell clock: phase and speed both random, so drops never sync up.
        float ti = fract(t * (0.08 + 0.22 * rnd.y) + n * 7.0);
        // Accelerating fall (gravity-ish), with a fade at both ends of the loop
        // so drops condense in and slide out instead of popping.
        float fy = mix(0.08, 0.92, ti * ti);
        float fx = 0.5 + (n - 0.5) * 0.55 + sin(ti * 21.0 + n * 43.0) * 0.04;
        float fade = smoothstep(0.0, 0.10, ti) * (1.0 - smoothstep(0.85, 1.0, ti));
        // Distance from the drop center in auv units (cells are non-square).
        float2 toC = (f - float2(fx, fy)) / cells;
        float r = (0.009 + 0.010 * fract(n * 9.7));
        float d = length(toC);
        float drop = (1.0 - smoothstep(r * 0.7, r, d)) * fade;
        // Wet streak: a thin clear band above the drop, strongest right behind
        // it and fading toward where the drop started.
        float sx = abs(toC.x);
        float streakW = r * (0.55 + 0.35 * rnd.y);
        float streak = (1.0 - smoothstep(streakW * 0.35, streakW, sx))
                     * step(f.y, fy)
                     * clamp(1.0 - (fy - f.y) / max(fy - 0.05, 0.001), 0.0, 1.0)
                     * fade * 0.85;
        // Refraction: the drop is a tiny lens — sample across its center,
        // magnified, so the world appears inverted inside it. The streak only
        // smears horizontally, and much less.
        float2 off = -toC * drop * 3.0;
        off.x += -toC.x * streak * 0.6;
        // Specular: a small bright dot up-left of center, plus a faint rim ring
        // at the drop boundary — on a dark terminal the rim is what makes the
        // bead read as glass at all.
        float hi = (1.0 - smoothstep(r * 0.12, r * 0.35,
                                     length(toC - float2(-r * 0.30, -r * 0.35)))) * drop;
        float rim = (smoothstep(r * 0.50, r * 0.80, d)
                   - smoothstep(r * 0.80, r * 1.04, d)) * fade;
        return float4(off, max(drop, streak), hi + rim * 0.26);
    }

    // Drifting snow: three parallax layers of flakes, each layer a grid of
    // mostly-empty cells with one jittered, twinkling flake. Returns additive
    // brightness 0..1.
    static inline float snow_field(float2 auv, float t) {
        float acc = 0.0;
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            float g = 11.0 + fi * 9.0;                 // far layers are denser…
            float speed = 0.16 - fi * 0.045;           // …slower…
            float rr = 0.085 - fi * 0.022;             // …and smaller (cell units)
            float sway = sin(t * (0.6 + fi * 0.23) + auv.y * 2.7 + fi * 5.0) * 0.6;
            float2 st = float2(auv.x * g + sway, auv.y * g - t * speed * g);
            float2 id = floor(st);
            float2 f = fract(st);
            float2 rnd = hash22(id + fi * 31.7);
            if (rnd.x < 0.72) { continue; }            // sparse
            float2 c = 0.25 + 0.5 * hash22(id + 17.3 + fi);
            float d = length(f - c);
            float flake = 1.0 - smoothstep(rr * 0.45, rr, d);
            float twinkle = 0.7 + 0.3 * sin(t * 2.6 + rnd.y * 41.0);
            acc += flake * twinkle * (1.0 - fi * 0.28);
        }
        return min(acc, 1.0);
    }

    // Rising bubbles for the underwater mode: same grid trick as snow, drifting
    // upward, drawn as a thin ring with a highlight dot (a bubble is mostly
    // transparent — only its rim catches light). Returns additive brightness.
    static inline float bubble_field(float2 auv, float t) {
        float acc = 0.0;
        for (int i = 0; i < 2; i++) {
            float fi = float(i);
            float g = 7.0 + fi * 6.0;
            float speed = 0.10 + fi * 0.05;
            float sway = sin(t * (0.8 + fi * 0.3) + auv.y * 4.0 + fi * 2.0) * 0.25;
            float2 st = float2(auv.x * g + sway, auv.y * g + t * speed * g);
            float2 id = floor(st);
            float2 f = fract(st);
            float2 rnd = hash22(id + fi * 53.1);
            if (rnd.x < 0.78) { continue; }            // bubbles are rare
            float2 c = 0.3 + 0.4 * hash22(id + 7.7 + fi);
            float r = 0.05 + 0.07 * rnd.y;
            float d = length(f - c);
            float ring = smoothstep(r, r * 0.82, d) - smoothstep(r * 0.66, r * 0.40, d);
            float hi = 1.0 - smoothstep(0.0, r * 0.30,
                                        length(f - c - float2(-r * 0.35, -r * 0.35)));
            acc += ring * 0.5 + hi * 0.55;
        }
        return min(acc, 1.0);
    }

    // Tube curve, edges bowing INWARD: the sample coordinate is pushed outward
    // more the further it is from the center, so the scene's edges land inside
    // the display and its boundary bows toward the middle (most at the corners
    // → rounded tube bezel). Every scene pixel maps to SOME display position,
    // so no terminal content is ever pushed off-screen — display pixels whose
    // sample falls outside [0,1] are the bezel and get masked to black.
    // (The previous center-magnify bulge spread the middle rows outward, which
    // visually shoved content off the left/right edges.) amount 0 = identity.
    static inline float2 crt_curve(float2 uv, float amount) {
        float2 c = uv * 2.0 - 1.0;          // -1..1, center origin
        float r2 = dot(c, c);               // 0 at center, 2 at the corners
        c *= 1.0 + amount * r2;             // sample beyond the scene near edges
        return c * 0.5 + 0.5;               // back to 0..1
    }

    fragment float4 postfx_fragment(PostFXVOut in [[stage_in]],
                                    texture2d<float> scene [[texture(0)]],
                                    sampler samp [[sampler(0)]],
                                    constant PostFXParams& p [[buffer(0)]]) {
        float scan = p.coeffs.x;
        float glowS = p.coeffs.y;
        float vig = p.coeffs.z;
        float glowR = p.coeffs.w;
        float curve = p.coeffs2.x;
        float aber = p.coeffs2.z;
        float grain = p.coeffs2.w;
        float invertAmt = p.coeffs3.x;
        float pixPx = p.coeffs3.y;
        float grille = p.coeffs3.z;

        // Curve the sampling coordinate; everything below samples/measures in
        // tube space so scanlines and vignette follow the curved image. Display
        // pixels whose curved sample falls outside the scene are the tube bezel:
        // `bezel` fades to 0 there (with a ~0.4% soft edge for AA) and the final
        // color is masked to opaque black.
        float2 uv = (curve > 0.0) ? crt_curve(in.uv, curve) : in.uv;
        float bezel = 1.0;
        if (curve > 0.0) {
            float2 inside = smoothstep(float2(-0.004), float2(0.004), uv)
                          * (1.0 - smoothstep(float2(0.996), float2(1.004), uv));
            bezel = inside.x * inside.y;
        }

        // Pixelate: quantize the sample coordinate to square blocks (device px).
        if (pixPx > 0.0) {
            float2 block = float2(pixPx) / p.screenSize;
            uv = (floor(uv / block) + 0.5) * block;
        }

        // Animated effects — pre-sample stage: distort the sampling coordinate
        // (raindrop lenses, underwater wobble) and collect masks for the
        // post-sample stages below.
        float animMode = p.coeffs4.y;
        float animT = p.coeffs4.x;
        float animK = p.coeffs4.z;
        float aspect = p.screenSize.x / p.screenSize.y;
        float rainWet = 0.0, rainSpec = 0.0, fogMix = 0.0;
        if (animMode > 0.5 && animMode < 1.5) {
            // Rain on glass: two drop layers at different scales/clocks so the
            // pattern never reads as a grid.
            float2 auv = float2(uv.x * aspect, uv.y);
            float4 d1 = rain_layer(auv, animT, float2(20.0, 3.0), 0.0);
            float4 d2 = rain_layer(auv, animT * 0.85 + 11.0, float2(13.0, 2.0), 3.7);
            float2 off = d1.xy + d2.xy;
            rainWet = max(d1.z, d2.z);
            rainSpec = max(d1.w, d2.w);
            uv += float2(off.x / aspect, off.y) * animK;
            // Condensation: everything fogs except where water has wiped the
            // glass clear (drops and their streaks stay sharp).
            fogMix = animK * 0.65 * (1.0 - rainWet);
        } else if (animMode > 2.5) {
            // Underwater: layered sine wobble — slow large swell + faster ripple.
            uv.x += (sin(uv.y * 21.0 + animT * 1.6) * 0.0035
                   + sin(uv.y * 6.7 - animT * 1.1) * 0.0020) * animK;
            uv.y += sin(uv.x * 17.0 + animT * 1.2) * 0.0022 * animK;
        }

        float4 src;
        float3 color;
        if (aber > 0.0) {
            // Chromatic aberration: R and B sampled with opposite horizontal
            // offsets (in device px) — the misconverged-gun / VHS color fringe.
            float2 off = float2(aber / p.screenSize.x, 0.0);
            src = scene.sample(samp, uv);
            color = float3(scene.sample(samp, uv + off).r,
                           src.g,
                           scene.sample(samp, uv - off).b);
        } else {
            src = scene.sample(samp, uv);
            color = src.rgb;
        }

        // Rain condensation: a soft 5-tap blur plus a faint lift, mixed in
        // everywhere the glass hasn't been wiped clear by a drop.
        if (fogMix > 0.0) {
            float2 texel = 4.0 / p.screenSize;
            float3 blur = color * 0.2;
            blur += scene.sample(samp, uv + float2( texel.x,  texel.y)).rgb * 0.2;
            blur += scene.sample(samp, uv + float2(-texel.x,  texel.y)).rgb * 0.2;
            blur += scene.sample(samp, uv + float2( texel.x, -texel.y)).rgb * 0.2;
            blur += scene.sample(samp, uv + float2(-texel.x, -texel.y)).rgb * 0.2;
            color = mix(color, blur + 0.022, fogMix);
        }

        // Phosphor glow: cheap 3x3 box blur, lighten-mixed back in.
        if (glowS > 0.0 && glowR > 0.0) {
            float2 texel = float2(glowR) / p.screenSize;
            float3 sum = float3(0.0);
            for (int dx = -1; dx <= 1; dx++) {
                for (int dy = -1; dy <= 1; dy++) {
                    sum += scene.sample(samp, uv + float2(float(dx), float(dy)) * texel).rgb;
                }
            }
            float3 glow = sum * (1.0 / 9.0);
            color = mix(color, max(color, glow), glowS);
        }
        // Scanlines: dim alternating device-pixel rows.
        if (scan > 0.0) {
            int row = int(uv.y * p.screenSize.y);
            float dim = mix(1.0, 1.0 - scan, float(row & 1));
            color *= dim;
        }
        // Aperture grille: vertical RGB triad stripes (each device-pixel column
        // favors one channel), brightness-compensated so the mask doesn't darken.
        if (grille > 0.0) {
            int col = int(uv.x * p.screenSize.x);
            int ch = col - (col / 3) * 3;
            float3 mask = float3(ch == 0 ? 1.0 : 0.0,
                                 ch == 1 ? 1.0 : 0.0,
                                 ch == 2 ? 1.0 : 0.0);
            color *= mix(float3(1.0), mask * 2.6, grille);
        }
        // Color transform: monochrome (phosphor / grayscale) maps luminance onto
        // the tint color; otherwise the tint is a subtle multiply (CRT warmth).
        float mono = p.coeffs2.y;
        if (mono > 0.0) {
            float lum = dot(color, float3(0.299, 0.587, 0.114));
            color = mix(color, lum * p.tint.rgb, mono);
        } else {
            color *= p.tint.rgb;
        }
        // Invert (negative). Applied after tint/mono so phosphor inverts too.
        if (invertAmt > 0.0) {
            color = mix(color, 1.0 - color, invertAmt);
        }
        // Film grain: static per-pixel noise (position-keyed, NOT time-keyed —
        // keeps the zero-idle-cost contract; it shimmers only as content redraws).
        if (grain > 0.0) {
            float n = hash21(floor(in.uv * p.screenSize)) - 0.5;
            color += n * grain;
        }
        // Animated effects — post-sample overlays. These read the UNdistorted
        // screen coordinate (in.uv) so flakes/bubbles float over the content
        // rather than being bent by it.
        if (animMode > 1.5 && animMode < 2.5) {
            float2 auv = float2(in.uv.x * aspect, in.uv.y);
            color += snow_field(auv, animT) * 0.85 * animK * float3(0.92, 0.96, 1.05);
        } else if (animMode > 2.5) {
            float2 auv = float2(in.uv.x * aspect, in.uv.y);
            // Caustic shimmer: two crossing moving interference patterns,
            // sharpened so only the crests read as light.
            float c1 = sin(auv.x * 23.0 + animT * 2.1) * sin(auv.y * 17.0 - animT * 1.55);
            float c2 = sin(auv.x * 31.0 - animT * 1.3) * sin(auv.y * 23.0 + animT * 1.9);
            float caust = pow(max(c1 * c2, 0.0), 2.0);
            // Brighten lit content AND add a faint glow — the additive part is
            // what keeps caustics visible over the (near-black) terminal bg.
            color *= 1.0 + caust * 0.10 * animK;
            color += caust * float3(0.020, 0.045, 0.055) * animK;
            color += bubble_field(auv, animT) * 0.40 * animK;
        }
        if (rainSpec > 0.0) {
            color += rainSpec * 0.5 * animK;
        }
        // Vignette: darken toward the corners.
        if (vig > 0.0) {
            float d = distance(uv, float2(0.5));
            color *= 1.0 - smoothstep(0.35, 0.85, d) * vig;
        }
        // Tube bezel: outside the curved image, show the terminal background
        // slightly dimmed (the clamp sampler would otherwise smear the edge
        // pixels outward). Premultiplied like everything else in this pipeline.
        float3 bezelColor = p.bgColor.rgb * 0.78;
        color = mix(bezelColor, color, bezel);
        float alpha = mix(p.bgColor.a, src.a, bezel);
        return float4(max(color, float3(0.0)), alpha);
    }
    """
}
