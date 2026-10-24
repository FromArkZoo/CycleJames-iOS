import SceneKit

/// Ground: the terrain grid, the far terrain and the road verges.
extension WorldShaders {
    /// Grid and far terrain: world (x, z) arrives in texcoord 0; world y
    /// (for the triplanar detail on steep faces) from the position.
    static let terrainGeometry = """
    #pragma varyings
    float2 wxz;
    float3 vdat;
    float wy;
    #pragma body
    out.wxz = _geometry.texcoords[0];
    out.vdat = float3(0.0);
    out.wy = (scn_node.modelTransform * _geometry.position).y;
    """

    /// Verge: texcoord 1 = (bank, verge grass), texcoord 2 = (mud, -).
    static let vergeGeometry = """
    #pragma varyings
    float2 wxz;
    float3 vdat;
    float wy;
    #pragma body
    out.wxz = _geometry.texcoords[0];
    out.vdat = float3(_geometry.texcoords[1], _geometry.texcoords[2].x);
    out.wy = (scn_node.modelTransform * _geometry.position).y;
    """

    /// Ortho photo (the diffuse, mapped by contentsTransform) blended with
    /// tiled detail by ground type, a far-field patchwork beyond the photo,
    /// bare earth on steep slopes and, on the verge, ivy, grass and mud.
    /// Projected in plan, the photo and the detail would stretch into
    /// streaks down a steep face (a sunken lane's banks): from about 30
    /// degrees the detail turns triplanar and the photo gives way to earth,
    /// leaf litter and moss. Lit through the course's light raster
    /// (`WorldShaders+Light`).
    static let terrainSurface = """
    #pragma arguments
    texture2d<float> splatTex;
    texture2d<float> detailTex;
    texture2d<float> farTex;
    float detailNormals;
    \(lightArgs)
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
    // Triplanar share: none below about 30 degrees, all from about 45.
    float tri = 1.0 - smoothstep(0.7, 0.87, nW.y);
    float3 bw = nW * nW;
    bw *= bw;
    bw /= bw.x + bw.y + bw.z;
    // Blending projections averages their contrast away; restore it.
    float rc = min(rsqrt(dot(bw, bw)), 1.6);
    // Side projections, seen along x (z, -y) and along z (x, -y). Their
    // gradients are taken here: not inside the branch below.
    float2 qx = float2(p.y, -in.wy);
    float2 qz = float2(p.x, -in.wy);
    float2 qxdx = dfdx(qx), qxdy = dfdy(qx), qzdx = dfdx(qz), qzdy = dfdy(qz);
    w.b = max(w.b, steep);
    float bank = in.vdat.x;
    float vgrass = in.vdat.y;
    float mud = in.vdat.z;
    w.b = max(w.b, bank);
    // No grass blades or crop rows on a steep face: seen side-on they
    // stretch into straw-coloured streaks down the bank.
    w.rg *= 1.0 - steep;
    w /= max(w.r + w.g + w.b + w.a, 0.001);
    // The verge strip is grass even where the field beside it is crops.
    w = mix(w, float4(1.0, 0.0, 0.0, 0.0), vgrass);
    float2 duv = p * 0.4;
    // Texels of the 2.5 m tile per pixel, along the footprint's long axis
    // past the anisotropy limit or across it: once a pixel spans several,
    // the pattern only aliases (fields seen from the road turn to moire),
    // so it fades to the channels' means (bake_materials.py prints them).
    // Measured along the screen axes, so the fade doesn't depend on which
    // way the road runs.
    float2 fw = float2(length(dfdx(duv)), length(dfdy(duv))) * 1024.0;
    float aniso = max(max(fw.x, fw.y) / 8.0, min(fw.x, fw.y));
    float detailK = 1.0 - smoothstep(3.0, 12.0, aniso);
    // Steep faces take the triplanar detail, which the plan footprint
    // doesn't describe.
    detailK = max(detailK, tri);
    float hMean = dot(w, float4(0.246, 0.369, 0.334, 0.594));
    float4 d1 = detailTex.sample(rep, duv);
    float4 d2 = detailTex.sample(rep, p * 0.0885 + float2(0.31, 0.77));
    float iv = detailTex.sample(rep, p * 0.023).g;
    float hPlan = dot(w, d1);
    if (tri > 0.001) {
        float4 d1x = detailTex.sample(rep, qx * 0.4, gradient2d(qxdx * 0.4, qxdy * 0.4));
        float4 d1z = detailTex.sample(rep, qz * 0.4, gradient2d(qzdx * 0.4, qzdy * 0.4));
        float4 d2x = detailTex.sample(rep, qx * 0.0885 + float2(0.31, 0.77), gradient2d(qxdx * 0.0885, qxdy * 0.0885));
        float4 d2z = detailTex.sample(rep, qz * 0.0885 + float2(0.31, 0.77), gradient2d(qzdx * 0.0885, qzdy * 0.0885));
        float ivx = detailTex.sample(rep, qx * 0.023, gradient2d(qxdx * 0.023, qxdy * 0.023)).g;
        float ivz = detailTex.sample(rep, qz * 0.023, gradient2d(qzdx * 0.023, qzdy * 0.023)).g;
        float4 t1 = saturate(0.5 + (d1 * bw.y + d1x * bw.x + d1z * bw.z - 0.5) * rc);
        float4 t2 = saturate(0.5 + (d2 * bw.y + d2x * bw.x + d2z * bw.z - 0.5) * rc);
        float ti = saturate(0.5 + (iv * bw.y + ivx * bw.x + ivz * bw.z - 0.5) * rc);
        d1 = mix(d1, t1, tri);
        d2 = mix(d2, t2, tri);
        iv = mix(iv, ti, tri);
    }
    float h = dot(w, d1);
    float h2 = dot(w, d2);
    float dist = length(_surface.position);
    // Detail normals only close by: further out they only add a sheen.
    float nearF = 1.0 - smoothstep(6.0, 45.0, dist);
    alb *= (0.56 + 0.88 * mix(hMean, h, detailK)) * (0.84 + 0.32 * h2);
    float3 litter = mix(float3(0.045, 0.03, 0.016), float3(0.13, 0.085, 0.04), d1.b) * (0.8 + 0.4 * d2.b);
    alb = mix(alb, litter, saturate(w.b * 0.6 + steep * 0.2));
    // Steep faces: dark loam and leaf litter with moss in patches instead
    // of the photo.
    float mossN = smoothstep(0.4, 0.62, iv * 0.6 + d2.r * 0.5);
    float3 moss = float3(0.028, 0.046, 0.015) * (0.7 + 0.6 * d1.r);
    float3 loam = float3(0.05, 0.04, 0.028) * (0.75 + 0.5 * d1.g);
    float3 face = mix(mix(litter, loam, saturate(0.35 + (d2.g - 0.5) * 1.5)), moss, mossN * 0.8);
    litter = mix(litter, face, tri);
    alb = mix(alb, litter, tri * 0.85);
    float ivyN = smoothstep(0.30, 0.55, d2.r * 0.55 + iv * 0.6);
    float3 ivy = float3(0.018, 0.042, 0.012) * (0.6 + 0.8 * d1.b);
    alb = mix(alb, mix(litter, ivy, ivyN), bank * 0.9);
    float3 vg = float3(0.065, 0.12, 0.028) * (0.6 + 0.8 * d1.r);
    alb = mix(alb, vg, vgrass * 0.45);
    // Wet loam, darker where it lies wetter.
    alb = mix(alb, float3(0.036, 0.026, 0.016) * (0.8 + 0.4 * d1.b) * (0.75 + 0.5 * d2.g), mud * 0.9);
    if (detailNormals > 0.5 && nearF > 0.0) {
        float e = 1.0 / 1024.0;
        // Wet loam settles smooth: at full strength its crumbs caught the
        // sun on every facet, like crumpled foil.
        float k = 2.5 * nearF * (1.0 - 0.75 * mud);
        float3 nP = nW;
        if (tri < 0.999) {
            float hx = dot(w, detailTex.sample(rep, duv + float2(e, 0.0)));
            float hz = dot(w, detailTex.sample(rep, duv + float2(0.0, e)));
            nP -= float3(hx - hPlan, 0.0, hz - hPlan) * (k * (1.0 - tri));
        }
        if (tri > 0.001) {
            // Clods and roots: coarse bumps from the side projection the
            // face looks along most.
            bool alongX = abs(nW.x) > abs(nW.z);
            float2 q = (alongX ? qx : qz) * 0.0885 + float2(0.31, 0.77);
            float2 gdx = (alongX ? qxdx : qzdx) * 0.0885;
            float2 gdy = (alongX ? qxdy : qzdy) * 0.0885;
            float s0 = dot(w, detailTex.sample(rep, q, gradient2d(gdx, gdy)));
            float su = dot(w, detailTex.sample(rep, q + float2(e, 0.0), gradient2d(gdx, gdy)));
            float sv = dot(w, detailTex.sample(rep, q + float2(0.0, e), gradient2d(gdx, gdy)));
            float3 U = alongX ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
            nP -= (U * (su - s0) - float3(0.0, sv - s0, 0.0)) * (1.6 * k * tri);
        }
        _surface.normal = normalize((scn_frame.viewTransform * float4(normalize(nP), 0.0)).xyz);
    }
    // Sky occlusion and the sun's shade beyond the shadow map.
    float3 lgtP = float3(p.x, in.wy, p.y);
    float3 lgtN = nW;
    float lgtD = -_surface.position.z;
    \(lightFetch)
    \(lightApply)
    _surface.diffuse = float4(alb, 1.0);
    // Grass and crops are canopies, not surfaces: near-matte. Steep faces
    // fully rough: their side-projected clods would mirror the sky in thin
    // grey lines along the bank. Mud satin: at 0.45 it read as a pale grey
    // band along the lane at grazing angles.
    float rough = dot(w, float4(0.97, 0.95, 0.9, 0.85));
    rough = mix(rough, 0.55, bank * ivyN);
    rough = mix(rough, 1.0, tri);
    _surface.roughness = max(mix(rough, 0.8, mud), 0.4);
    """

    /// Verge: the mud keeps a quarter of its reflection. Dark wet loam
    /// beside a sunlit lane mirrored the bright sky at grazing angles
    /// (Fresnel) far above its own albedo, so the strip read as grey foil,
    /// not earth.
    static let vergeFragment = """
    #pragma body
    _output.color.rgb = max(_output.color.rgb - _lightingContribution.specular * (0.75 * saturate(in.vdat.z)), float3(0.0));
    """
}
