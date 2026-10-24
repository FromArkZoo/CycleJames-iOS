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
