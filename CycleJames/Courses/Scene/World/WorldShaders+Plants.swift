import SceneKit

/// Plants: wind, verge grass, leaf cards, distant tree impostors and
/// bark.
extension WorldShaders {
    /// A plant's per-vertex shading, texcoord 2, decoded once per vertex
    /// (the four corners of a card carry the same values) into the ambient
    /// occlusion `fao` and the colour multiplier `ftint`. x: ao, 0 to 1.
    /// y: yellowing below 65536, or a packed RGB multiplier r << 16 |
    /// g << 8 | b, 128 = x1 (`TreeArchetype.packColour`).
    static let shadeDecode = """
    float2 sh = _geometry.texcoords[2];
    out.fao = sh.x;
    if (sh.y < 65536.0) {
        out.ftint = mix(float3(1.0), float3(1.16, 1.06, 0.72), sh.y);
    } else {
        uint u = uint(sh.y);
        out.ftint = float3(float((u >> 16) & 255u), float((u >> 8) & 255u), float(u & 255u)) * (1.0 / 128.0);
    }
    """

    /// Wind: texcoord 1 = (sway weight, phase); texcoord 2 (`shadeDecode`)
    /// and the model-space normal are passed on to the fragment stage.
    static let windGeometry = """
    #pragma arguments
    float windStrength;
    float flutter;
    #pragma varyings
    float fao;
    float3 ftint;
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
        // twin; set the caster back from the sun by 1.6 times its corner's
        // offset. (At 1, a camera-facing card cut through the casters of
        // its neighbours in the crown, and the cut drew a straight-edged
        // sunlit patch across it; deeper, the cut falls on the crown's far
        // side, which faces away from the sun.)
        if (scn_frame.projectionTransform[3][3] > 0.5) {
            _geometry.position.xyz -= normalize(scn_frame.inverseViewTransform[2].xyz) * (1.6 * length(bo));
        }
    }
    float2 sw = _geometry.texcoords[1];
    \(shadeDecode)
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
    float fao;
    float3 ftint;
    float3 nrmM;
    #pragma body
    out.nrmM = _geometry.normal;
    float2 sw = _geometry.texcoords[1];
    \(shadeDecode)
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

    /// Alpha-tested leaf cards, shaded as a mass of leaves rather than a
    /// mirror, with per-vertex shading (`shadeDecode`) and light through
    /// the leaves from behind.
    ///
    /// Arguments: `atlasPx` is the bound atlas's width in pixels;
    /// `anisotropy` is how many samples along a footprint the alpha cut
    /// takes the diffuse's anisotropic filter to spread (1: the cut follows
    /// the footprint's long axis); `throughCrown` 1 limits the light
    /// through to the side of a crown facing away from the sun (cards with
    /// crown-bent normals), 0 lets every card take it (grass blades, whose
    /// normals point up); `exposureGain` scales that light with the
    /// exposure, as the lights are scaled (1 = none). Per-leaf normals wait
    /// for a leaf atlas with a normal map (leaf atlas v2). `mipCoverage`
    /// (0: unset) keeps the cut where it is and scales the alpha up by that
    /// much per mip level instead (`mipCoverageMed`).
    static let foliageSurface = """
    #pragma arguments
    float3 toSun;
    float translucency;
    float alphaCut;
    float atlasPx;
    float anisotropy;
    float throughCrown;
    float exposureGain;
    float mipCoverage;
    #pragma body
    // Lower mip levels average leaf coverage into the gaps, which would
    // turn distant cards into solid squares; raise the cut-off with the
    // level being sampled to keep crowns ragged. With anisotropic
    // filtering that level follows the footprint's long axis over up to
    // `anisotropy` samples, or its short axis.
    float2 tc = _surface.diffuseTexcoord * atlasPx;
    float2 tdx = dfdx(tc), tdy = dfdy(tc);
    float fx = dot(tdx, tdx), fy = dot(tdy, tdy);
    float lod = 0.5 * log2(max(max(max(fx, fy) / (anisotropy * anisotropy), min(fx, fy)), 1e-8));
    float rise = mipCoverage > 0.0 ? 0.0 : 0.045;
    float cut = alphaCut + clamp(lod - 1.0, 0.0, 6.0) * rise;
    if (_surface.diffuse.a * (1.0 + max(lod, 0.0) * mipCoverage) < cut) { discard_fragment(); }
    float3 V = normalize(_surface.view);
    // Cards are double-sided, and SceneKit flips the normal on the back
    // face, which would point a leaf's or a grass blade's shading into the
    // ground; keep the designed (crown-bent, mostly upward) normal on both
    // sides and let translucency handle light from behind.
    float3 Nc = normalize((scn_node.normalTransform * float4(in.nrmM, 0.0)).xyz);
    float3 L = normalize((scn_frame.viewTransform * float4(toSun, 0.0)).xyz);
    float back = saturate(dot(-V, L));
    // Never a grazing mirror: a card turned from the viewer is lit through,
    // not seen at the specular peak. Looking towards the sun, up-bent cards
    // would still glare grey-white (Fresnel at grazing, even at roughness
    // 1), so the normal turns further towards the viewer, and so away from
    // the sun, the nearer the view is to the sun.
    _surface.normal = normalize(Nc + V * max(0.0, 0.35 + 0.45 * back * back - dot(Nc, V)));
    float ao = in.fao;
    // Ao dims the sky light and its reflection, and the leaf by up to
    // half: the leaves inside a crown see little of the sun either, which
    // the shadow map is too coarse to show.
    _surface.ambientOcclusion = ao;
    float3 c = _surface.diffuse.rgb * in.ftint;
    c *= mix(1.0, ao, 0.5);
    _surface.diffuse = float4(c, 1.0);
    float through = mix(1.0, saturate(0.3 - dot(Nc, L) * 0.7), throughCrown);
    // Light through leaves is yellower than light off them.
    float3 tcol = c * float3(1.3, 1.45, 0.55);
    float k = translucency * through * (0.15 + 0.85 * back * back) * exposureGain;
    _surface.emission = float4(tcol * k, 1.0);
    """

    /// Leaf cards and impostors: opaque (as `opaqueFragment`), keeping a
    /// tenth of the specular. A card stands for many leaves, and in a crown
    /// most of the sky a leaf would mirror is hidden by the leaves round
    /// it, which the ambient occlusion doesn't take off the sky's
    /// reflection: on dark leaves in shade that grey sheen outshone their
    /// green, so crowns had pale grey-blue patches and near shrubs read as
    /// a milky veil, cut by a straight line where a shadow crossed the
    /// card (at 30 % kept, still a grey cast in shade). Leaves and
    /// impostors alike, so a tree keeps its brightness across the switch.
    static let leafFragment = """
    #pragma opaque
    _output.color.rgb = max(_output.color.rgb - _lightingContribution.specular * 0.9, float3(0.0));
    _output.color.a = 1.0;
    """

    /// Distant trees: one quad per tree turned about the vertical towards
    /// the viewer.
    static let impostorGeometry = """
    #pragma varyings
    float fao;
    float3 ftint;
    float3 nrmM;
    #pragma body
    \(shadeDecode)
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

    /// Distant trees lit as crowns, not as flat stickers: the impostor
    /// atlas's detail map (`impDetail`: normal x right, y down; ao) gives
    /// each tree a sunlit side and a shaded one. An impostor turns about the
    /// vertical towards the camera, so its frame is the camera's horizontal
    /// right, world up and towards the camera. `impostorNormals` 0 (no map
    /// bound) lights it flat. The alpha cut rises with the mip level as in
    /// `foliageSurface` (or, with `mipCoverage` set, the alpha does); the
    /// light through the leaves comes from the side of the crown facing
    /// away from the sun.
    static let impostorSurface = """
    #pragma arguments
    float3 toSun;
    float translucency;
    float alphaCut;
    float atlasPx;
    float exposureGain;
    float impostorNormals;
    float mipCoverage;
    texture2d<float> impDetail;
    #pragma body
    float2 tc = _surface.diffuseTexcoord * atlasPx;
    float2 tdx = dfdx(tc), tdy = dfdy(tc);
    float lod = 0.5 * log2(max(max(dot(tdx, tdx), dot(tdy, tdy)), 1e-8));
    float rise = mipCoverage > 0.0 ? 0.0 : 0.045;
    float cut = alphaCut + clamp(lod - 1.0, 0.0, 6.0) * rise;
    if (_surface.diffuse.a * (1.0 + max(lod, 0.0) * mipCoverage) < cut) { discard_fragment(); }
    constexpr sampler lin(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float4 nd = impDetail.sample(lin, _surface.diffuseTexcoord);
    float3 rW = scn_frame.inverseViewTransform[0].xyz;
    rW.y = 0.0;
    rW = normalize(rW + float3(1e-5, 0.0, 0.0));
    float3 Rv = normalize((scn_frame.viewTransform * float4(rW, 0.0)).xyz);
    float3 Uv = normalize((scn_frame.viewTransform * float4(0.0, 1.0, 0.0, 0.0)).xyz);
    float3 Fv = normalize(cross(Rv, Uv));
    float2 t = (nd.rg * 2.0 - 1.0) * impostorNormals;
    float3 N = normalize(Rv * t.x - Uv * t.y + Fv * sqrt(saturate(1.0 - dot(t, t))));
    float3 V = normalize(_surface.view);
    N = normalize(N + V * max(0.0, 0.35 - dot(N, V)));
    _surface.normal = N;
    float ao = mix(1.0, nd.b, impostorNormals) * in.fao;
    _surface.ambientOcclusion = ao;
    float3 c = _surface.diffuse.rgb * in.ftint * mix(1.0, ao, 0.5);
    _surface.diffuse = float4(c, 1.0);
    float3 L = normalize((scn_frame.viewTransform * float4(toSun, 0.0)).xyz);
    float back = saturate(dot(-V, L));
    float through = saturate(0.3 - dot(N, L) * 0.7);
    float k = translucency * through * (0.15 + 0.85 * back * back) * exposureGain;
    _surface.emission = float4(c * float3(1.3, 1.45, 0.55) * k, 1.0);
    """

    /// Bark sways with the crown; detail normals from its packed texture.
    /// Its shading (texture channel 2's x: the sky the tree stands in, see
    /// `VegetationBuilder.skyShade`) dims the sky light only, as the light
    /// raster does the ground's, so a trunk in the sun keeps it.
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
    _surface.ambientOcclusion *= in.fao;
    _surface.roughness = d.b;
    """

    /// `barkSurface` from the Riviera's bark atlas (cj_bark_med_*: 4 x 2
    /// tiles of 512 px, each a 496 px periodic core in an 8 px wrap gutter).
    /// A vertex's u is its tile times `TreeArchetype.barkTileStride` plus its
    /// u within the tile, which repeats every 1, as v does; both atlases are
    /// sampled in the tile's core with the gradients of the unwrapped
    /// coordinates, so the repeats show no seam and no mip jump.
    static let barkAtlasSurface = """
    #pragma arguments
    texture2d<float> detailTex;
    texture2d<float> albedoTex;
    float normalStrength;
    #pragma body
    constexpr sampler aniso(filter::linear, mip_filter::linear, address::clamp_to_edge, max_anisotropy(8));
    float2 tc = _surface.diffuseTexcoord;
    float tile = floor(tc.x / \(TreeArchetype.barkTileStride));
    float2 local = float2(tc.x - tile * \(TreeArchetype.barkTileStride), tc.y);
    float2 cell = float2(fmod(tile, 4.0), floor(tile / 4.0));
    float2 span = float2(496.0 / 2048.0, 496.0 / 1024.0);
    float2 auv = (cell * 512.0 + 8.0) / float2(2048.0, 1024.0) + fract(local) * span;
    float2 uv = local * span;
    float2 gx = dfdx(uv), gy = dfdy(uv);
    float4 d = detailTex.sample(aniso, auv, gradient2d(gx, gy));
    _surface.diffuse = float4(albedoTex.sample(aniso, auv, gradient2d(gx, gy)).rgb, 1.0);
    float2 nxy = (d.rg * 2.0 - 1.0) * normalStrength;
    float3 nts = float3(nxy, sqrt(saturate(1.0 - dot(nxy, nxy))));
    \(cotangentNormal)
    _surface.normal = nMapped;
    _surface.ambientOcclusion *= in.fao;
    _surface.roughness = d.b;
    """
}
