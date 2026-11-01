import SceneKit

/// Paved surfaces: the road, the side roads draped over the ground,
/// asphalt, kerbs, concrete lanes and gutters, and cycle lanes, all lit
/// through the course's light raster (`WorldShaders+Light`). The setts are
/// in `WorldShaders+Setts`.
extension WorldShaders {
    /// Road: texcoord 1 = (0 centre .. 1 edge, mud weight).
    static let pavedGeometry = """
    #pragma varyings
    float2 rdat;
    #pragma body
    out.rdat = _geometry.texcoords[1];
    """

    /// Draped side roads: as `pavedGeometry`, pulled a few centimetres
    /// towards the camera so they always win over the ground under them.
    static let drapedGeometry = """
    #pragma varyings
    float2 rdat;
    #pragma body
    out.rdat = _geometry.texcoords[1];
    float3 cam = scn_frame.inverseViewTransform[3].xyz;
    float3 toCam = cam - _geometry.position.xyz;
    float dist = length(toCam);
    _geometry.position.xyz += toCam / max(dist, 0.001) * min(0.05 + dist * 0.002, 0.4);
    """

    /// Asphalt: albedo is the diffuse texture; the detail texture packs
    /// normal xy, roughness and height. Mud fills the joints first, then
    /// creeps over the stones towards the edges.
    static let pavedSurface = """
    #pragma arguments
    texture2d<float> detailTex;
    \(lightArgs)
    float mudAmount;
    float normalStrength;
    #pragma body
    constexpr sampler rep(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(16));
    float2 uv = _surface.diffuseTexcoord;
    float4 d = detailTex.sample(rep, uv);
    float2 nxy = (d.rg * 2.0 - 1.0) * normalStrength;
    float3 nts = float3(nxy, sqrt(saturate(1.0 - dot(nxy, nxy))));
    \(cotangentNormal)
    float edge = in.rdat.x;
    float mud = in.rdat.y * mudAmount;
    float big = detailTex.sample(rep, uv * 0.113 + float2(0.37, 0.11)).a;
    float big2 = detailTex.sample(rep, uv * 0.031 + float2(0.71, 0.29)).a;
    float patchy = saturate((big - 0.5) * 1.6 + (big2 - 0.5) * 1.2 + 0.5);
    float m = mud * (smoothstep(0.62, 1.0, edge) * 0.85 + 0.1) * (0.55 + 0.9 * patchy);
    // Joints fill first; whole stones only where it is thick.
    float fill = smoothstep(0.15, 0.6, m - d.a * 0.55);
    float joint = (1.0 - smoothstep(0.15, 0.5, d.a)) * saturate(mud * 1.5);
    float3 alb = _surface.diffuse.rgb;
    // Large, untiled brightness variation hides the texture repeat.
    alb *= 0.9 + 0.2 * big2;
    alb *= mix(1.0, 0.82, smoothstep(0.8, 1.0, edge));
    alb *= 1.0 - 0.35 * joint;
    float3 mudCol = float3(0.062, 0.048, 0.03) * (0.85 + 0.3 * big);
    alb = mix(alb, mudCol, fill * 0.9);
    // Sky occlusion and the sun's shade beyond the shadow map.
    float3 lgtP = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
    float3 lgtN = normalize((scn_frame.inverseViewTransform * float4(N0, 0.0)).xyz);
    float lgtD = -_surface.position.z;
    \(lightFetch)
    \(lightApply)
    _surface.diffuse = float4(alb, 1.0);
    _surface.roughness = mix(d.b - 0.1 * mud, 0.38, fill);
    _surface.normal = normalize(mix(nMapped, N0, fill * 0.7));
    """

    /// Riviera road and its paint: texcoord 0 = (lateral, route distance)
    /// in metres, passed on unscaled as `ruv`; texcoord 1 as `rdat`
    /// ((0 centre .. 1 edge, mud) on the asphalt, (paint kind + edge,
    /// wear) on the paint).
    static let rivieraGeometry = """
    #pragma varyings
    float2 ruv;
    float2 rdat;
    #pragma body
    out.ruv = _geometry.texcoords[0];
    out.rdat = _geometry.texcoords[1];
    """

    /// `rivieraGeometry` pulled towards the camera, as `drapedGeometry`.
    static let rivieraDrapedGeometry = rivieraGeometry + "\n" + """
    float3 cam = scn_frame.inverseViewTransform[3].xyz;
    float3 toCam = cam - _geometry.position.xyz;
    float dist = length(toCam);
    _geometry.position.xyz += toCam / max(dist, 0.001) * min(0.05 + dist * 0.002, 0.4);
    """

    /// Hashes and a smooth 1D noise for the Riviera road (names `cjr`, so
    /// they can't collide with the setts' `cjs`).
    static let rivieraDeclarations = """
    #pragma declaration
    static inline float cjrHash(float n) {
        return fract(sin(n * 12.9898 + 78.233) * 43758.5453);
    }
    static inline float cjrNoise(float x) {
        float i = floor(x);
        float f = x - i;
        float u = f * f * (3.0 - 2.0 * f);
        return mix(cjrHash(i), cjrHash(i + 1.0), u);
    }
    // Antialiased 1 inside [a, b], 0 outside, over a footprint `w`.
    static inline float cjrBox(float x, float a, float b, float w) {
        return smoothstep(a - w, a + w, x) * (1.0 - smoothstep(b - w, b + w, x));
    }
    """

    /// The SP55's asphalt (look.md section 3), shared by the road and its
    /// paint so worn paint shows the same tarmac. Needs `uv` (texture
    /// units), `lat` and `rs` (lateral and route distance, metres) and
    /// `edge` (0 centre .. 1 edge); leaves `d` (the detail texel), `big`,
    /// `alb` (linear), `rough` and `nts` (tangent normal).
    ///
    /// Smooth fine-grained tarmac laid at different times, bleached by the
    /// sun to a pale, neutral silver-grey: in the 2024 frames the sunlit
    /// road is about as bright as the sandstone walls beside it, and the
    /// summit photo measures #9fa09d-#b4b5b0 (look.md section 3, sunlit
    /// #a4a6a1). The limestone-chip texture is a little warm and the 5100 K
    /// sun warmer: a cool tint brings the sunlit road to neutral. Long
    /// stretches of the base, older and paler, or fresh and darker; patch
    /// repairs over one lane, a trench strip, the full width or a small
    /// square, sealed at their edges (none before `asphaltK.y`); oil and
    /// tyre darkening down the middle of each lane; sunken cast-iron
    /// inspection covers in their collars here and there.
    ///
    /// The chips' contrast is compressed about the tile's mean luminance
    /// (`asphaltK.x`, linear, the material's intensity included): at 5.9
    /// times the texture's brightest chips reach 0.87 linear against a mean
    /// of 0.34, and read up close as a white salt-and-pepper speckle that
    /// glowed in the shade (3950 chase, #4d5a6b with white flecks). The 2024
    /// POV and the 2026 summit photo show an even, fine silver-grey. Kept
    /// at 0.38 of the texture's: about the grain the road had at 2.55 times.
    /// Linear about the mean, so the mean, and the distant road the mipmaps
    /// average to it, keep their tone. No compression where it is unset (0).
    static let rivieraAsphaltCore = """
    constexpr sampler rep(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(16));
    float4 d = detailTex.sample(rep, uv);
    float big = detailTex.sample(rep, uv * 0.113 + float2(0.37, 0.11)).a;
    float big2 = detailTex.sample(rep, uv * 0.031 + float2(0.71, 0.29)).a;
    float2 nxy = (d.rg * 2.0 - 1.0) * normalStrength;
    float3 alb = _surface.diffuse.rgb;
    float grainL = dot(alb, float3(0.2126, 0.7152, 0.0722));
    float grainM = asphaltK.x > 0.0 ? asphaltK.x : grainL;
    alb *= (grainM + (grainL - grainM) * 0.38) / max(grainL, 1e-4);
    alb *= (0.93 + 0.14 * big2) * float3(0.92, 1.0, 1.09);
    // The chips are a little smoother than the binder: by half as much.
    float rough = mix(0.84, d.b, 0.5);
    float aw = max(fwidth(rs), 0.004);
    float lw = max(fwidth(lat), 0.004);
    // Stretches laid in different years.
    float lay = cjrNoise(rs / 170.0 + 2.3) * 0.65 + cjrNoise(rs / 53.0 + 9.1) * 0.35;
    float warm = smoothstep(0.6, 0.72, lay);
    float fresh = 1.0 - smoothstep(0.27, 0.37, lay);
    alb *= mix(float3(1.0), float3(1.1, 1.08, 1.04), warm);
    alb *= mix(1.0, 0.7, fresh);
    rough = mix(rough, rough * 0.92, fresh);
    // Patch repairs, in about one 23 m cell in four.
    float pc = floor(rs / 23.0);
    float h0 = cjrHash(pc * 7.31 + 1.7), h1 = cjrHash(pc * 3.17 + 5.3);
    float h2 = cjrHash(pc * 11.9 + 2.1), h3 = cjrHash(pc * 5.77 + 8.9);
    float ps0 = pc * 23.0 + 1.0 + h1 * 8.0;
    float ps1 = ps0 + 2.5 + h2 * 11.0;
    float pl0 = -20.0, pl1 = 20.0;
    if (h3 < 0.35) { pl0 = h2 < 0.5 ? -20.0 : -0.05; pl1 = h2 < 0.5 ? 0.05 : 20.0; }
    else if (h3 < 0.6) { float c = (h2 - 0.5) * 3.0; pl0 = c - 0.35; pl1 = c + 0.35; }
    else if (h3 >= 0.8) { float c = (h1 - 0.5) * 2.6; pl0 = c - 0.6 - 0.4 * h2; pl1 = c + 0.6 + 0.4 * h2; ps1 = ps0 + 1.2 + h3; }
    float inPatch = h0 < 0.27 && ps0 > asphaltK.y ? cjrBox(rs, ps0, ps1, aw) * cjrBox(lat, pl0, pl1, lw) : 0.0;
    // Fresh repairs darker (look.md: #4a4a4c on the #62625f base, 0.56
    // linear), but the base is now the sun-bleached road, and at 0.6 a
    // lane-wide repair read as a black block (route 310-330): 0.74.
    float3 patchTint = h1 > 0.45 ? float3(0.74) : float3(1.1, 1.09, 1.07);
    alb *= mix(float3(1.0), patchTint, inPatch);
    // The sealed seam round a patch: a dark band 4 cm wide.
    float seam = inPatch * (1.0 - inPatch) * 4.0;
    alb *= 1.0 - 0.45 * seam * smoothstep(0.08, 0.02, max(aw, lw));
    // Oil and tyre darkening down each lane, patchy.
    float eo = (edge - 0.5) / 0.11, et0 = (edge - 0.24) / 0.07, et1 = (edge - 0.78) / 0.07;
    float oil = exp(-eo * eo) * (0.55 + 0.9 * big);
    float tyres = exp(-et0 * et0) + exp(-et1 * et1);
    alb *= (1.0 - 0.2 * saturate(oil)) * (1.0 - 0.07 * tyres * (0.5 + big));
    rough -= 0.07 * tyres;
    // Inspection covers: one in about half the 61 m cells.
    float cc = floor(rs / 61.0);
    float k0 = cjrHash(cc * 4.13 + 0.7), k1 = cjrHash(cc * 9.71 + 3.3), k2 = cjrHash(cc * 2.39 + 6.1);
    if (k0 < 0.55) {
        float2 q = float2(lat - (k1 - 0.5) * 2.8, rs - (cc * 61.0 + 6.0 + k2 * 48.0));
        bool disc = k1 > 0.3;
        float r = disc ? 0.33 : 0.31;
        float dd = disc ? length(q) : max(abs(q.x), abs(q.y));
        float fw = max(aw, lw);
        float lid = 1.0 - smoothstep(r - fw, r + fw, dd);
        float gap = cjrBox(dd, r, r + 0.018, fw);
        float collar = cjrBox(dd, r + 0.018, r + 0.15, fw);
        // Weathered cast iron, dull grey-brown (black read as a hole in the
        // chase view), with concentric (or crossed) ribs, fading out where the
        // ribs would alias.
        float rib = disc ? fract(dd * 16.0) : fract((q.x + q.y) * 11.3);
        float ribs = mix(step(0.5, rib), 0.5, smoothstep(0.01, 0.03, fw));
        alb = mix(alb, float3(0.062, 0.057, 0.051) * (0.8 + 0.4 * ribs), lid);
        alb *= 1.0 - 0.75 * gap;
        alb *= mix(1.0, 0.8, collar);
        rough = mix(rough, 0.55, lid);
        // Sunk 1-2 cm: the collar slopes down towards the lid.
        nxy += collar * 0.35 * normalize(q + float2(1e-5));
    }
    float3 nts = float3(nxy, sqrt(saturate(1.0 - dot(nxy, nxy))));
    """

    /// The Riviera asphalt (`rivieraAsphaltCore`), lit through the light
    /// raster as `pavedSurface`.
    static let rivieraAsphaltSurface = """
    #pragma arguments
    texture2d<float> detailTex;
    \(lightArgs)
    float normalStrength;
    float4 asphaltK;
    \(rivieraDeclarations)
    #pragma body
    float2 uv = _surface.diffuseTexcoord;
    float lat = in.ruv.x;
    float rs = in.ruv.y;
    float edge = in.rdat.x;
    \(rivieraAsphaltCore)
    \(cotangentNormal)
    float3 lgtP = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
    float3 lgtN = normalize((scn_frame.inverseViewTransform * float4(N0, 0.0)).xyz);
    float lgtD = -_surface.position.z;
    \(lightFetch)
    \(lightApply)
    _surface.diffuse = float4(alb, 1.0);
    _surface.roughness = saturate(rough);
    _surface.normal = nMapped;
    """

    /// The Poggio's lanes and driveways (`RoadBuilder.appendRivieraSideRoad`):
    /// `rivieraAsphaltSurface` frayed into the dry verge over the outer
    /// half metre of a lane's own edges (texcoord 1 = (edge, half width in
    /// metres); edge 0 where it meets the carriageway), ragged: dust and
    /// grit, the straw-and-earth of the verges (look.md section 3, #a39c7f
    /// straw), duller and flatter. A lane's tarmac ended in a hard grey line
    /// on the grass (1900 right). Not on a road over about 6 m wide (the
    /// SS1), which ends at a kerb or a wall.
    static let rivieraSideAsphaltSurface: String = {
        let tail = "float3 nts = float3(nxy, sqrt(saturate(1.0 - dot(nxy, nxy))));"
        assert(rivieraAsphaltSurface.components(separatedBy: tail).count == 2, "rivieraAsphaltCore's tail moved")
        return rivieraAsphaltSurface.replacingOccurrences(of: tail, with: tail + """

        float rag = detailTex.sample(rep, uv * 0.41 + float2(0.13, 0.61)).a;
        float hwM = max(in.rdat.y, 0.5);
        float fray = 0.55 * (1.0 - smoothstep(2.6, 3.2, hwM));
        float fromEdge = (1.0 - edge) * hwM + 0.25 * (rag - 0.5) + 0.12 * (big - 0.5);
        float dust = fray > 0.01 ? 1.0 - smoothstep(0.0, fray, fromEdge) : 0.0;
        alb = mix(alb, float3(0.33, 0.29, 0.2) * (0.8 + 0.4 * big2), dust * 0.85);
        rough = mix(rough, 0.95, dust);
        nts = normalize(mix(nts, float3(0.0, 0.0, 1.0), dust * 0.5));
        """)
    }()

    /// Paint on the Riviera road: lines, zebra stripes, give-way teeth, the
    /// bus stop's yellow and the fans' writing. Texcoord 1 = (kind + edge,
    /// wear): kind 0 white, 1 yellow, 2 red, 3 blue, 4 green; edge as the
    /// asphalt's (0 centre .. 1 edge, under 1); wear 0 fresh .. 1 gone.
    /// Paint wears through first on the aggregate's tops and in metre-scale
    /// patches, showing the very asphalt under it (`rivieraAsphaltCore`).
    static let rivieraPaintSurface = """
    #pragma arguments
    texture2d<float> detailTex;
    \(lightArgs)
    float normalStrength;
    float4 asphaltK;
    \(rivieraDeclarations)
    #pragma body
    float2 uv = _surface.diffuseTexcoord;
    float lat = in.ruv.x;
    float rs = in.ruv.y;
    float kind = floor(in.rdat.x + 0.001);
    float edge = saturate(in.rdat.x - kind);
    float wear = in.rdat.y;
    \(rivieraAsphaltCore)
    float3 paint = float3(0.76, 0.755, 0.735);
    if (kind > 0.5 && kind < 1.5) { paint = float3(0.86, 0.52, 0.035); }
    else if (kind > 1.5 && kind < 2.5) { paint = float3(0.55, 0.035, 0.03); }
    else if (kind > 2.5 && kind < 3.5) { paint = float3(0.035, 0.11, 0.42); }
    else if (kind > 3.5) { paint = float3(0.04, 0.27, 0.07); }
    float patchW = detailTex.sample(rep, uv * 0.41 + float2(0.13, 0.61)).a;
    // The grain's share of the wear fades to its mean where a pixel spans
    // many grains, so far lines don't shimmer.
    float fine = 1.0 - smoothstep(0.004, 0.02, max(aw, lw));
    float x = wear + 0.5 * (patchW - 0.5) + 0.25 * (big - 0.5) + 0.35 * (d.a - 0.5) * fine;
    float cov = 1.0 - smoothstep(0.42, 0.58, x);
    // Grime from the tyres on fresh paint too.
    paint *= 0.88 + 0.12 * big2 - 0.08 * saturate(oil);
    alb = mix(alb, paint, cov);
    rough = mix(rough, 0.48, cov);
    nts = normalize(mix(nts, float3(0.0, 0.0, 1.0), cov * 0.6));
    \(cotangentNormal)
    float3 lgtP = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
    float3 lgtN = normalize((scn_frame.inverseViewTransform * float4(N0, 0.0)).xyz);
    float lgtD = -_surface.position.z;
    \(lightFetch)
    \(lightApply)
    _surface.diffuse = float4(alb, 1.0);
    _surface.roughness = saturate(rough);
    _surface.normal = nMapped;
    """

    /// `concreteSurface` in the Riviera's warmer concrete: sand from the
    /// local sandstone and ochre dust in it, an albedo about #9c948a against
    /// the Flemish near-neutral grey (look.md section 3, kerbs and gutters).
    static let rivieraConcreteSurface: String = {
        let flemish = "float3(1.0, 0.985, 0.95) * 2.8"
        assert(concreteSurface.contains(flemish), "concreteSurface's tint moved")
        return concreteSurface.replacingOccurrences(of: flemish, with: "float3(1.05, 0.95, 0.8) * 2.8")
    }()

    /// `pavedSurface` with its albedo multiplied by `tint3` (linear, may
    /// exceed 1): red cycle-lane surfacing from the asphalt textures.
    static let tintedPavedSurface = pavedSurface
        .replacingOccurrences(of: "float normalStrength;\n#pragma body", with: "float normalStrength;\nfloat3 tint3;\n#pragma body")
        .replacingOccurrences(of: "_surface.diffuse = float4(alb, 1.0);", with: "alb *= tint3;\n_surface.diffuse = float4(alb, 1.0);")

    /// Concrete: `pavedSurface` with joints across the road every `slabV`
    /// texture units (texture v runs along the road), `jointV` wide.
    static let concreteSurface = """
    #pragma arguments
    texture2d<float> detailTex;
    \(lightArgs)
    float mudAmount;
    float normalStrength;
    float slabV;
    float jointV;
    #pragma body
    constexpr sampler rep(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(16));
    float2 uv = _surface.diffuseTexcoord;
    float4 d = detailTex.sample(rep, uv);
    float2 nxy = (d.rg * 2.0 - 1.0) * normalStrength;
    float3 nts = float3(nxy, sqrt(saturate(1.0 - dot(nxy, nxy))));
    \(cotangentNormal)
    float edge = in.rdat.x;
    float mud = in.rdat.y * mudAmount;
    float big = detailTex.sample(rep, uv * 0.113 + float2(0.37, 0.11)).a;
    float big2 = detailTex.sample(rep, uv * 0.031 + float2(0.71, 0.29)).a;
    float3 alb = _surface.diffuse.rgb;
    // Concrete is much paler and less blue than the asphalt it is made
    // from: about 0.3 linear (0.58 sRGB) where the asphalt is 0.1.
    float lum = dot(alb, float3(0.299, 0.587, 0.114));
    alb = mix(float3(lum), alb, 0.35) * float3(1.0, 0.985, 0.95) * 2.8;
    alb *= 0.86 + 0.28 * big2;
    // Weathering: darker towards the edges, where dirt and moss collect.
    alb *= mix(1.0, 0.78, smoothstep(0.7, 1.0, edge) * (0.6 + 0.8 * big));
    // Joints: the pixel footprint's coverage of the joint band (box
    // filter), fading to the band's mean share before the footprint
    // reaches the next joint, so distant slabs keep their brightness.
    float t = abs(fract(uv.y / slabV + 0.5) - 0.5) * slabV;
    float w = max(fwidth(uv.y), 1e-5);
    float hw = 0.5 * w;
    float cov = saturate((min(t + hw, jointV) - max(t - hw, -jointV)) / w);
    float joint = mix(cov, 2.0 * jointV / slabV, smoothstep(0.25 * slabV, 0.5 * slabV, w));
    alb *= 1.0 - 0.55 * joint;
    alb = mix(alb, float3(0.062, 0.048, 0.03), saturate(mud * (0.4 + 0.6 * big)) * 0.6);
    float3 lgtP = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
    float3 lgtN = normalize((scn_frame.inverseViewTransform * float4(N0, 0.0)).xyz);
    float lgtD = -_surface.position.z;
    \(lightFetch)
    \(lightApply)
    _surface.diffuse = float4(alb, 1.0);
    _surface.roughness = mix(saturate(d.b + 0.12), 0.95, joint);
    _surface.normal = normalize(mix(nMapped, N0, 0.3));
    """
}
