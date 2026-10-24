import SceneKit

/// Metal shader modifiers for the world materials (see SCNShadable.h).
/// Per-vertex data travels in extra texture channels (vertex colours would
/// be multiplied into the diffuse) and reaches the fragment stage through
/// `#pragma varyings`.
///
/// The tangent frame and the streams' and opaque fragments are here. The
/// course's light raster (`lightArgs`, `lightFetch`, `lightApply`), spliced
/// into the ground, road, sett and wall surfaces, is in `WorldShaders+Light`;
/// each part's own modifiers are in `WorldShaders+Ground`, `+Road`,
/// `+Setts`, `+Plants` and `+Buildings`.
enum WorldShaders {
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
}
