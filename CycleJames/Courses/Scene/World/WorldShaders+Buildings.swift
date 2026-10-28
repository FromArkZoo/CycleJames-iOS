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
    /// ribs; a dry-stone retaining wall laid in slabs; rain streaks under the eaves, a damp, splashed foot with green
    /// on the shady side, and ambient occlusion where the wall meets the
    /// ground and under the eaves. The atlas's glass is dark and bluish: it
    /// turns smooth, so it mirrors the sky. The light raster
    /// (`WorldShaders+Light`) dims the sky light on walls in the lanes and
    /// low on every wall, and gives them the sun's shade past the shadow
    /// map (a hedge's or shed's on the lower metres only); chimneys stay
    /// open and sunlit.
    static let wallSurface = """
    #pragma arguments
    texture2d<float> grimeTex;
    texture2d<float> facadeTex;
    \(lightArgs)
    #pragma body
    constexpr sampler rep(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(4));
    constexpr sampler cellS(filter::linear, mip_filter::linear, address::clamp_to_edge, max_anisotropy(8));
    float hG = in.wdat.x;
    float below = in.wdat.y;
    float code = floor(in.wdat.z + 0.5);
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
    float rough = mix(0.85, 0.1, glass);
    if (kind > 0.5 && kind < 4.5) {
        const float4 plinths[4] = {
            float4(0.020, 0.019, 0.018, 0.45), float4(0.034, 0.036, 0.040, 0.6),
            float4(0.050, 0.055, 0.060, 0.7), float4(0.150, 0.145, 0.135, 0.9) };
        float4 pl = plinths[int(clamp(kind - 1.0, 0.0, 3.0))];
        alb = pl.rgb * (0.75 + 0.5 * smoothstep(0.03, 0.6, lum));
        rough = pl.a;
    }
    if (kind > 7.5) {
        // A dry-stone retaining wall: flat schist and sandstone slabs in
        // rough courses 7-15 cm high, each 20-60 cm long, grey to brown,
        // with dark open joints and no mortar; the joints fade to their
        // mean under a few pixels.
        float2 sp = gp;
        // Metres per pixel: the blank wall's texcoord runs a cell (3 m) per unit.
        float pxs = 3.0 * max(length(tdx), length(tdy));
        float band = floor(sp.y / 0.11);
        float hb = fract(sin(band * 91.7 + seed * 13.1) * 43758.5453);
        float rowH = 0.07 + 0.08 * hb;
        float fy = fract(sp.y / 0.11) * 0.11 / rowH;
        float row = band * 3.0 + floor(fy);
        float hr = fract(sin(row * 37.13 + seed * 5.7) * 43758.5453);
        float len = 0.2 + 0.4 * hr;
        float xs = sp.x / len + hr * 7.0;
        float hs = fract(sin(floor(xs) * 12.9898 + row * 78.233 + seed * 3.1) * 43758.5453);
        float jx = min(fract(xs), 1.0 - fract(xs)) * len;
        float jy = min(fract(fy), 1.0 - fract(fy)) * rowH;
        float joint = (1.0 - smoothstep(0.005, 0.016, min(jx, jy))) * (1.0 - smoothstep(0.01, 0.04, pxs));
        float3 slab = mix(float3(0.060, 0.058, 0.054), float3(0.105, 0.092, 0.074), hs);
        slab *= 0.85 + 0.3 * fract(hs * 17.0);
        alb = mix(slab, float3(0.012, 0.011, 0.010), joint * 0.85 + 0.15 * smoothstep(0.01, 0.04, pxs));
        rough = 0.92;
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
        if (steel) {
            c = sheet[int(pick * 3.99)] * (1.0 + (smoothstep(0.1, 0.2, f) * (1.0 - smoothstep(0.45, 0.55, f)) - 0.4) * 0.35 * fade);
        } else {
            float n = fract(sin(floor(x) * 12.9898 + seed * 78.233) * 43758.5453);
            float joint = 1.0 - smoothstep(0.04, 0.12, min(f, 1.0 - f));
            c = timber[int(pick * 4.99)] * (1.0 + (n - 0.5) * 0.22 * fade) * (1.0 - 0.6 * joint * fade);
        }
        float edge = min(min(dl.x, sz.x - dl.x), sz.y - dl.y);
        float meet = sz.x > 1.8 ? abs(dl.x - 0.5 * sz.x) + 0.03 : 1.0;
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
    _surface.diffuse = float4(alb, 1.0);
    _surface.roughness = mix(rough, 0.95, foot * 0.6);
    _surface.ambientOcclusion *= mix(0.5, 1.0, smoothstep(-0.05, 0.9, hG)) * mix(0.55, 1.0, smoothstep(0.0, 0.7, below));
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
    /// (boards, flat roofs, dark ridges) take a flat colour.
    static let roofSurface = """
    #pragma arguments
    texture2d<float> roofTex;
    texture2d<float> roofDetail;
    texture2d<float> grimeTex;
    float detailNormals;
    #pragma body
    constexpr sampler rep(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));
    float2 uv = in.rdat.xy;
    float id = floor(in.rdat.z + 0.01);
    float seed = saturate((in.rdat.z - id) * 2.0);
    float up = in.rdat.w;
    float tile = min(id, 3.0);
    float2 t = uv * 0.5 + float2(floor(fract(seed * 5.31) * 7.0) / 7.0, fract(seed * 3.17));
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
    alb = mix(alb, mix(float3(0.035, 0.05, 0.018), float3(0.09, 0.1, 0.03), g2.a), moss * 0.75);
    alb = mix(alb, float3(0.42, 0.41, 0.3), lichen * 0.45);
    bool trim = id > 3.5;
    float3 trimCol = id < 4.5 ? float3(0.70, 0.70, 0.68) : (id < 5.5 ? float3(0.03, 0.028, 0.026)
                   : (id < 6.5 ? float3(0.05, 0.05, 0.048) : float3(0.055, 0.058, 0.064)));
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
    _surface.roughness = trim ? (id < 5.5 ? 0.55 : (id < 6.5 ? 0.9 : 0.6)) : mix(d.b, 0.95, max(moss, lichen));
    _surface.ambientOcclusion *= trim ? 1.0 : 0.55 + 0.45 * d.a;
    """
}
