import SceneKit

/// Village buildings: the walls over cj_facade.jpg and the roofs on the
/// cj_roof.jpg atlas, each building tinted and weathered on its own with
/// cj_grime (scripts/courses/textures/bake_buildings.py).
extension WorldShaders {
    /// Walls: texcoord 0 = `BuildingBuilder.Paint`, texcoord 1 = (height
    /// above the ground under the vertex, metres below the wall top),
    /// texcoord 2 = (kind * 8 + tint, seed); see `BuildingBuilder.WallKind`
    /// and `wallCode`.
    static let wallGeometry = """
    #pragma varyings
    float4 wdat;
    float2 wuv;
    #pragma body
    out.wdat = float4(_geometry.texcoords[1], _geometry.texcoords[2]);
    out.wuv = _geometry.texcoords[0];
    """

    /// The facade colour: a window or door cell of cj_facade.jpg as laid
    /// out, or the blank wall of the building's row, wrapped every 3 m along
    /// and up and kept half a texel of the sampled level clear of the cell's
    /// edges; tinted per building (warm or cool white, cream, redder or
    /// browner brick); plinths tarred, painted, bluestone or cement over the
    /// wall's own relief; a barn's timber or steel door painted in boards or
    /// ribs; a dry-stone retaining wall laid in slabs or rubble; dressed
    /// limestone and a sandstone plinth (the Oudenberg chapel); rain
    /// streaks under the eaves, a damp, splashed foot with green
    /// on the shady side, and ambient occlusion where the wall meets the
    /// ground and under the eaves. The atlas's glass is dark and bluish: it
    /// turns smooth, so it mirrors the sky. The light raster
    /// (`WorldShaders+Light`) dims the sky light on walls in the lanes and
    /// low on every wall, and gives them the sun's shade past the shadow
    /// map (a hedge's or shed's on the lower metres only); chimneys stay
    /// open and sunlit.
    ///
    /// On the Riviera (`riviera` 1: WorldLook.riviera, the atlas
    /// cj_facade_lig.jpg) the code carries a render colour and a shutter
    /// colour over 128 (`BuildingBuilder.rivieraTint`): `facadeMask` (R
    /// render, G shutters and painted doors) says where the atlas's neutral
    /// render takes the building's Ligurian pastel, a little lighter or
    /// darker per building, and its grey-green persiane the building's dark
    /// green, brown or light blue. Dry-stone walls are honey sandstone
    /// there, a garage's steel door a roll-down shutter, and the wall foot
    /// is stained by rising damp rather than green with algae.
    static let wallSurface = """
    #pragma arguments
    texture2d<float> grimeTex;
    texture2d<float> facadeTex;
    texture2d<float> facadeMask;
    float riviera;
    \(lightArgs)
    #pragma body
    constexpr sampler rep(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(4));
    constexpr sampler cellS(filter::linear, mip_filter::linear, address::clamp_to_edge, max_anisotropy(8));
    float hG = in.wdat.x;
    float below = in.wdat.y;
    float code = floor(in.wdat.z + 0.5);
    // Riviera colours over 128 (none on a Flemish wall: its code is under 128).
    float hiCode = floor(code * (1.0 / 128.0));
    code -= hiCode * 128.0;
    bool lig = riviera > 0.5;
    float kind = floor(code * 0.125 + 0.01);
    float tint = code - kind * 8.0;
    float seed = in.wdat.w;
    float2 tc = in.wuv;
    float2 tdx = dfdx(tc), tdy = dfdy(tc);
    float3 wp = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
    float3 nW = normalize((scn_frame.inverseViewTransform * float4(_surface.normal, 0.0)).xyz);
    // Weathering in wall metres: along the wall, and down it.
    float2 gp = float2(abs(nW.x) > abs(nW.z) ? wp.z : wp.x, -wp.y);
    float4 gA = grimeTex.sample(rep, gp * 0.19 + float2(seed * 3.7, seed * 1.9));
    float4 gS = grimeTex.sample(rep, float2(gp.x * 0.83 + seed * 5.1, gp.y * 0.09));
    // Blank wall: texcoord 0 = (2 + cells along, 32 + 64 * row + cells up).
    bool blank = tc.x > 1.5;
    float cellPx = float(facadeTex.get_width()) * 0.25;
    float2 bgx = float2(tdx.x, -tdx.y) * 0.25, bgy = float2(tdy.x, -tdy.y) * 0.25;
    float lod = max(0.5 * log2(max(max(dot(bgx, bgx), dot(bgy, bgy)) * 16.0 * cellPx * cellPx, 1e-8)), 0.0);
    float inset = min(0.5 * exp2(lod) / cellPx, 0.2);
    float2 bc = clamp(float2(fract(tc.x), 1.0 - fract(tc.y)), inset, 1.0 - inset);
    float2 ba = (float2(3.0, floor(tc.y * (1.0 / 64.0))) + bc) * 0.25;
    float3 alb = facadeTex.sample(cellS, blank ? ba : tc, gradient2d(blank ? bgx : tdx, blank ? bgy : tdy)).rgb;
    float lum = dot(alb, float3(0.2126, 0.7152, 0.0722));
    float glass = smoothstep(0.008, 0.03, alb.b - alb.r) * (1.0 - smoothstep(0.1, 0.18, lum));
    const float3 tints[8] = {
        float3(1.0, 1.0, 1.0), float3(1.03, 0.99, 0.91), float3(0.95, 0.98, 1.03), float3(1.04, 0.97, 0.85),
        float3(0.84, 0.83, 0.81), float3(1.1, 0.93, 0.86), float3(0.88, 0.8, 0.74), float3(1.05, 1.0, 0.82) };
    alb *= mix(tints[int(clamp(tint, 0.0, 7.0))], float3(1.0), glass);
    float renderShare = 0.0;
    if (lig) {
        // Ligurian pastels (look.md section 3, paint values, linear): cream,
        // pale yellow, ochre, pale pink, salmon, white, pale green, weathered
        // grey-beige, pink-beige, the Santuario's cream-ochre, warm yellow,
        // faded rose, light grey, peach, blue-grey; over the atlas's #ebe5d9.
        const float3 paints[16] = {
            float3(0.8308, 0.7835, 0.6939), float3(0.807, 0.716, 0.552), float3(0.791, 0.644, 0.323),
            float3(0.658, 0.392, 0.130), float3(0.761, 0.565, 0.521), float3(0.716, 0.392, 0.275),
            float3(0.871, 0.839, 0.776), float3(0.474, 0.591, 0.352), float3(0.527, 0.479, 0.392),
            float3(0.807, 0.672, 0.604), float3(0.687, 0.578, 0.352), float3(0.768, 0.539, 0.195),
            float3(0.624, 0.323, 0.223), float3(0.672, 0.644, 0.591), float3(0.831, 0.546, 0.352),
            float3(0.552, 0.604, 0.591) };
        // Persiane: dark green #1f3d35, brown #6b4a33, light blue #8fb3d6,
        // faded green #4f6b5e.
        const float3 shutters[4] = {
            float3(0.0137, 0.0467, 0.0356), float3(0.1470, 0.0685, 0.0331), float3(0.2747, 0.4508, 0.6724),
            float3(0.0782, 0.1470, 0.1119) };
        float4 msk = facadeMask.sample(cellS, blank ? ba : tc, gradient2d(blank ? bgx : tdx, blank ? bgy : tdy));
        float pal = hiCode - 16.0 * floor(hiCode * (1.0 / 16.0));
        float3 paint = paints[int(clamp(pal, 0.0, 15.0))] * (1.0 / float3(0.8308, 0.7835, 0.6939));
        // Repainted at different times: a little lighter or darker, warmer or cooler.
        float jit = fract(seed * 5.37);
        paint *= (0.93 + 0.12 * jit) * float3(1.0 + 0.03 * (fract(seed * 2.9) - 0.5), 1.0, 1.0 - 0.03 * (fract(seed * 2.9) - 0.5));
        // Under the white point in sun: the paint cards decoded straight
        // reach 0.8-0.87, which a wall square to the sun (2.1 times the
        // ambient-lit level) clipped to lemon or white (#fdf8a7, #ffffea at
        // 1100 and 2700). The brightest channel is held to 0.66. The cards
        // are photographs' colours, so decoded to linear their chroma is
        // already a camera's in full sun; a tenth of it is taken back
        // (a lift of a tenth turned sunlit ochre and peach to tangerine,
        // #fcb957 at 1450, against the card's #d4a865), and `wallFragment`
        // pales what still runs bright, as a camera's shoulder does.
        float3 rc = step(0.5, pal) > 0.5 ? alb * paint : alb;
        float rl = dot(rc, float3(0.2126, 0.7152, 0.0722));
        rc = max(rl + (rc - rl) * 0.9, float3(0.0));
        rc *= min(1.0, 0.66 / max(max(rc.r, rc.g), max(rc.b, 1e-4)));
        alb = mix(alb, rc, msk.r);
        renderShare = msk.r;
        float3 sh = shutters[int(clamp(floor(hiCode * (1.0 / 16.0)), 0.0, 3.0))];
        alb = mix(alb, sh * (lum * (1.0 / 0.1645)) * (0.9 + 0.2 * fract(seed * 8.3)), msk.g);
        glass *= 1.0 - msk.g;
    }
    float rough = mix(0.85, 0.1, glass);
    if (kind > 0.5 && kind < 4.5) {
        const float4 plinths[4] = {
            float4(0.020, 0.019, 0.018, 0.45), float4(0.034, 0.036, 0.040, 0.6),
            float4(0.050, 0.055, 0.060, 0.7), float4(0.150, 0.145, 0.135, 0.9) };
        float4 pl = plinths[int(clamp(kind - 1.0, 0.0, 3.0))];
        alb = pl.rgb * (0.75 + 0.5 * smoothstep(0.03, 0.6, lum));
        rough = pl.a;
    }
    if (kind > 7.5 && kind < 8.5) {
        // A dry-stone retaining wall: flat schist and sandstone slabs in
        // rough courses 7-15 cm high, each 20-60 cm long, grey to brown,
        // with dark open joints and no mortar; or (tint 1) rubble, rounded
        // brown-grey ironstone blocks 18-30 cm high and 25-55 cm long.
        // The joints fade to their mean under a few pixels.
        // On the Riviera: honey sandstone, squared rubble in loose courses
        // (look.md: blocks 20-60 cm long, 15-30 cm high).
        bool rubble = tint > 0.5 || lig;
        float2 sp = gp;
        // Metres per pixel: the blank wall's texcoord runs a cell (3 m) per unit.
        float pxs = 3.0 * max(length(tdx), length(tdy));
        float bandH = rubble ? 0.24 : 0.11;
        float band = floor(sp.y / bandH);
        float hb = fract(sin(band * 91.7 + seed * 13.1) * 43758.5453);
        float rowH = rubble ? 0.18 + 0.12 * hb : 0.07 + 0.08 * hb;
        float fy = fract(sp.y / bandH) * bandH / rowH;
        float row = band * 3.0 + floor(fy);
        float hr = fract(sin(row * 37.13 + seed * 5.7) * 43758.5453);
        float len = rubble ? 0.25 + 0.3 * hr : 0.2 + 0.4 * hr;
        float xs = sp.x / len + hr * 7.0;
        float hs = fract(sin(floor(xs) * 12.9898 + row * 78.233 + seed * 3.1) * 43758.5453);
        float jx = min(fract(xs), 1.0 - fract(xs)) * len;
        float jy = min(fract(fy), 1.0 - fract(fy)) * rowH;
        // Rubble's rounded edges: a wide, soft joint.
        float jw = rubble ? 0.035 : 0.016;
        float joint = (1.0 - smoothstep(0.005, jw, min(jx, jy))) * (1.0 - smoothstep(0.01, 0.04, pxs));
        float3 slab = rubble ? mix(float3(0.13, 0.11, 0.09), float3(0.26, 0.21, 0.155), hs)
                             : mix(float3(0.060, 0.058, 0.054), float3(0.105, 0.092, 0.074), hs);
        slab *= 0.85 + 0.3 * fract(hs * 17.0);
        if (lig) {
            // Pale honey #bba984, ochre #a8936c, grey-brown #8a7d68, the odd
            // rust-orange #a07a55; recessed joints #4f4535.
            float hk = fract(hs * 7.31);
            slab = hk < 0.35 ? float3(0.497, 0.397, 0.231) : (hk < 0.65 ? float3(0.392, 0.292, 0.150)
                 : (hk < 0.92 ? float3(0.254, 0.205, 0.138) : float3(0.352, 0.195, 0.091)));
            slab *= 0.82 + 0.3 * fract(hs * 17.0);
            alb = mix(slab, float3(0.078, 0.060, 0.036), joint * 0.8 + 0.1 * smoothstep(0.01, 0.04, pxs));
        } else {
            alb = mix(slab, float3(0.012, 0.011, 0.010), joint * 0.85 + 0.15 * smoothstep(0.01, 0.04, pxs));
        }
        // The top: earth and moss over the last course (dry earth and
        // grass on the Riviera).
        float cap = smoothstep(0.6, 0.85, nW.y);
        alb = mix(alb, lig ? mix(float3(0.16, 0.13, 0.08), float3(0.12, 0.14, 0.06), gA.b)
                           : mix(float3(0.032, 0.027, 0.019), float3(0.04, 0.055, 0.02), gA.b), cap);
        rough = 0.92;
    }
    if (kind > 8.5) {
        // Dressed stone: cream limestone in courses 30 cm high, blocks
        // 45-90 cm long on fine joints (the chapel's pilasters, quoins and
        // cornices); or its sandstone plinth, grey-brown and rougher, in
        // 26 cm courses. The joints fade to their mean under a few pixels.
        bool sand = kind > 9.5;
        float2 sp = gp;
        float pxs = 3.0 * max(length(tdx), length(tdy));
        float courseH = sand ? 0.26 : 0.3;
        float fy = sp.y / courseH;
        float row = floor(fy);
        float hr = fract(sin(row * 37.13 + seed * 5.7) * 43758.5453);
        float len = (sand ? 0.35 : 0.45) + 0.45 * hr;
        float xs = sp.x / len + hr * 7.0;
        float hs = fract(sin(floor(xs) * 12.9898 + row * 78.233 + seed * 3.1) * 43758.5453);
        float jx = min(fract(xs), 1.0 - fract(xs)) * len;
        float jy = min(fract(fy), 1.0 - fract(fy)) * courseH;
        float jw = sand ? 0.012 : 0.006;
        float joint = (1.0 - smoothstep(0.5 * jw, 1.6 * jw, min(jx, jy))) * (1.0 - smoothstep(0.008, 0.03, pxs));
        float3 stone = sand ? mix(float3(0.22, 0.21, 0.18), float3(0.31, 0.29, 0.25), hs)
                            : mix(float3(0.50, 0.49, 0.45), float3(0.58, 0.56, 0.51), hs);
        alb = mix(stone, stone * 0.6, joint);
        rough = sand ? 0.9 : 0.8;
    }
    if (kind > 5.5 && kind < 7.5) {
        // A barn's door: texcoord 0 = 2 + 8 * its size in decimetres +
        // metres from its lower left. Boards 16 cm wide, each its own tone,
        // or 20 cm box ribs on steel, fading to their mean under a few
        // pixels; a dark reveal round it and between its two leaves; strap
        // hinges on timber.
        bool steel = kind > 6.5;
        float2 q = floor(tc * 0.125);
        float2 dl = tc - q * 8.0 - 2.0;
        float2 sz = q * 0.1;
        float px = max(max(abs(tdx.x), abs(tdy.x)), max(abs(tdx.y), abs(tdy.y)));
        const float3 timber[5] = {
            float3(0.022, 0.021, 0.02), float3(0.02, 0.045, 0.03), float3(0.075, 0.026, 0.018),
            float3(0.11, 0.1, 0.088), float3(0.06, 0.038, 0.025) };
        const float3 sheet[4] = {
            float3(0.25, 0.26, 0.27), float3(0.09, 0.12, 0.1), float3(0.035, 0.038, 0.042), float3(0.06, 0.08, 0.11) };
        float pick = fract(seed * 11.71);
        float pw = steel ? 0.2 : 0.16;
        float x = dl.x / pw;
        float f = fract(x);
        float fade = 1.0 - smoothstep(0.08, 0.3, px / pw);
        float3 c;
        if (steel && lig) {
            // A garage's roll-down shutter: horizontal slats 6 cm high, grey
            // #8a8a86, brown #6b4a33 or pale beige, a darker bottom rail.
            const float3 roller[3] = { float3(0.254, 0.254, 0.238), float3(0.147, 0.068, 0.033), float3(0.40, 0.37, 0.31) };
            float fs = fract(dl.y / 0.06);
            float sfade = 1.0 - smoothstep(0.15, 0.4, px / 0.06);
            c = roller[int(pick * 2.99)] * (1.0 + (smoothstep(0.05, 0.25, fs) * (1.0 - smoothstep(0.75, 0.95, fs)) - 0.6) * 0.3 * sfade);
            c *= 1.0 - 0.35 * step(dl.y, 0.08);
        } else if (steel) {
            c = sheet[int(pick * 3.99)] * (1.0 + (smoothstep(0.1, 0.2, f) * (1.0 - smoothstep(0.45, 0.55, f)) - 0.4) * 0.35 * fade);
        } else {
            float n = fract(sin(floor(x) * 12.9898 + seed * 78.233) * 43758.5453);
            float joint = 1.0 - smoothstep(0.04, 0.12, min(f, 1.0 - f));
            c = timber[int(pick * 4.99)] * (1.0 + (n - 0.5) * 0.22 * fade) * (1.0 - 0.6 * joint * fade);
        }
        float edge = min(min(dl.x, sz.x - dl.x), sz.y - dl.y);
        float meet = sz.x > 1.8 && !(steel && lig) ? abs(dl.x - 0.5 * sz.x) + 0.03 : 1.0;
        c *= mix(0.3, 1.0, smoothstep(0.02, 0.07 + px, min(edge, meet)));
        float hinge = step(min(dl.x, sz.x - dl.x), 0.7) * (step(abs(dl.y - 0.45), 0.03) + step(abs(dl.y - sz.y + 0.45), 0.03));
        c = mix(c, float3(0.02), hinge * (steel ? 0.0 : 1.0) * (1.0 - smoothstep(0.02, 0.05, px)));
        alb = c;
        rough = steel ? 0.5 : 0.82;
    }
    // How weathered this building is.
    float dirt = 0.35 + 0.65 * fract(seed * 7.13);
    alb *= 1.0 + (gA.a - 0.5) * 0.18 * dirt;
    float streak = smoothstep(0.45, 0.85, gS.r) * (1.0 - smoothstep(0.2, 2.0, below)) * dirt;
    alb *= 1.0 - 0.28 * streak;
    float foot = 1.0 - smoothstep(0.0, 0.35 + 0.35 * gA.g, hG);
    float north = saturate(-nW.z * 0.8 + 0.2);
    float green = (1.0 - smoothstep(0.0, 1.1, hG)) * north * smoothstep(0.45, 0.8, gA.b) * dirt;
    if (lig) {
        // Dry air: little green. Rising damp instead: a blotchy grey-brown
        // tide mark up to a metre or so on painted render.
        green *= 0.25;
        float damp = (1.0 - smoothstep(0.25, 0.7 + 0.6 * gA.g, hG)) * smoothstep(0.35, 0.6, gA.r * 0.5 + gA.a * 0.5) * dirt;
        alb = mix(alb, alb * float3(0.78, 0.76, 0.72), damp * 0.6);
    }
    alb = mix(alb, alb * float3(0.6, 0.56, 0.48), foot * 0.55);
    alb = mix(alb, float3(0.045, 0.06, 0.03), green * 0.45);
    // The raster 2 m out from the wall: the ground there sees about as
    // much sky as the wall does 1.5 m up (and its own building takes about
    // the share the wall can't see behind it). More sky higher up, less at
    // the foot: the unseen share halves every 5 m.
    float3 lgtP = wp + float3(nW.x, 0.0, nW.z) * 2.0;
    float3 lgtN = nW;
    float lgtD = -_surface.position.z;
    \(lightFetch)
    // A chimney stands above the roofs, and 2 m out from it is still its
    // own house, where the raster has no sun: open sky and full sun.
    if (kind > 4.5 && kind < 5.5) lgtQ = float4(1.0, 1.0, 0.0, 0.0);
    lgtQ.r = 1.0 - (1.0 - lgtQ.r) * exp2(0.3 - 0.2 * hG);
    // The sun's shade there is the wall's at its foot. Hedges, garden
    // walls and sheds shade only the lower metres, so it gives way from
    // 1.5 to 5 m up, unless the canopy there stands higher than this
    // point. Fitted to the sun-facing walls ray-marched at 0.3-8 m as the
    // bake does: on the Koppenberg, wall drawn shaded in sun 14 -> 3 %, lit
    // in shade 0.6 -> 5 % (the Oude Kwaremont alike).
    lgtQ.g = mix(lgtQ.g, 1.0, smoothstep(1.5, 5.0, hG) * smoothstep(0.0, 2.0, hG - lgtQ.b * 40.0));
    \(lightApply)
    if (lig && kind < 0.5) {
        // The sunlit street and the house opposite light a Ligurian wall
        // in shade warm: a little of its own colour, standing for the
        // ground's bounce the sky light leaves out. At 6 % shaded yellow
        // and ochre still read olive under the blue skylight (#604f30 at
        // 3900, #695a35 at 640) and pink mauve-grey (#6c6061); the 2026
        // phone photo's shaded fronts keep their pink and ochre.
        _surface.emission = float4(alb * renderShare * float3(0.105, 0.094, 0.078) * (1.0 - nW.y * nW.y), 1.0);
    }
    _surface.diffuse = float4(alb, 1.0);
    _surface.roughness = mix(rough, 0.95, foot * 0.6);
    _surface.ambientOcclusion *= mix(0.5, 1.0, smoothstep(-0.05, 0.9, hG)) * mix(0.55, 1.0, smoothstep(0.0, 0.7, below));
    """

    /// The Riviera's walls only (`WorldMaterials.makeWalls`): a camera's
    /// shoulder. From 0.62 up the colour pales towards its own luminance
    /// (a sunlit ochre or yellow render photographs soft, #d4a865 and
    /// #e6d29a, not amber), then what still passes the white point rolls
    /// off from 0.8 towards it, every channel by the same factor, so it
    /// keeps its texture instead of clipping to lemon or white. Values
    /// under 0.62 (shade, stone, the dark kinds) are untouched.
    static let wallFragment = """
    #pragma body
    float3 wc = _output.color.rgb;
    float wm = max(max(wc.r, wc.g), wc.b);
    if (wm > 0.62) {
        float wl = dot(wc, float3(0.2126, 0.7152, 0.0722));
        wc = mix(wc, float3(wl), 0.55 * smoothstep(0.62, 1.25, wm));
        wm = max(max(wc.r, wc.g), wc.b);
        if (wm > 0.8) {
            float wk = 0.8 + 0.2 * (1.0 - exp(-(wm - 0.8) * 5.0));
            wc *= wk / wm;
        }
        _output.color.rgb = wc;
    }
    """

    /// The Riviera's wires: each tube's vertices pushed out along their
    /// normals until it is about a pixel across at its distance (the
    /// frame's inverse resolution and the projection's focal length give a
    /// pixel's size there), so a 5 mm line 30 m off is drawn whole rather
    /// than in dashes. Near, where the tube already covers a pixel, nothing
    /// changes.
    static let wireGeometry = """
    #pragma body
    float4 wv = scn_node.modelViewTransform * _geometry.position;
    float wpx = 2.0 * max(-wv.z, 0.05) * scn_frame.inverseResolution.y / max(scn_frame.projectionTransform[1][1], 0.1);
    _geometry.position.xyz += _geometry.normal * max(0.55 * wpx - 0.005, 0.0);
    """

    /// Roofs: texcoord 0 = (metres along the eaves, metres down the slope),
    /// texcoord 1 = (id + seed / 2, metres up from the eave line); ids 0-3
    /// are cj_roof.jpg's tiles (`BuildingBuilder.RoofCover`), 4 up the
    /// trims (`BuildingBuilder.RoofTrim`).
    static let roofGeometry = """
    #pragma varyings
    float4 rdat;
    #pragma body
    out.rdat = float4(_geometry.texcoords[0], _geometry.texcoords[1]);
    """

    /// The cover's 2 m tile, from a per-roof offset (a whole pantile
    /// across, so ridge tiles keep the crown), toned per roof and mottled
    /// at roof scale. Moss grows on the north slopes, towards the eaves and
    /// first in the laps and troughs; lichen spots the sunny side. Trims
    /// (boards, flat roofs, dark ridges, lead rolls) take a flat colour.
    /// On the Riviera (`riviera` 1, cj_roof_lig.jpg) the tiles lie eight to
    /// the 2 m tile, no moss grows, and the lichen is the orange and grey
    /// of sun-baked terracotta.
    static let roofSurface = """
    #pragma arguments
    texture2d<float> roofTex;
    texture2d<float> roofDetail;
    texture2d<float> grimeTex;
    float detailNormals;
    float riviera;
    #pragma body
    bool lig = riviera > 0.5;
    constexpr sampler rep(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));
    float2 uv = in.rdat.xy;
    float id = floor(in.rdat.z + 0.01);
    float seed = saturate((in.rdat.z - id) * 2.0);
    float up = in.rdat.w;
    float tile = min(id, 3.0);
    float across = lig ? 8.0 : 7.0;
    float2 t = uv * 0.5 + float2(floor(fract(seed * 5.31) * across) / across, fract(seed * 3.17));
    float2 tdx = dfdx(t), tdy = dfdy(t);
    float3 dp1 = dfdx(_surface.position), dp2 = dfdy(_surface.position);
    float3 N0 = normalize(_surface.normal);
    float3 nW = normalize((scn_frame.inverseViewTransform * float4(N0, 0.0)).xyz);
    // Half a texel of the sampled level clear of the tile's edges, so
    // filtering never reads the neighbouring tile.
    float2 gx = tdx * 0.5, gy = tdy * 0.5;
    float W = float(roofTex.get_width());
    float lod = max(0.5 * log2(max(max(dot(gx, gx), dot(gy, gy)) * W * W, 1e-8)), 0.0);
    float inset = min(0.5 * exp2(lod) / (0.5 * W), 0.2);
    float2 a = (float2(fmod(tile, 2.0), floor(tile * 0.5)) + clamp(fract(t), inset, 1.0 - inset)) * 0.5;
    float3 alb = roofTex.sample(rep, a, gradient2d(gx, gy)).rgb;
    float4 d = roofDetail.sample(rep, a, gradient2d(gx, gy));
    float4 g = grimeTex.sample(rep, uv * 0.11 + float2(seed * 4.1, seed * 2.7));
    float4 g2 = grimeTex.sample(rep, uv * 0.57 + float2(seed * 1.3, seed * 0.7));
    alb *= (0.86 + 0.28 * fract(seed * 13.7)) * (0.82 + 0.34 * g.a);
    float north = saturate(-nW.z * 0.9 + 0.1);
    float mossy = fract(seed * 29.3);
    // Where moss takes (metres-wide drifts, north, low on the roof, more on
    // some roofs), then tufts in the laps and troughs within that.
    float region = g.a * 0.5 + g.b * 0.4 + north * 0.6 + mossy * 0.45 - saturate(up * 0.1) * 0.35 - 0.8;
    float tuft = (1.0 - d.a) * 0.55 + g2.b * 0.45;
    float moss = smoothstep(0.1, 0.5, region + (tuft - 0.5) * 0.8) * (tile < 2.5 ? 1.0 : 0.4);
    float lichen = smoothstep(0.75, 0.9, g2.g) * (1.0 - north) * d.a * mossy;
    if (lig) {
        moss = 0.0;
        lichen = smoothstep(0.7, 0.9, g2.g) * d.a * (0.4 + 0.6 * mossy);
    }
    alb = mix(alb, mix(float3(0.035, 0.05, 0.018), float3(0.09, 0.1, 0.03), g2.a), moss * 0.75);
    alb = mix(alb, lig ? mix(float3(0.45, 0.26, 0.06), float3(0.3, 0.29, 0.25), g2.a) : float3(0.42, 0.41, 0.3),
              lichen * (lig ? 0.3 : 0.45));
    bool trim = id > 3.5;
    float3 trimCol = id < 4.5 ? float3(0.70, 0.70, 0.68) : (id < 5.5 ? float3(0.03, 0.028, 0.026)
                   : (id < 6.5 ? float3(0.05, 0.05, 0.048) : (id < 7.5 ? float3(0.055, 0.058, 0.064)
                   : float3(0.17, 0.18, 0.19))));
    alb = trim ? trimCol * (0.85 + 0.3 * g.a) : alb;
    float2 nxy = (d.rg * 2.0 - 1.0) * detailNormals * (trim ? 0.0 : 1.0 - 0.6 * moss);
    float3 nts = float3(nxy, sqrt(saturate(1.0 - dot(nxy, nxy))));
    float3 dp2perp = cross(dp2, N0);
    float3 dp1perp = cross(N0, dp1);
    float3 Tn = dp2perp * tdx.x + dp1perp * tdy.x;
    float3 Bn = dp2perp * tdx.y + dp1perp * tdy.y;
    float invmax = rsqrt(max(max(dot(Tn, Tn), dot(Bn, Bn)), 1e-20));
    _surface.normal = normalize(Tn * invmax * nts.x + Bn * invmax * nts.y + N0 * nts.z);
    _surface.diffuse = float4(alb, 1.0);
    _surface.roughness = trim ? (id < 5.5 ? 0.55 : (id < 6.5 ? 0.9 : (id < 7.5 ? 0.6 : 0.45)))
                              : mix(d.b, 0.95, max(moss, lichen));
    _surface.ambientOcclusion *= trim ? 1.0 : 0.55 + 0.45 * d.a;
    """

    /// Greenhouse glass and film (the Riviera's serre): texcoord 0 = metres
    /// along and across the face, texcoord 1 = (`BuildingBuilder.GlassPart`
    /// + seed / 2, the span width on a far roof).
    static let greenhouseGeometry = """
    #pragma varyings
    float4 gdat;
    #pragma body
    out.gdat = float4(_geometry.texcoords[0], _geometry.texcoords[1]);
    """

    /// Opaque, so hundreds of houses cost no sorting, and drawn as glass by
    /// its parts: the whitewash (shading paint sprayed on in spring) is the
    /// lit surface, milky white-green (#c6d4d0 to #e8edea from the road,
    /// grey-green #7b8d85 to #8d9e97 from the air); through the clear
    /// glass the house's inside shows, lit through its roof, and the glass
    /// mirrors the sky by Fresnel's law (Schlick, F0 0.04), both as
    /// emission in the scene's radiance (`glassK`: x the radiance of a
    /// white board facing the sun, y the sky's, z `SkyLighting.skyScale`;
    /// `glassSky` the sea's sky above the horizon, cj_sea_sky.jpg). The
    /// paint is even over a house, a little thicker or thinner along the
    /// brush and on the odd pane put back clear, so a wall reads as one
    /// sheet of glass, not a chequer (2024 POV, look s 2556 and 2615: sky
    /// in the panes, the crop and benches through them). On the walls the
    /// inside is drawn at depth (parallax): the crop on its benches up to
    /// about a metre, then the bright house with its posts. Panes 0.73 m
    /// wide on thin glazing bars, galvanised or aluminium on most houses,
    /// white-painted on some, dark rusting steel on the oldest, with a
    /// heavier post every four panes that still reads at 100 m; about a
    /// fifth of the houses half-abandoned (grimier, some panes broken and
    /// the dark inside showing). Film tunnels are milky film on their hoops,
    /// glowing where the sun is behind them. A far house's roof is one
    /// plane at mid height (`GlassPart.spanRoof`): its spans are drawn by
    /// tilting the normal up and down each half span, so the saw-tooth still
    /// catches the sun span by span. Bars, the inside and broken panes fade
    /// to their mean under a few pixels.
    static let greenhouseSurface = """
    #pragma arguments
    float3 toSun;
    texture2d<float> glassSky;
    float4 glassK;
    #pragma body
    constexpr sampler skySm(filter::linear, mip_filter::linear, s_address::repeat, t_address::clamp_to_edge);
    float2 uv = in.gdat.xy;
    float id = floor(in.gdat.z + 0.01);
    float seed = saturate((in.gdat.z - id) * 2.0);
    float aux = in.gdat.w;
    float2 fw = fwidth(uv);
    float px = max(fw.x, fw.y);
    float wash = 0.3 + 0.7 * fract(seed * 7.31);
    bool derelict = fract(seed * 3.71) < 0.22;
    float brokenShare = derelict ? 0.12 : 0.006;
    float fk = fract(seed * 11.3);
    // Glazing bars: galvanised steel weathered to a mid grey (#7c7f7f in sun
    // in the 2024 frames at look s 2556 and 2615, darker than the panes),
    // white-painted on a few houses, dark rusting steel on the oldest.
    float3 frameC = fk < 0.65 ? float3(0.20, 0.21, 0.21) : (fk < 0.8 ? float3(0.46, 0.47, 0.45)
                  : float3(0.10, 0.08, 0.06) * (0.8 + 0.4 * fract(seed * 5.9)));
    bool galv = fk < 0.65;
    float3 N0 = normalize(_surface.normal);
    float3 V = normalize(-_surface.position);
    if (dot(N0, V) < 0.0) N0 = -N0;
    float3 L = normalize((scn_frame.viewTransform * float4(toSun, 0.0)).xyz);
    // Light inside a house: the sun and sky through its painted roof.
    float lightIn = (glassK.x * max(toSun.y, 0.0) + glassK.y) * 0.5;
    bool roofGlass = id < 0.5 || id > 3.5;
    float2 pitch = roofGlass ? float2(0.73, 1.65) : float2(0.73, 1.05);
    float far = smoothstep(0.015, 0.06, px);
    float3 alb;
    float rough = 0.3, metal = 0.0;
    float3 emit = float3(0.0);
    float3 N = N0;
    float3 dp1 = dfdx(_surface.position), dp2 = dfdy(_surface.position);
    float2 d1 = dfdx(uv), d2 = dfdy(uv);
    if (id > 2.5 && id < 3.5) {
        // Steel: gutters, ridge bars, hoops.
        alb = frameC;
        rough = 0.55;
        metal = galv ? 0.6 : 0.2;
    } else if (id > 1.5 && id < 2.5) {
        // Milky film over hoops every 1.5 m, wrinkled and weathered.
        float hf = fract(uv.x / 1.5);
        float hoop = (1.0 - smoothstep(0.03, 0.03 + max(fw.x, 0.004), min(hf, 1.0 - hf) * 1.5)) * (1.0 - far);
        float wr = 0.94 + 0.06 * sin(uv.x * 9.0 + sin(uv.y * 3.1) * 2.0 + seed * 20.0);
        alb = float3(0.55, 0.58, 0.565) * (0.88 + 0.12 * wash) * wr;
        alb = mix(alb, frameC, hoop + far * 0.03);
        rough = 0.5;
        emit = alb * glassK.x * 0.22 * saturate(-dot(N0, L));
    } else {
        float spanLine = 0.0;
        if (id > 3.5) {
            // A far house's roof: tilt the normal up the first half of each
            // span and down the second, about the span's own axis.
            float sw = max(aux, 1.0);
            float fx = fract(uv.y / sw);
            float det = d1.x * d2.y - d2.x * d1.y;
            float3 dv = (dp2 * d1.x - dp1 * d2.x) / (abs(det) > 1e-12 ? det : 1e-12);
            float lv = length(dv);
            if (lv > 1e-6) {
                float3 across = dv / lv;
                N = normalize(N0 - across * (fx < 0.5 ? 0.466 : -0.466));
            }
            // Gutters and ridge bars along the span lines.
            float dl = min(min(fx, abs(fx - 0.5)), 1.0 - fx) * sw;
            pitch = float2(0.73, 1e4);
            spanLine = 1.0 - smoothstep(0.05, 0.05 + max(fw.y, 0.01), dl);
        }
        float2 q = uv / pitch;
        float2 cell = floor(q);
        float2 de = min(fract(q), 1.0 - fract(q)) * pitch;
        // Upright bars 5 cm across on a wall, 4 cm on a roof; the glazing
        // bars across the panes 0.7 of that.
        float bw = roofGlass ? 0.02 : 0.025;
        float barU = 1.0 - smoothstep(bw, bw + max(fw.x, 0.004), de.x);
        float barV = 1.0 - smoothstep(0.7 * bw, 0.7 * bw + max(fw.y, 0.004), de.y);
        float post = 0.0;
        if (!roofGlass) {
            // A post every four panes and the sill rail: heavier, they
            // keep the frame where the bars have faded.
            float qp = uv.x / (4.0 * pitch.x);
            float dpst = min(fract(qp), 1.0 - fract(qp)) * 4.0 * pitch.x;
            post = max(1.0 - smoothstep(0.045, 0.045 + max(fw.x, 0.006), dpst),
                       1.0 - smoothstep(0.06, 0.06 + max(fw.y, 0.006), uv.y));
        }
        float bar = max(max(max(barU, barV), spanLine), post);
        float barMean = saturate(2.0 * bw / pitch.x + 1.4 * bw / min(pitch.y, 10.0)) + (id > 3.5 ? 0.06 : 0.0)
                      + (roofGlass ? 0.0 : 0.09 / (4.0 * pitch.x));
        bar = mix(bar, barMean, far);
        float h = fract(sin(dot(cell, float2(12.9898, 78.233)) + seed * 43.1) * 43758.5453);
        float h2 = fract(h * 91.7 + seed * 3.3);
        float broken = mix(h < brokenShare ? 1.0 : 0.0, brokenShare * 0.7, far);
        // The paint: one coat over the house, sprayed thicker on the roofs;
        // along the brush a little more or less, the odd pane put back clear.
        // The walls get the overspray only: from the road their panes are
        // mostly clear (the 2024 frames at look s 2556 and 2615 and the 2023
        // photo at 2600: crop, benches and the house's posts through them,
        // sky in the upper panes). From 35 m out to 120 m what shows through
        // averages to the house's milky white-green (#c6d4d0 to #e8edea in
        // look.md section 4), so the coat drawn thickens to the old one there.
        float dist = length(_surface.position);
        float wallWash = wash * (0.45 + 0.5 * fract(seed * 2.17)) * (derelict ? 0.7 : 1.0);
        wallWash *= mix(0.32, 1.0, smoothstep(35.0, 120.0, dist));
        float streak = (roofGlass ? 0.07 : 0.05) * sin(uv.x * 0.83 + seed * 31.0) * sin(uv.y * 1.7 + uv.x * 0.31 + seed * 7.0);
        float paneWash = saturate((roofGlass ? wash : wallWash) * (0.93 + 0.14 * h2) + streak);
        paneWash *= (h2 > 0.965 && !derelict) ? 0.3 : 1.0;
        paneWash = mix(paneWash, roofGlass ? wash : wallWash, far);
        // Old glass: each pane set at its own slight tilt, so the sky
        // breaks pane by pane.
        float3 Tn = normalize(cross(dp2, N0) * d1.x + cross(N0, dp1) * d2.x + 1e-9);
        float3 Bn = normalize(cross(dp2, N0) * d1.y + cross(N0, dp1) * d2.y + 1e-9);
        if (id < 3.5) N = normalize(N + (Tn * (h - 0.5) + Bn * (h2 - 0.5)) * 0.03 * (1.0 - far));
        // The inside, lit through the roof: from the air the crop on the
        // benches; on a wall, seen at depth, the crop to about a metre
        // over the curb (bench tops 0.3 m), then the bright house, its
        // posts every 3.2 m and the glass across the house.
        float3 inside;
        if (roofGlass) {
            inside = float3(0.07, 0.095, 0.06) * (0.8 + 0.4 * h2) * lightIn;
        } else {
            float3 Vin = -V;
            float vz = max(dot(Vin, -N0), 0.18);
            float2 off = clamp(float2(dot(Vin, Tn), dot(Vin, Bn)) / vz, -6.0, 6.0);
            float2 cu = uv + off * 0.7;
            float2 cq = cu * float2(3.1, 4.3);
            float2 ci = floor(cq), cf = fract(cq);
            cf = cf * cf * (3.0 - 2.0 * cf);
            float n00 = fract(sin(dot(ci, float2(12.9898, 78.233)) + seed * 17.0) * 43758.5453);
            float n10 = fract(sin(dot(ci + float2(1.0, 0.0), float2(12.9898, 78.233)) + seed * 17.0) * 43758.5453);
            float n01 = fract(sin(dot(ci + float2(0.0, 1.0), float2(12.9898, 78.233)) + seed * 17.0) * 43758.5453);
            float n11 = fract(sin(dot(ci + float2(1.0, 1.0), float2(12.9898, 78.233)) + seed * 17.0) * 43758.5453);
            float nz = mix(mix(n00, n10, cf.x), mix(n01, n11, cf.x), cf.y);
            // The crop on its benches to 0.9-1.4 m (pots on aluminium
            // tables, roses and marguerites grown tall), dark in the shade
            // under the benches, a pale bench edge at 0.8 m.
            float top = 0.9 + 0.5 * nz;
            float crop = 1.0 - smoothstep(top - 0.15, top, cu.y);
            float3 leaves = mix(float3(0.022, 0.040, 0.020), float3(0.080, 0.115, 0.045), nz);
            // A few pots in flower (ranunculus, marguerites), cell by cell
            // (a threshold on the smooth noise drew its contours as rings).
            float bloom = step(0.9, n10) * step(0.4, fract(seed * 4.3));
            leaves = mix(leaves, float3(0.45, 0.30, 0.32), bloom * 0.5);
            float bench = (1.0 - smoothstep(0.0, 0.05, abs(cu.y - 0.8))) * step(0.5, fract(seed * 6.1));
            leaves = mix(leaves, float3(0.30, 0.31, 0.30), bench * 0.7);
            leaves = mix(leaves, float3(0.012, 0.014, 0.012), (1.0 - smoothstep(0.35, 0.6, cu.y)) * 0.8);
            // Above it the house's air, lit through its whitewashed roof:
            // brighter towards the roof, its posts every 3.2 m and the far
            // side's gutter dark against it.
            float2 pu = uv + off * 3.0;
            float pf = fract(pu.x / 3.2);
            float postIn = 1.0 - smoothstep(0.03, 0.07, min(pf, 1.0 - pf) * 3.2);
            float gutter = 1.0 - smoothstep(0.04, 0.09, abs(pu.y - 2.6));
            float3 room = mix(float3(0.26, 0.29, 0.27), float3(0.50, 0.55, 0.52), smoothstep(1.0, 2.8, cu.y));
            room = mix(room, float3(0.09, 0.10, 0.10), max(postIn, gutter) * 0.75);
            inside = mix(room, leaves, crop);
            inside = mix(inside, float3(0.24, 0.27, 0.25), far);
            inside *= lightIn;
        }
        // The sky in the glass (below the horizon, the ground).
        float3 Rv = reflect(-V, N);
        float3 R = (scn_frame.inverseViewTransform * float4(Rv, 0.0)).xyz;
        float u = atan2(R.x, -R.z) * 0.15915494 + 1.0;
        float3 sky = glassSky.sample(skySm, float2(u, 1.0 - saturate(R.y)), level(1.5 + 3.0 * paneWash)).rgb * glassK.z;
        float3 earth = float3(0.16, 0.15, 0.12) * lightIn;
        sky = mix(earth, sky, smoothstep(-0.06, 0.02, R.y));
        float F = 0.04 + 0.96 * pow(1.0 - saturate(dot(N, V)), 5.0);
        float3 washC = roofGlass ? float3(0.36, 0.42, 0.39) : float3(0.50, 0.55, 0.53);
        float3 dirt = roofGlass ? float3(0.16, 0.20, 0.18) : float3(0.03, 0.035, 0.03);
        if (roofGlass) {
            // From above (the aerials' grey-green) the glass keeps its old
            // albedo, the crop under it lit through it.
            alb = mix(dirt, washC, paneWash);
            inside *= 0.0;
        } else {
            alb = mix(dirt * (derelict ? 2.0 : 1.0), washC, paneWash);
        }
        // Dirt and green slime along the lower edge of each pane.
        float laps = smoothstep(0.75, 1.0, fract(q.y)) * (1.0 - far) * 0.12;
        alb *= 1.0 - laps;
        float3 glassEmit = inside * (1.0 - F) * (1.0 - 0.88 * paneWash) * (roofGlass ? 0.85 : 0.95)
                         + sky * F * (1.0 - (roofGlass ? 0.75 : 0.5) * paneWash);
        // The sun through the paint from behind.
        glassEmit += washC * paneWash * glassK.x * 0.25 * saturate(-dot(N0, L));
        float3 hole = roofGlass ? float3(0.03, 0.04, 0.025) : float3(0.0);
        alb = mix(mix(alb, hole, broken), frameC, bar);
        emit = mix(mix(glassEmit, inside, broken), float3(0.0), bar);
        // Whitewash is matt; clear glass keeps its gloss.
        rough = mix(mix(mix(0.3, 0.6, paneWash), 0.95, broken), 0.5, bar);
        metal = bar * (galv ? 0.5 : 0.15);
    }
    _surface.normal = N;
    _surface.diffuse = float4(alb, 1.0);
    _surface.roughness = rough;
    _surface.metalness = metal;
    _surface.emission = float4(emit, 1.0);
    """
}
