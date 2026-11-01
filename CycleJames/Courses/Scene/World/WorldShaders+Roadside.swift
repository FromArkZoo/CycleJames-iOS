import SceneKit

/// The Riviera's roadside (`BuildingBuilder.buildRivieraRoadside`): its
/// walls' stone and concrete laid out by the shader, galvanised steel,
/// chain-link and shade net. Colours are the look bible's paints (look.md
/// section 3), linear.
extension WorldShaders {
    /// Masonry: texcoord 0 = (stone code × 1024 + metres along the wall,
    /// height above the wall's foot); see `CourseArt.Stone`.
    static let masonryGeometry = """
    #pragma varyings
    float2 mdat;
    #pragma body
    out.mdat = _geometry.texcoords[0];
    """

    /// Stone laid at true scale, block by block, so no course repeats:
    /// rows of random height two to a band, each block its own length,
    /// colour and surface (cj_stone_lig_detail at an offset of its own),
    /// its arrises rounded into recessed joints; a road face in wall metres
    /// (along it, and level courses up it), a flat top in plan. Honey
    /// sandstone in its four tones with dark joints and weeds in some; the
    /// newer grey squared stone in regular courses; dry-stone terraces with
    /// open joints and a grassy top; grey rubble; brick. Concrete over
    /// cj_concrete_lig_detail: copings jointed every metre, parapets in
    /// cast panels, precast blocks, beige render streaked with damp, the
    /// dark-grey painted wall, white render; reed screens cane by cane;
    /// rusty corrugated sheet; the piazza's gneiss slabs in running bond.
    /// Joints and canes fade to their mean under a few pixels. Damp and
    /// splash at the foot, the light raster as on the house walls.
    static let masonrySurface = """
    #pragma arguments
    texture2d<float> stoneDetail;
    texture2d<float> concreteDetail;
    texture2d<float> grimeTex;
    \(lightArgs)
    #pragma body
    constexpr sampler rep(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));
    float code = floor(in.mdat.x * (1.0 / 1024.0) + 0.0005);
    float along = in.mdat.x - code * 1024.0;
    float hFoot = in.mdat.y;
    int kind = int(code + 0.5);
    float3 wp = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
    float3 N0 = normalize(_surface.normal);
    float3 nW = normalize((scn_frame.inverseViewTransform * float4(N0, 0.0)).xyz);
    bool flatTop = nW.y > 0.7;
    // Metres on the surface, the second running down: along the wall and
    // down from a level datum on a face, the plan on a flat top.
    float2 q = flatTop ? float2(wp.x, wp.z) : float2(along, -wp.y);
    float2 qdx = dfdx(q), qdy = dfdy(q);
    float pxs = max(length(qdx), length(qdy));
    float4 gA = grimeTex.sample(rep, q * 0.19 + float2(code * 0.37, code * 0.11));
    float4 gS = grimeTex.sample(rep, float2(q.x * 0.83 + code * 0.5, q.y * 0.09));
    float3 alb = float3(0.4);
    float rough = 0.9;
    float2 tilt = float2(0.0);
    float cav = 1.0;
    float joint = 0.0;
    float weeds = 0.0;
    bool stone = kind == 0 || kind == 1 || kind == 2 || kind == 7 || kind == 8 || kind == 12;
    if (stone) {
        bool regular = kind == 1 || kind == 12;
        // Two rows to a band. The honey sandstone lies in thin courses of
        // long stones, three or four times as long as high (the 2024 frames
        // at 0-340 m: 15-25 cm courses, stones 20-80 cm).
        float bandH = kind == 12 ? 0.15 : (kind == 1 ? 0.46 : (kind == 2 ? 0.5 : (kind == 0 ? 0.38 : 0.46)));
        float L = kind == 12 ? 0.25 : (kind == 1 ? 0.52 : (kind == 2 ? 0.3 : (kind == 0 ? 0.5 : 0.38)));
        float jw = kind == 12 ? 0.011 : (kind == 1 ? 0.012 : (kind == 2 ? 0.03 : (kind == 8 ? 0.026 : 0.022)));
        // Rough-squared stones: their joints wander a few centimetres
        // (courses and arrises alike), less in the newer squared stone.
        float wa = regular ? 0.008 : 0.035;
        float2 wq = q + (float2(stoneDetail.sample(rep, q * 0.31).a, stoneDetail.sample(rep, q * 0.29 + 0.5).a) - 0.5) * wa * 2.0;
        float yq = wq.y + (regular ? 0.0 : (gA.a - 0.5) * 0.06);
        float band = floor(yq / bandH);
        float hb = fract(sin(band * 91.7 + 3.1) * 43758.5453);
        float split = regular ? 0.5 : 0.36 + 0.28 * hb;
        float fb = yq / bandH - band;
        bool lower = fb > split;
        float row = band * 2.0 + (lower ? 1.0 : 0.0);
        float yin = fb * bandH;
        float r0 = lower ? split * bandH : 0.0;
        float r1 = lower ? bandH : split * bandH;
        float hr = fract(sin(row * 37.13 + 1.7) * 43758.5453);
        float xs = wq.x / L + hr * 7.0 + (kind == 12 ? fmod(row, 2.0) * 0.5 : 0.0);
        float ci = floor(xs);
        float jm = regular ? 0.0 : 0.7;
        float jA = (fract(sin(ci * 12.9898 + row * 78.233) * 43758.5453) - 0.5) * jm;
        float jB = (fract(sin((ci + 1.0) * 12.9898 + row * 78.233) * 43758.5453) - 0.5) * jm;
        float jP = (fract(sin((ci - 1.0) * 12.9898 + row * 78.233) * 43758.5453) - 0.5) * jm;
        float fx = xs - ci;
        float bl = fx < jA ? ci - 1.0 + jP : ci + jA;
        float br = fx < jA ? ci + jA : ci + 1.0 + jB;
        float bi = fx < jA ? ci - 1.0 : ci;
        float dxl = (xs - bl) * L, dxr = (br - xs) * L;
        float dyt = yin - r0, dyb = r1 - yin;
        float hs = fract(sin(bi * 12.9898 + row * 78.233 + 4.1) * 43758.5453);
        float hs2 = fract(hs * 57.31 + row * 0.13);
        // The block's own surface: the detail tile at an offset of its own.
        float2 dq = q + float2(hs * 0.73, hs2 * 0.61);
        float4 d = stoneDetail.sample(rep, dq, gradient2d(qdx, qdy));
        // Rounded corners: a soft minimum of the distances to the nearest
        // head and bed joints.
        float dx = min(dxl, dxr), dy = min(dyt, dyb);
        float kr = regular ? 0.006 : 0.018;
        float dlo = min(dx, dy);
        float dmin = dlo - kr * log(1.0 + exp(-(max(dx, dy) - dlo) / kr)) + kr * 0.69 + (d.b - 0.9) * 0.012;
        // The joint box-filtered over the pixel's footprint, so it thins
        // into a fainter line with distance instead of vanishing and
        // leaving the stones' colours as a mosaic; where the courses fall
        // under a few pixels, the joints' mean cover.
        float hw = jw * 0.72;
        float pf = max(pxs, jw * 0.3);
        float cover = saturate((min(dmin + pf * 0.5, hw) - max(dmin - pf * 0.5, -hw)) / pf);
        float rowH = bandH * 0.5;
        float far = smoothstep(rowH * 0.18, rowH * 0.42, pxs);
        joint = mix(cover, min(2.0 * hw / L + 2.0 * hw / rowH, 0.45), far);
        float fade = 1.0 - smoothstep(0.004, 0.03, pxs);
        // Rounded arrises: the face turns down into the joint.
        float edge = (1.0 - smoothstep(0.0, regular ? 0.015 : 0.025, dmin - jw * 0.5)) * fade;
        float2 toEdge = min(dxl, dxr) < min(dyt, dyb) ? float2(dxl < dxr ? -1.0 : 1.0, 0.0)
                                                      : float2(0.0, dyt < dyb ? -1.0 : 1.0);
        tilt = toEdge * edge * (regular ? 0.35 : 0.3) + (d.rg * 2.0 - 1.0) * (regular ? 0.5 : 1.05);
        cav = mix(0.8, 1.0, d.b);
        float3 c;
        float3 jc;
        // The stones' mean colour, which they fade to as the courses fall
        // under a few pixels.
        float3 cm = float3(0.4);
        if (kind == 0) {
            // Pale honey #bba984 to ochre #a8936c, a few grey-brown #8a7d68
            // and the odd rust-orange #a07a55, a quarter less saturated than
            // the paints: the 2024 frames' sunlit wall (#7e6e57 a stop
            // under) is greyer than they render.
            c = mix(float3(0.497, 0.397, 0.235), float3(0.392, 0.292, 0.150), fract(hs * 3.7));
            c = hs < 0.86 ? c : (hs < 0.975 ? float3(0.254, 0.205, 0.138) : float3(0.352, 0.195, 0.091));
            c = mix(float3(dot(c, float3(0.2126, 0.7152, 0.0722))), c, 0.75);
            cm = float3(0.39, 0.322, 0.215);
            jc = float3(0.078, 0.059, 0.036);
        } else if (kind == 1) {
            // Grey squared stone #b4ab9b, pointed in a pale mortar a little
            // darker than the stone (PezCycling 2007, the hairpin's outside).
            c = float3(0.456, 0.407, 0.332) * (0.88 + 0.22 * hs) * (hs2 < 0.15 ? float3(1.06, 1.0, 0.9) : float3(1.0));
            cm = float3(0.456, 0.407, 0.332);
            jc = float3(0.3, 0.282, 0.25);
        } else if (kind == 2) {
            c = mix(float3(0.34, 0.32, 0.28), float3(0.39, 0.29, 0.15), hs) * (0.8 + 0.3 * hs2);
            cm = float3(0.34, 0.29, 0.21);
            jc = float3(0.025, 0.021, 0.016);
        } else if (kind == 8) {
            c = mix(float3(0.19, 0.174, 0.146), float3(0.33, 0.297, 0.242), hs) * (0.85 + 0.25 * hs2);
            cm = float3(0.26, 0.237, 0.198);
            jc = float3(0.045, 0.04, 0.034);
        } else if (kind == 7) {
            // The dark wall the fans paint: rubble under coat after coat of
            // dark grey (#6e6b64), newer and older coats in patches, the
            // joints filled with paint a little darker than the stones.
            // (The coats' mean at the paint itself: after the stone's own
            // light and dark and the cavities, the old 0.15 came out at
            // about #363531 in the sun's shade, which the 2024 GoPro frames
            // read a stop under.)
            float coat = smoothstep(0.35, 0.65, gA.g);
            c = mix(float3(0.232, 0.22, 0.192), float3(0.176, 0.172, 0.16), coat) * (0.9 + 0.2 * hs2);
            cm = float3(0.205, 0.197, 0.178);
            jc = c * 0.5;
        } else {
            c = float3(0.392, 0.107, 0.054) * (0.8 + 0.35 * hs);
            cm = float3(0.38, 0.11, 0.055);
            jc = float3(0.42, 0.40, 0.35);
        }
        // Stone by stone a little lighter or darker; the honey sandstone
        // more so, weathered unevenly.
        float vary = kind == 0 ? 0.36 : (kind == 7 ? 0.12 : 0.2);
        c = mix(c * (1.0 - vary * 0.5 + vary * hs2), cm, far * 0.75) * (0.74 + 0.52 * d.a);
        if (kind == 0) cav = mix(0.72, 1.0, d.b);
        cav *= mix(1.0, 0.86, edge);
        alb = mix(c, jc, joint * (kind == 12 ? 1.0 : 0.92));
        rough = mix(0.88, 0.95, joint);
        // Grass, valerian and capers in some joints: patches, more low
        // down and in the old rubble.
        weeds = joint * smoothstep(0.55, 0.8, gA.b) * (kind == 1 || kind == 7 || kind == 12 ? 0.25 : 1.0)
              * (0.5 + 0.5 * (1.0 - smoothstep(0.2, 1.2, hFoot)));
    } else if (kind == 9) {
        // Reed screen: canes 2 cm thick, each its own straw-brown, bound by
        // a wire every 45 cm.
        float xc = q.x / 0.021;
        float ci = floor(xc), f = xc - ci;
        float hc = fract(sin(ci * 12.9898) * 43758.5453);
        float fade = 1.0 - smoothstep(0.004, 0.016, pxs);
        float3 cane = hc < 0.55 ? float3(0.147, 0.102, 0.056) : (hc < 0.8 ? float3(0.069, 0.048, 0.030)
                    : float3(0.30, 0.235, 0.135));
        cane *= 0.85 + 0.3 * fract(hc * 13.1);
        // Past a pixel a cane, bundles of a few canes each a shade of its
        // own (#6b5a43 to #4a3e30), still fibrous to some 15 m.
        float xb = q.x / 0.065;
        float hbd = fract(sin(floor(xb) * 31.7 + 2.3) * 43758.5453);
        float bfade = 1.0 - smoothstep(0.02, 0.07, pxs);
        // Old canes go grey: the screen at look s 220 is a dark grey-brown.
        float3 bundle = mix(float3(0.042, 0.036, 0.027), float3(0.105, 0.084, 0.056), hbd);
        cane = mix(float3(dot(cane, float3(0.2126, 0.7152, 0.0722))), cane, 0.6) * 0.75;
        alb = mix(mix(float3(0.068, 0.056, 0.039), bundle, bfade), cane * (0.8 + 0.4 * f * (1.0 - f) * 4.0), fade);
        // Weathered and newer strands in narrow vertical streaks.
        float4 gR = grimeTex.sample(rep, float2(q.x * 6.0, q.y * 0.07));
        alb *= 0.78 + 0.44 * gR.a;
        tilt = float2((f - 0.5) * 1.4 * fade, 0.0);
        float tie = 1.0 - smoothstep(0.004, 0.009, abs(fract(q.y / 0.45) - 0.5) * 0.45);
        alb = mix(alb, float3(0.03), tie * fade * 0.8);
        rough = 0.85;
    } else if (kind == 10) {
        // Corrugated sheet, 76 mm pitch, rusted through its zinc.
        float w = sin(q.x * (6.2832 / 0.076));
        float fade = 1.0 - smoothstep(0.004, 0.015, pxs);
        tilt = float2(cos(q.x * (6.2832 / 0.076)) * 0.55 * fade, 0.0);
        float4 cd = concreteDetail.sample(rep, q * 0.5, gradient2d(qdx * 0.5, qdy * 0.5));
        alb = mix(float3(0.323, 0.144, 0.048), float3(0.147, 0.069, 0.030), saturate(gA.a * 0.8 + cd.a * 0.5 - 0.2));
        alb *= 0.9 + 0.1 * w * fade;
        rough = 0.8;
    } else {
        float4 cd = concreteDetail.sample(rep, q + float2(code * 0.31, code * 0.17), gradient2d(qdx, qdy));
        tilt = (cd.rg * 2.0 - 1.0) * 0.7;
        cav = mix(0.82, 1.0, cd.b);
        float fade = 1.0 - smoothstep(0.004, 0.02, pxs);
        float3 c;
        if (kind == 3) {
            // Coping, #8f8c84, a joint every metre. (Measured from the
            // nearest joint: the old test was true everywhere but at the
            // joints, so near to the eye the whole coping was drawn as a
            // joint, a black band under its sunlit top.)
            c = float3(0.275, 0.262, 0.235);
            joint = (1.0 - smoothstep(0.004, 0.008, 0.5 - abs(fract(q.x) - 0.5))) * fade;
        } else if (kind == 4) {
            // Cast parapet, #b5b2aa, in panels 2.5 m long.
            c = float3(0.462, 0.445, 0.402);
            joint = (1.0 - smoothstep(0.005, 0.01, (0.5 - abs(fract(q.x / 2.5) - 0.5)) * 2.5)) * fade;
        } else if (kind == 5) {
            // Grey precast blocks, 1.2 x 0.4 m.
            float row = floor(q.y / 0.4);
            float xs = q.x / 1.2 + fmod(row, 2.0) * 0.5;
            float hb = fract(sin(floor(xs) * 12.9898 + row * 78.233) * 43758.5453);
            c = float3(0.33, 0.32, 0.29) * (0.88 + 0.22 * hb);
            float dj = min(min(fract(xs), 1.0 - fract(xs)) * 1.2, min(fract(q.y / 0.4), 1.0 - fract(q.y / 0.4)) * 0.4);
            joint = (1.0 - smoothstep(0.004, 0.012, dj)) * fade + (1.0 - fade) * 0.05;
        } else if (kind == 6) {
            // Sprayed concrete over the cut bank, a weathered grey-beige
            // (#a99e8a in the sunlit 2024 frame at 1840 m; the bible's paint
            // #c9bca2 rendered sand-yellow in full sun), mottled in broad
            // patches. About 1.2-1.6 m up the render has fallen away along
            // the wall, a ragged band of the brown rubble under it, damp and
            // rust stains above that and a few runs down from it.
            // The rubble shows in patches a metre or two long whose height
            // wanders, not along a continuous band (that read as a tide line).
            c = float3(0.37, 0.33, 0.255);
            float4 gM = grimeTex.sample(rep, q * 0.07 + float2(0.21, 0.63));
            float4 gP = grimeTex.sample(rep, q * float2(0.23, 0.5) + float2(0.57, 0.13));
            c *= 0.78 + 0.44 * gM.a;
            c = mix(c, c * float3(0.86, 0.85, 0.82), smoothstep(0.55, 0.8, gP.r) * 0.6);
            float yb = hFoot + (gA.a - 0.5) * 0.35 + (gM.g - 0.5) * 0.9;
            float lost = smoothstep(1.45, 1.55, yb) * (1.0 - smoothstep(1.85, 1.95, yb))
                       * smoothstep(0.58, 0.7, gP.b * 0.75 + gA.g * 0.45);
            float4 st = stoneDetail.sample(rep, q * 2.3, gradient2d(qdx * 2.3, qdy * 2.3));
            float3 rubble = float3(0.3, 0.25, 0.175) * (0.55 + 0.7 * st.a) * mix(0.7, 1.0, st.b) * (0.85 + 0.3 * gA.b);
            float stain = smoothstep(2.2, 2.6, hFoot) * smoothstep(0.45, 0.8, gM.r);
            float4 gN = grimeTex.sample(rep, float2(q.x * 0.31 + 0.37, q.y * 0.05));
            float runs = smoothstep(0.62, 0.9, gN.r) * smoothstep(1.4, 2.2, yb) * 0.5;
            c = mix(c, float3(0.21, 0.18, 0.14), saturate(max(stain * 0.35, runs)));
            c = mix(c, rubble, lost);
            tilt *= 0.5 + 1.5 * lost;
        } else if (kind == 11) {
            // Gneiss slabs in running bond, 0.6 x 0.4 m, on fine joints.
            float row = floor(q.y / 0.4);
            float xs = q.x / 0.6 + fmod(row, 2.0) * 0.5 + fract(sin(row * 3.7) * 437.5) * 0.3;
            float hb = fract(sin(floor(xs) * 12.9898 + row * 78.233) * 43758.5453);
            c = float3(0.397, 0.413, 0.381) * (0.86 + 0.24 * hb) * (hb > 0.8 ? float3(0.96, 1.0, 1.03) : float3(1.0));
            float dj = min(min(fract(xs), 1.0 - fract(xs)) * 0.6, min(fract(q.y / 0.4), 1.0 - fract(q.y / 0.4)) * 0.4);
            joint = (1.0 - smoothstep(0.002, 0.006, dj)) * fade + (1.0 - fade) * 0.03;
            tilt *= 0.3;
            rough = 0.7;
        } else {
            // White render.
            c = float3(0.84, 0.82, 0.76);
            tilt *= 0.4;
        }
        c *= 0.86 + 0.28 * cd.a;
        alb = mix(c, c * 0.45, joint);
        if (kind != 11) rough = 0.9;
    }
    // Weathering: mottle, rain streaks down the faces, damp and splash at
    // the foot.
    alb *= 1.0 + (gA.a - 0.5) * 0.16;
    // (On the render, which has its own runs, they read as boarding.)
    // (Nor on the reed screen, where a metre-wide streak read as a board.)
    float streak = flatTop || kind == 9 ? 0.0 : smoothstep(0.5, 0.88, gS.r) * (kind == 6 ? 0.12 : 0.6);
    alb *= 1.0 - 0.22 * streak;
    float foot = 1.0 - smoothstep(0.0, 0.45 + 0.3 * gA.g, hFoot);
    alb = mix(alb, alb * float3(0.62, 0.58, 0.5), foot * 0.5);
    alb = mix(alb, float3(0.12, 0.15, 0.05), weeds * 0.85);
    alb *= cav;
    // A grassy top on the terraces and retaining walls without a coping
    // (the render's wide top too: grass and shrubs on its crest).
    if (flatTop && (kind == 0 || kind == 2 || kind == 6 || kind == 8)) {
        float grass = smoothstep(0.25, 0.6, gA.a + gA.b * 0.4);
        alb = mix(alb, mix(float3(0.16, 0.2, 0.075), float3(0.37, 0.33, 0.21), gA.g), grass * 0.85);
        tilt *= 1.0 - grass;
    }
    float3 nts = normalize(float3(tilt, 1.0));
    float3 dp1 = dfdx(_surface.position), dp2 = dfdy(_surface.position);
    float3 dp2perp = cross(dp2, N0), dp1perp = cross(N0, dp1);
    float3 Tn = dp2perp * qdx.x + dp1perp * qdy.x;
    float3 Bn = dp2perp * qdx.y + dp1perp * qdy.y;
    float invmax = rsqrt(max(max(dot(Tn, Tn), dot(Bn, Bn)), 1e-20));
    _surface.normal = normalize(Tn * invmax * nts.x + Bn * invmax * nts.y + N0 * nts.z);
    // The raster a metre out from the face: about the sky the face sees.
    float3 lgtP = wp + float3(nW.x, 0.0, nW.z) * 1.0;
    float3 lgtN = nW;
    float lgtD = -_surface.position.z;
    \(lightFetch)
    lgtQ.r = 1.0 - (1.0 - lgtQ.r) * exp2(0.3 - 0.2 * hFoot);
    lgtQ.g = mix(lgtQ.g, 1.0, smoothstep(1.5, 5.0, hFoot) * smoothstep(0.0, 2.0, hFoot - lgtQ.b * 40.0));
    \(lightApply)
    _surface.diffuse = float4(alb, 1.0);
    _surface.roughness = rough;
    _surface.ambientOcclusion *= (1.0 - 0.35 * joint) * mix(0.6, 1.0, smoothstep(0.0, 0.6, hFoot));
    """

    /// Galvanised steel: dull zinc, mottled and streaked darker where it
    /// has weathered, smoother where it hasn't.
    static let galvanisedSurface = """
    #pragma arguments
    texture2d<float> grimeTex;
    #pragma body
    constexpr sampler rep(filter::linear, mip_filter::linear, address::repeat);
    float3 wp = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
    // Streaked down the posts and beams, never banded round a pole.
    float4 g = grimeTex.sample(rep, float2((wp.x + wp.z) * 0.9, wp.y * 0.06));
    float dull = smoothstep(0.3, 0.8, g.a * 0.7 + g.r * 0.5);
    _surface.diffuse.rgb *= mix(1.0, 0.72, dull);
    _surface.roughness = mix(0.38, 0.62, dull);
    """

    /// Chain-link: texcoord 0 = (metres along, metres up), up offset by
    /// 100 for green plastic-coated mesh. 50 mm diamonds of 3 mm wire (4 mm
    /// coated), blended over what is behind; under a few pixels a mesh of
    /// that coverage. Up offset by 200 (galvanised) or 300 (painted blue):
    /// a balustrade's bars drawn the same way.
    static let chainLinkGeometry = """
    #pragma varyings
    float2 cdat;
    #pragma body
    out.cdat = _geometry.texcoords[0];
    """

    static let chainLinkSurface = """
    #pragma body
    float2 uv = in.cdat;
    float mode = floor(uv.y / 100.0 + 0.5);
    uv.y -= mode * 100.0;
    float fw = max(length(dfdx(uv)), length(dfdy(uv)));
    if (mode > 1.5) {
        // A balustrade's 22 mm round bars 12 cm apart. Seen at a slant a
        // round bar still shows its whole width while the gaps close up,
        // so on the panel it covers its width over the sine of the angle
        // (along the road the railing reads as a screen, as in the 2024
        // frame at 1840 m); box-filtered over the pixel and, once the bars
        // fall under a pixel, their coverage: as tubes they beat with the
        // pixel grid into bright arcs (moire).
        float3 V = normalize(_surface.view);
        float sinT = max(abs(dot(normalize(_surface.normal), V)), 0.02);
        // (18 mm bars about 16 cm apart in the 1840 frame: between two
        // posts the sea shows clearly until 25-30 m down the road.)
        float pitch = 0.16, hw = min(0.009 / sinT, 0.07);
        float x = (fract(uv.x / pitch) - 0.5) * pitch;
        float pf = max(fw, 1e-5);
        float bar = saturate((min(x + pf * 0.5, hw) - max(x - pf * 0.5, -hw)) / pf);
        float far = smoothstep(hw * 0.6, hw * 2.2, fw);
        // (Their mean, under a pixel, held to a half: the sea reads between
        // the bars to 30-40 m in the frame, where a full screen read as glazing.)
        float cover = mix(bar, min(2.0 * hw / pitch, 0.5), far);
        // Round: the bar's normal turns from facing the eye at its middle
        // to sideways at its edges (round its upright axis), facing the eye
        // once the bars are under a pixel. The panel's own normal, seen
        // along the road, mirrored the sky and hid the bars.
        float3 upV = normalize((scn_frame.viewTransform * float4(0.0, 1.0, 0.0, 0.0)).xyz);
        float3 nv = normalize(V - dot(V, upV) * upV + float3(1e-5));
        float xs = clamp(x / hw, -1.0, 1.0) * (1.0 - far);
        _surface.normal = normalize(nv * sqrt(max(1.0 - xs * xs, 0.0)) + cross(upV, nv) * xs);
        float shade = 1.0;
        bool blue = mode > 2.5;
        // Galvanised, or painted blue (the parapet at look s 1840: #2c4e8c
        // when new, sun-faded to a greyer mid blue, about #5a7090).
        float3 c = blue ? float3(0.1, 0.16, 0.28) : float3(0.5, 0.52, 0.53);
        _surface.diffuse = float4(c * shade, saturate(cover));
        _surface.roughness = blue ? 0.5 : 0.45;
        _surface.metalness = blue ? 0.0 : 0.6;
    } else {
        bool green = mode > 0.5;
        float r = green ? 0.002 : 0.0015;
        float d1 = abs(fract((uv.x + uv.y) / 0.0707 + 0.5) - 0.5) * 0.05;
        float d2 = abs(fract((uv.x - uv.y) / 0.0707 + 0.5) - 0.5) * 0.05;
        float d = min(d1, d2);
        float wire = 1.0 - smoothstep(r - fw * 0.5, r + fw * 0.5, d);
        float mean = 4.0 * r / 0.05;
        float cover = mix(wire, mean, smoothstep(0.002, 0.008, fw));
        float3 c = green ? float3(0.035, 0.09, 0.045) : float3(0.5, 0.52, 0.53);
        _surface.diffuse = float4(c, saturate(cover * 1.15));
        _surface.roughness = green ? 0.7 : 0.5;
        _surface.metalness = green ? 0.0 : 0.6;
    }
    """

    /// Shade netting, #33473a in the bible, teal-green in the sun (the 2024
    /// frames at 2130-2160 m): knitted tape, about three quarters cover, so
    /// the light and what is behind show through it. Texcoord 0 = (metres
    /// along, metres up); blended like the chain-link, the knit's holes
    /// fading to its coverage once they fall under a pixel, the tape's
    /// density and folds varying along it.
    static let shadeNetGeometry = """
    #pragma varyings
    float2 ndat;
    #pragma body
    out.ndat = _geometry.texcoords[0];
    """

    static let shadeNetSurface = """
    #pragma arguments
    texture2d<float> grimeTex;
    #pragma body
    constexpr sampler rep(filter::linear, mip_filter::linear, address::repeat);
    float2 uv = in.ndat;
    float fw = max(length(dfdx(uv)), length(dfdy(uv)));
    float4 g = grimeTex.sample(rep, uv * 0.37);
    float4 f = grimeTex.sample(rep, float2(uv.x * 1.7, uv.y * 0.05));
    // The knit: rows of tape 5 mm apart, zigzagging every 6 mm, a hole in
    // each loop.
    float2 k = float2(uv.x / 0.006, uv.y / 0.005);
    float2 c = fract(k + float2(fmod(floor(k.y), 2.0) * 0.5, 0.0)) - 0.5;
    float hole = 1.0 - smoothstep(0.22 - fw * 60.0, 0.3 + fw * 60.0, length(c * float2(1.0, 1.3)));
    float mean = 0.74 + 0.12 * (g.a - 0.5);
    float cover = mix(1.0 - hole * 0.9, mean, smoothstep(0.001, 0.004, fw));
    // Seen obliquely, along the road, the holes close up.
    cover = 1.0 - (1.0 - cover) * abs(dot(normalize(_surface.normal), normalize(_surface.view)));
    // Folds hanging down it, and the knit's sheen.
    float fold = smoothstep(0.3, 0.7, f.r);
    _surface.diffuse.rgb *= (0.9 + 0.2 * g.a) * mix(0.85, 1.1, fold);
    _surface.diffuse.a = saturate(cover);
    // Light through the knit: the tape is thin and the sun behind it lights
    // it from the back (the 2023 frame at 2150 m: clearly lighter than the
    // shade round it).
    _surface.emission.rgb = _surface.diffuse.rgb * 0.22;
    """

    /// The net's knitted tape has no sheen to speak of: without this the
    /// physically based Fresnel turned it into a pale veil of sky seen
    /// along the road.
    static let shadeNetFragment = """
    #pragma body
    _output.color.rgb = max(_output.color.rgb - _lightingContribution.specular * 0.9, float3(0.0));
    """
}
