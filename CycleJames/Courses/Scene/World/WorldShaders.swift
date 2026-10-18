import SceneKit

/// Metal shader modifiers for the world materials (see SCNShadable.h).
/// Per-vertex data travels in extra texture channels (vertex colours would
/// be multiplied into the diffuse) and reaches the fragment stage through
/// `#pragma varyings`.
enum WorldShaders {
    // MARK: Ground

    /// Grid and far terrain: world (x, z) arrives in texcoord 0.
    static let terrainGeometry = """
    #pragma varyings
    float2 wxz;
    float3 vdat;
    #pragma body
    out.wxz = _geometry.texcoords[0];
    out.vdat = float3(0.0);
    """

    /// Verge: texcoord 1 = (bank, verge grass), texcoord 2 = (mud, -).
    static let vergeGeometry = """
    #pragma varyings
    float2 wxz;
    float3 vdat;
    #pragma body
    out.wxz = _geometry.texcoords[0];
    out.vdat = float3(_geometry.texcoords[1], _geometry.texcoords[2].x);
    """

    /// Ortho photo (the diffuse, mapped by contentsTransform) blended with
    /// tiled detail by ground type, a far-field patchwork beyond the photo,
    /// bare earth on steep slopes and, on the verge, ivy, grass and mud.
    static let terrainSurface = """
    #pragma arguments
    texture2d<float> splatTex;
    texture2d<float> detailTex;
    texture2d<float> farTex;
    float detailNormals;
    #pragma body
    constexpr sampler rep(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));
    constexpr sampler clp(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float2 p = in.wxz;
    float2 ouv = _surface.diffuseTexcoord;
    float3 alb = _surface.diffuse.rgb;
    float edgeUV = min(min(ouv.x, 1.0 - ouv.x), min(ouv.y, 1.0 - ouv.y));
    float photo = smoothstep(0.0, 0.05, edgeUV);
    float3 farc = farTex.sample(rep, p * (1.0 / 2560.0)).rgb;
    alb = mix(farc, alb, photo);
    float4 sp = splatTex.sample(clp, ouv);
    if (sp.r + sp.g + sp.b + sp.a < 0.05) { sp = float4(1.0, 0.0, 0.0, 0.0); }
    float4 w = mix(float4(1.0, 0.0, 0.0, 0.0), sp, photo);
    float3 nV = normalize(_surface.normal);
    float3 nW = normalize((scn_frame.inverseViewTransform * float4(nV, 0.0)).xyz);
    float steep = 1.0 - smoothstep(0.55, 0.86, nW.y);
    w.b = max(w.b, steep);
    float bank = in.vdat.x;
    float vgrass = in.vdat.y;
    float mud = in.vdat.z;
    w.b = max(w.b, bank);
    w /= max(w.r + w.g + w.b + w.a, 0.001);
    // The verge strip is grass even where the field beside it is crops.
    w = mix(w, float4(1.0, 0.0, 0.0, 0.0), vgrass);
    float2 duv = p * 0.4;
    float4 d1 = detailTex.sample(rep, duv);
    float4 d2 = detailTex.sample(rep, p * 0.0885 + float2(0.31, 0.77));
    float h = dot(w, d1);
    float h2 = dot(w, d2);
    float dist = length(_surface.position);
    // Detail normals only close by: further out they only add a sheen.
    float nearF = 1.0 - smoothstep(6.0, 45.0, dist);
    alb *= (0.56 + 0.88 * h) * (0.84 + 0.32 * h2);
    float3 litter = mix(float3(0.045, 0.03, 0.016), float3(0.13, 0.085, 0.04), d1.b) * (0.8 + 0.4 * d2.b);
    alb = mix(alb, litter, saturate(w.b * 0.6 + steep * 0.2));
    float ivyN = smoothstep(0.30, 0.55, d2.r * 0.55 + detailTex.sample(rep, p * 0.023).g * 0.6);
    float3 ivy = float3(0.018, 0.042, 0.012) * (0.6 + 0.8 * d1.b);
    alb = mix(alb, mix(litter, ivy, ivyN), bank * 0.9);
    float3 vg = float3(0.065, 0.12, 0.028) * (0.6 + 0.8 * d1.r);
    alb = mix(alb, vg, vgrass * 0.45);
    alb = mix(alb, float3(0.042, 0.03, 0.018) * (0.8 + 0.4 * d1.b), mud * 0.8);
    if (detailNormals > 0.5 && nearF > 0.0) {
        float e = 1.0 / 1024.0;
        float hx = dot(w, detailTex.sample(rep, duv + float2(e, 0.0)));
        float hz = dot(w, detailTex.sample(rep, duv + float2(0.0, e)));
        float k = 2.5 * nearF;
        float3 nP = normalize(nW - float3((hx - h) * k, 0.0, (hz - h) * k));
        _surface.normal = normalize((scn_frame.viewTransform * float4(nP, 0.0)).xyz);
    }
    _surface.diffuse = float4(alb, 1.0);
    // Grass and crops are canopies, not surfaces: near-matte.
    float rough = dot(w, float4(0.97, 0.95, 0.9, 0.85));
    rough = mix(rough, 0.55, bank * ivyN);
    _surface.roughness = max(mix(rough, 0.45, mud), 0.4);
    """

    // MARK: Paved

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

    /// Tangent frame from screen-space derivatives (no tangents needed).
    static let cotangentNormal = """
    float3 N0 = normalize(_surface.normal);
    float3 dp1 = dfdx(_surface.position);
    float3 dp2 = dfdy(_surface.position);
    float2 duv1 = dfdx(uv);
    float2 duv2 = dfdy(uv);
    float3 dp2perp = cross(dp2, N0);
    float3 dp1perp = cross(N0, dp1);
    float3 Tn = dp2perp * duv1.x + dp1perp * duv2.x;
    float3 Bn = dp2perp * duv1.y + dp1perp * duv2.y;
    float invmax = rsqrt(max(max(dot(Tn, Tn), dot(Bn, Bn)), 1e-20));
    float3 nMapped = normalize(Tn * invmax * nts.x + Bn * invmax * nts.y + N0 * nts.z);
    """

    /// Cobbles and asphalt: albedo is the diffuse texture; the detail
    /// texture packs normal xy, roughness and height. Mud fills the joints
    /// first, then creeps over the stones towards the edges.
    static let pavedSurface = """
    #pragma arguments
    texture2d<float> detailTex;
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
    _surface.diffuse = float4(alb, 1.0);
    _surface.roughness = mix(d.b - 0.1 * mud, 0.38, fill);
    _surface.normal = normalize(mix(nMapped, N0, fill * 0.7));
    """

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
    _surface.diffuse = float4(alb, 1.0);
    _surface.roughness = mix(saturate(d.b + 0.12), 0.95, joint);
    _surface.normal = normalize(mix(nMapped, N0, 0.3));
    """

    /// Any material with a packed detail texture (normal xy, roughness,
    /// height) over its diffuse texture coordinates.
    static let detailSurface = """
    #pragma arguments
    texture2d<float> detailTex;
    float normalStrength;
    #pragma body
    constexpr sampler rep(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));
    float2 uv = _surface.diffuseTexcoord;
    float4 d = detailTex.sample(rep, uv);
    float2 nxy = (d.rg * 2.0 - 1.0) * normalStrength;
    float3 nts = float3(nxy, sqrt(saturate(1.0 - dot(nxy, nxy))));
    \(cotangentNormal)
    _surface.normal = nMapped;
    _surface.roughness = d.b;
    _surface.ambientOcclusion *= 0.55 + 0.45 * d.a;
    """

    // MARK: Plants

    /// Wind: texcoord 1 = (sway weight, phase); texcoord 2 = (ao, tint) and
    /// the model-space normal are passed on to the fragment stage.
    static let windGeometry = """
    #pragma arguments
    float windStrength;
    float flutter;
    #pragma varyings
    float2 fdat;
    float3 nrmM;
    #pragma body
    out.nrmM = _geometry.normal;
    float2 bo = _geometry.texcoords[3];
    if (bo.x != 0.0 || bo.y != 0.0) {
        float3 camR = normalize(scn_frame.inverseViewTransform[0].xyz);
        float3 camU = normalize(scn_frame.inverseViewTransform[1].xyz);
        _geometry.position.xyz += camR * bo.x + camU * bo.y;
        // In the (orthographic) shadow pass the card faces the sun, not
        // the camera, so it would shade half of its own camera-facing
        // twin; set the caster back from the sun by the card's half size.
        if (scn_frame.projectionTransform[3][3] > 0.5) {
            _geometry.position.xyz -= normalize(scn_frame.inverseViewTransform[2].xyz) * length(bo);
        }
    }
    float2 sw = _geometry.texcoords[1];
    out.fdat = _geometry.texcoords[2];
    float t = scn_frame.time;
    float3 wp = _geometry.position.xyz;
    float gust = 0.55 + 0.45 * sin(t * 0.37 + sw.y * 0.5) * sin(t * 0.23 + 1.3);
    float3 off = float3(sin(t * 1.25 + sw.y), 0.0, cos(t * 1.05 + sw.y * 1.7)) * 0.06 * gust;
    off += float3(sin(t * 5.3 + wp.x * 2.1 + wp.y * 1.7), 0.35 * sin(t * 4.1 + wp.z * 1.9),
                  cos(t * 6.1 + wp.z * 2.3 + wp.y * 1.3)) * 0.02 * flutter;
    _geometry.position.xyz += off * sw.x * windStrength;
    """

    /// Metres over which verge grass grows from flat to full height inside
    /// `grassFadeEnd` (see `FrameUpdater`).
    static let grassFadeLength: Double = 10

    /// Verge grass: `windGeometry` without the billboard corners, and tufts
    /// shrinking to the ground over the last `grassFadeLength` metres before
    /// `grassFadeEnd` (camera distance), so streamed cells appear flat. A
    /// tuft's top vertices carry 1.2 x its height as their sway weight.
    static let grassGeometry = """
    #pragma arguments
    float windStrength;
    float flutter;
    float grassFadeEnd;
    #pragma varyings
    float2 fdat;
    float3 nrmM;
    #pragma body
    out.nrmM = _geometry.normal;
    float2 sw = _geometry.texcoords[1];
    out.fdat = _geometry.texcoords[2];
    float3 wpos = (scn_node.modelTransform * float4(_geometry.position.xyz, 1.0)).xyz;
    float d = distance(wpos, scn_frame.inverseViewTransform[3].xyz);
    float grow = 1.0 - smoothstep(grassFadeEnd - \(grassFadeLength), grassFadeEnd, d);
    _geometry.position.y -= (1.0 - grow) * sw.x / 1.2;
    float t = scn_frame.time;
    float3 wp = _geometry.position.xyz;
    float gust = 0.55 + 0.45 * sin(t * 0.37 + sw.y * 0.5) * sin(t * 0.23 + 1.3);
    float3 off = float3(sin(t * 1.25 + sw.y), 0.0, cos(t * 1.05 + sw.y * 1.7)) * 0.06 * gust;
    off += float3(sin(t * 5.3 + wp.x * 2.1 + wp.y * 1.7), 0.35 * sin(t * 4.1 + wp.z * 1.9),
                  cos(t * 6.1 + wp.z * 2.3 + wp.y * 1.3)) * 0.02 * flutter;
    _geometry.position.xyz += off * sw.x * windStrength * grow;
    """

    /// Alpha-tested leaf cards with per-vertex shading (ao, tint) and light
    /// through the leaves when the sun is behind them.
    static let foliageSurface = """
    #pragma arguments
    float3 toSun;
    float translucency;
    float alphaCut;
    #pragma body
    // Lower mip levels average leaf coverage into the gaps, which would
    // turn distant cards into solid squares; raise the cut-off with the
    // level being sampled to keep crowns ragged.
    float2 tc = _surface.diffuseTexcoord * 1024.0;
    float2 tdx = dfdx(tc), tdy = dfdy(tc);
    float lod = 0.5 * log2(max(max(dot(tdx, tdx), dot(tdy, tdy)), 1e-8));
    float cut = alphaCut + clamp(lod - 1.0, 0.0, 6.0) * 0.045;
    if (_surface.diffuse.a < cut) { discard_fragment(); }
    // Cards are double-sided, and SceneKit flips the normal on the back
    // face, which would point a leaf's or a grass blade's shading into the
    // ground; keep the designed (crown-bent, mostly upward) normal on both
    // sides and let translucency handle light from behind.
    _surface.normal = normalize((scn_node.normalTransform * float4(in.nrmM, 0.0)).xyz);
    float ao = in.fdat.x;
    float tint = in.fdat.y;
    float3 c = _surface.diffuse.rgb;
    c *= mix(float3(1.0), float3(1.16, 1.06, 0.72), tint);
    c *= ao;
    _surface.diffuse = float4(c, 1.0);
    float3 sunV = normalize((scn_frame.viewTransform * float4(toSun, 0.0)).xyz);
    float back = pow(saturate(dot(-normalize(_surface.view), sunV)), 4.0);
    _surface.emission = float4(c * (back * translucency * ao), 1.0);
    """

    /// Distant trees: one quad per tree turned about the vertical towards
    /// the viewer.
    static let impostorGeometry = """
    #pragma varyings
    float2 fdat;
    float3 nrmM;
    #pragma body
    out.fdat = _geometry.texcoords[2];
    out.nrmM = _geometry.normal;
    float2 bo = _geometry.texcoords[3];
    float3 camR = scn_frame.inverseViewTransform[0].xyz;
    camR.y = 0.0;
    camR = normalize(camR + float3(1e-5, 0.0, 0.0));
    _geometry.position.xyz += camR * bo.x + float3(0.0, bo.y, 0.0);
    if (scn_frame.projectionTransform[3][3] > 0.5) {
        float3 back = scn_frame.inverseViewTransform[2].xyz;
        back.y = 0.0;
        _geometry.position.xyz -= normalize(back + float3(1e-5, 0.0, 0.0)) * abs(bo.x);
    }
    """

    /// Small streams: texcoord 1 = (open sky, -), from 1 in the open to 0
    /// under bushes and trees. Under cover the water can't mirror the sky,
    /// so it turns rough and dark rather than a bright sheet.
    static let streamGeometry = """
    #pragma varyings
    float sky;
    #pragma body
    out.sky = _geometry.texcoords[1].x;
    """

    static let streamSurface = """
    #pragma body
    float sky = saturate(in.sky);
    _surface.roughness = mix(0.85, 0.38, sky);
    _surface.ambientOcclusion *= mix(0.25, 1.0, sky);
    """

    static let streamFragment = """
    #pragma body
    _output.color.rgb *= mix(0.3, 1.0, saturate(in.sky));
    """

    static let opaqueFragment = """
    #pragma opaque
    _output.color.a = 1.0;
    """

    /// Bark sways with the crown; detail normals from its packed texture.
    static let barkSurface = """
    #pragma arguments
    texture2d<float> detailTex;
    float normalStrength;
    #pragma body
    constexpr sampler rep(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));
    float2 uv = _surface.diffuseTexcoord;
    float4 d = detailTex.sample(rep, uv);
    float2 nxy = (d.rg * 2.0 - 1.0) * normalStrength;
    float3 nts = float3(nxy, sqrt(saturate(1.0 - dot(nxy, nxy))));
    \(cotangentNormal)
    _surface.normal = nMapped;
    _surface.diffuse.rgb *= in.fdat.x;
    _surface.roughness = d.b;
    """
}
