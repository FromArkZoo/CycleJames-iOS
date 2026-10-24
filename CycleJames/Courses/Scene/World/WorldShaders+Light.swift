import SceneKit

/// The course's baked light raster (scripts/courses/textures/
/// bake_light_maps.py, bound by `WorldMaterials.bindLight`), spliced into
/// the ground, road, sett and wall surfaces. The image-based sky light reaches
/// every surface at full strength, and the shadow map stops at the tier's
/// `shadowDistance`: the raster stands in for both, so a sunken lane sees
/// only its strip of sky and the woods throw shade however far away they
/// are. Its names start `lgt` (and `lIn`) so they can't collide with a
/// host shader's own.
extension WorldShaders {
    /// Arguments: the raster, world (x, z) to its uv as `xz * xy + zw`,
    /// `lightK` (x the sun-to-sky irradiance ratio for a surface facing the
    /// sun; y, z the camera depths over which the baked sun shade takes
    /// over from the shadow map; w the floor on sky visibility, for the
    /// bounce light the bake leaves out) and the direction to the sun
    /// (world).
    static let lightArgs = """
    texture2d<float> lightTex;
    float4 lightUV;
    float4 lightK;
    float3 lightSun;
    """

    /// The raster at the world position `lgtP`: `lgtQ` = (sky visibility,
    /// sun visibility, canopy height / 40 m, ground height). It fades to
    /// open, sunlit ground over the last 2 % of its footprint, where the
    /// near terrain grid gives way to the far one.
    static let lightFetch = """
    constexpr sampler lgtSm(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float2 lgtUV = lgtP.xz * lightUV.xy + lightUV.zw;
    float4 lgtQ = lightTex.sample(lgtSm, lgtUV);
    float2 lgtE = min(lgtUV, 1.0 - lgtUV);
    float lIn = smoothstep(0.0, 0.02, min(lgtE.x, lgtE.y));
    lgtQ = mix(float4(1.0, 1.0, 0.0, 0.0), lgtQ, lIn);
    """

    /// Needs `lgtQ` (`lightFetch`), `alb` (linear albedo, changed here),
    /// `lgtN` (world geometric normal) and `lgtD` (camera depth). Sky
    /// visibility becomes ambient occlusion with multi-bounce (Jimenez et
    /// al. 2016, so pale ground doesn't go grey). Past the shadow map the
    /// baked sun shade scales the albedo so that "fully lit" becomes the
    /// ambient plus the visible share of the sun: the lit result is
    /// albedo (A ao + D NL) and we want albedo (A ao + D NL g), with
    /// lightK.x = D / A, which is exact for the diffuse. Under a canopy the
    /// sky light's share turns slightly green.
    static let lightApply = """
    float lgtV = max(lgtQ.r, lightK.w);
    float lgtA = dot(alb, float3(0.2126, 0.7152, 0.0722));
    float lgtAO = max(lgtV, ((lgtV * (2.0404 * lgtA - 0.3324) + (0.6417 - 4.7951 * lgtA)) * lgtV + (2.7552 * lgtA + 0.6903)) * lgtV);
    _surface.ambientOcclusion *= lgtAO;
    float lgtK = lightK.x * saturate(dot(lgtN, lightSun));
    float lgtG = mix(1.0, lgtQ.g, smoothstep(lightK.y, lightK.z, lgtD));
    alb *= (lgtAO + lgtK * lgtG) / (lgtAO + lgtK);
    float lgtSky = lgtAO / (lgtAO + lgtK * lgtG + 1e-4);
    alb *= mix(float3(1.0), float3(0.90, 1.0, 0.84), lgtSky * smoothstep(0.06, 0.12, lgtQ.b) * 0.5);
    """
}
