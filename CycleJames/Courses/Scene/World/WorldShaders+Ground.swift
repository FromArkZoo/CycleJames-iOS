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

    // MARK: - Riviera

    /// The Riviera's grid and far terrain: as `terrainGeometry`, bent down
    /// with the earth's curve (`earthCurve`) so the land meets the sea's
    /// horizon. A metre at 4 km, nothing to see near the road.
    static let terrainGeometryRiviera = """
    #pragma varyings
    float2 wxz;
    float3 vdat;
    float wy;
    #pragma body
    float4 ecW = scn_node.modelTransform * _geometry.position;
    out.wxz = _geometry.texcoords[0];
    out.vdat = float3(0.0);
    out.wy = ecW.y;
    \(earthCurve)
    """

    /// The Riviera's ground: `terrainSurface` with the land of a dry
    /// Ligurian spring instead of Flanders' (look.md section 3). Beyond the
    /// near photo it takes the far grid's own aerial photo (`farUV`, `farK`
    /// x gain, y 1 when there is one) rather than the Flemish patchwork,
    /// and past that, on the horizon ring, terraced grey-green slopes
    /// speckled white with greenhouses, villages by the sea and darker
    /// woods up high, carried on from the photo's own colours at its edge.
    /// Steep faces and banks show sun-baked ochre earth (#9a8064) and dry
    /// grass, not leaf litter and moss, through the photo's scrub, and only
    /// near the road: a hillside across the valley keeps its photo. The
    /// summer photos' dry grass and scrub are greened to March's. The
    /// verge's grass is the dry green and straw of #7a8455 / #a39c7f, its
    /// mud dust.
    static let terrainSurfaceRiviera: String = {
        var src = terrainSurface
        let swaps: [(String, String)] = [
            ("texture2d<float> farTex;\n", "texture2d<float> farTex;\nfloat4 farUV;\nfloat4 farK;\n"),
            ("float3 farc = farTex.sample(rep, p * (1.0 / 2560.0)).rgb;\n", rivieraFarGround + "\n"),
            ("float3 litter = mix(float3(0.045, 0.03, 0.016), float3(0.13, 0.085, 0.04), d1.b) * (0.8 + 0.4 * d2.b);",
             "float3 litter = mix(float3(0.10, 0.075, 0.045), float3(0.26, 0.18, 0.10), d1.b) * (0.8 + 0.4 * d2.b);"),
            ("float3 moss = float3(0.028, 0.046, 0.015) * (0.7 + 0.6 * d1.r);",
             "float3 moss = float3(0.10, 0.10, 0.045) * (0.7 + 0.6 * d1.r);"),
            ("float3 loam = float3(0.05, 0.04, 0.028) * (0.75 + 0.5 * d1.g);",
             "float3 loam = float3(0.20, 0.135, 0.08) * (0.75 + 0.5 * d1.g);"),
            // The Poggio's hillsides are steep nearly everywhere, and
            // scrub, terraces and gardens cover them: the photo stays,
            // earth shows through in part (at 0.45 the 1 m LiDAR's
            // terrace risers turned whole slopes beige from 30 m up).
            ("alb = mix(alb, litter, tri * 0.85);",
             "alb = mix(alb, litter, tri * 0.3 * (1.0 - smoothstep(80.0, 300.0, rvDist)));"),
            ("alb = mix(alb, litter, saturate(w.b * 0.6 + steep * 0.2));",
             "alb = mix(alb, litter, saturate(w.b * 0.3 + steep * 0.05));"),
            // The photo is a summer one (2022); in late March the slopes
            // are the dark greens of maquis, olive and holm oak with the
            // terraces' grass still green from the winter rains between
            // (look.md: #668158-#708a61 from the air, terraces #74825b,
            // the banks #3c4a3a, against the photo's straw #85856d-#b5a77f).
            // Its dry grass and scrub (yellowish: blue under 0.7-0.82 of
            // green, red under 1.15-1.4 of it) and the splat's grass are
            // re-coloured by their own brightness, steep terraces included:
            // two fifths darker at the median, the darker half with more
            // contrast, so the photo's shrubs and olives go to dark maquis
            // green, its straw to the terraces' green and its palest
            // patches (2022's drought-bare fields: they read as khaki lawn)
            // to a fresh, pale green with a little straw in it;
            // a quarter of the photo's own hue is kept, so two plants of one
            // brightness still differ (from 6 to 15 km the darkening fades
            // out; the paleness of the far hills is the land's own haze,
            // `rivieraLandHaze`: faded out from 3 km, the hills 3-5 km away
            // came back to the photo's bright summer green, reviews2). One
            // multiply by a green (as before)
            // turned every slope one khaki lawn. Greenhouse film, roofs,
            // paths and bare earth keep the photo's colour, and so does
            // the far photo's built-up land (`rvTown`). Beyond the near
            // photo the far photo and the procedural land get the same.
            // Then scrub and terraces at riding distance (`rivieraSlopes`),
            // and the coarse detail (11 m tile) at half its contrast: its
            // straw strokes on the banks read as scratches.
            ("alb *= (0.56 + 0.88 * mix(hMean, h, detailK)) * (0.84 + 0.32 * h2);",
             "float rvG = max(alb.g, 1e-4);\n" +
             "float rvDry = smoothstep(0.82, 0.7, alb.b / rvG) * (1.0 - smoothstep(1.15, 1.4, alb.r / rvG));\n" +
             "float rvVeg = max(w.r * photo, rvDry) * (1.0 - rvTown * (1.0 - photo));\n" +
             "float rvY = max(dot(alb, float3(0.2126, 0.7152, 0.0722)), 1e-4);\n" +
             "float rvY2 = mix(0.11 * pow(rvY / 0.19, rvY < 0.19 ? 1.35 : 1.0), rvY, smoothstep(6000.0, 15000.0, rvDist));\n" +
             "float3 rvC = mix(float3(0.70, 1.13, 0.62), float3(0.70, 1.15, 0.48), smoothstep(0.035, 0.10, rvY2));\n" +
             "rvC = mix(rvC, float3(1.10, 1.0, 0.62), smoothstep(0.14, 0.26, rvY2) * 0.3);\n" +
             "float3 rvP = alb * float3(0.84, 1.13, 0.8);\n" +
             "rvP /= max(dot(rvP, float3(0.2126, 0.7152, 0.0722)), 1e-4);\n" +
             "alb = mix(alb, mix(rvC, rvP, 0.25) * rvY2, rvVeg);\n" +
             rivieraSlopes + "\n" +
             "alb *= (0.56 + 0.88 * mix(hMean, h, detailK)) * (0.92 + 0.16 * h2);"),
            // Moss, loam and ivy in soft clumps (`rvMot`), not along the
            // detail's straw strokes: on the Riviera's pale earth those
            // drew dark hatching over every bank.
            ("float mossN = smoothstep(0.4, 0.62, iv * 0.6 + d2.r * 0.5);",
             "float mossN = smoothstep(0.45, 0.7, rvMot);"),
            ("float3 face = mix(mix(litter, loam, saturate(0.35 + (d2.g - 0.5) * 1.5)), moss, mossN * 0.8);",
             "float3 face = mix(mix(litter, loam, saturate(0.35 + (rvN2 - 0.5) * 1.2)), moss, mossN * 0.8);"),
            ("float ivyN = smoothstep(0.30, 0.55, d2.r * 0.55 + iv * 0.6);",
             "float ivyN = smoothstep(0.38, 0.62, rvMot);"),
            // Clods a quarter as deep and from a blurrier level: the leaf
            // and straw shapes of the 11 m tile stood out on the banks as
            // engraved twigs.
            ("float2 gdx = (alongX ? qxdx : qzdx) * 0.0885;", "float2 gdx = (alongX ? qxdx : qzdx) * 0.0885 * 6.0;"),
            ("float2 gdy = (alongX ? qxdy : qzdy) * 0.0885;", "float2 gdy = (alongX ? qxdy : qzdy) * 0.0885 * 6.0;"),
            ("nP -= (U * (su - s0) - float3(0.0, sv - s0, 0.0)) * (1.6 * k * tri);",
             "nP -= (U * (su - s0) - float3(0.0, sv - s0, 0.0)) * (0.4 * k * tri);"),
            ("float3 ivy = float3(0.018, 0.042, 0.012) * (0.6 + 0.8 * d1.b);",
             "float3 ivy = float3(0.05, 0.075, 0.03) * (0.6 + 0.8 * d1.b);"),
            ("float3 vg = float3(0.065, 0.12, 0.028) * (0.6 + 0.8 * d1.r);",
             "float3 vg = mix(float3(0.12, 0.14, 0.055), float3(0.24, 0.21, 0.12), d2.r) * (0.6 + 0.8 * d1.r);"),
            // The verge's grass strip lies flat by the road; up a bank it
            // is the bank's scrub, grass and earth (`rivieraSlopes`).
            ("alb = mix(alb, vg, vgrass * 0.45);", "alb = mix(alb, vg, vgrass * 0.45 * (1.0 - rvSteep));"),
            ("alb = mix(alb, float3(0.036, 0.026, 0.016) * (0.8 + 0.4 * d1.b) * (0.75 + 0.5 * d2.g), mud * 0.9);",
             "alb = mix(alb, float3(0.10, 0.08, 0.055) * (0.8 + 0.4 * d1.b) * (0.75 + 0.5 * d2.g), mud * 0.9);"),
        ]
        for (old, new) in swaps {
            precondition(src.components(separatedBy: old).count == 2, "terrainSurface changed: \(old)")
            src = src.replacingOccurrences(of: old, with: new)
        }
        return src
    }()

    /// Scrub and terraces on the near photo's slopes, where the photo seen
    /// side-on from the road is a smooth wash (`terrainSurfaceRiviera`):
    /// dark clumps of maquis two to ten metres across, and between them
    /// the dry-stone risers of the fasce along the contour, about every
    /// 1.6 m of height (look.md section 3), wandering as real terraces do.
    /// Value noise from a hash, as no texture holds clumps this size; both
    /// fade to their mean before a cell or a band shrinks to a pixel, so
    /// nothing shimmers. `rvMot` and `rvN2` also place the moss, loam and
    /// ivy on the steep faces and the banks. Flat ground, roofs, paths
    /// and greenhouses (not `rvVeg`) are left alone.
    static let rivieraSlopes = """
    float2 rvQ = p * 0.42;
    float2 rvI = floor(rvQ);
    float2 rvU = rvQ - rvI;
    rvU = rvU * rvU * (3.0 - 2.0 * rvU);
    float4 rvH = fract(sin(float4(dot(rvI, float2(127.1, 311.7)), dot(rvI + float2(1.0, 0.0), float2(127.1, 311.7)),
                                  dot(rvI + float2(0.0, 1.0), float2(127.1, 311.7)), dot(rvI + float2(1.0, 1.0), float2(127.1, 311.7)))) * 43758.5453);
    float rvN1 = mix(mix(rvH.x, rvH.y, rvU.x), mix(rvH.z, rvH.w, rvU.x), rvU.y);
    float2 rvQ2 = p * 0.09 + float2(17.3, 5.1);
    float2 rvI2 = floor(rvQ2);
    float2 rvU2 = rvQ2 - rvI2;
    rvU2 = rvU2 * rvU2 * (3.0 - 2.0 * rvU2);
    float4 rvH2 = fract(sin(float4(dot(rvI2, float2(269.5, 183.3)), dot(rvI2 + float2(1.0, 0.0), float2(269.5, 183.3)),
                                   dot(rvI2 + float2(0.0, 1.0), float2(269.5, 183.3)), dot(rvI2 + float2(1.0, 1.0), float2(269.5, 183.3)))) * 43758.5453);
    float rvN2 = mix(mix(rvH2.x, rvH2.y, rvU2.x), mix(rvH2.z, rvH2.w, rvU2.x), rvU2.y);
    float rvFw = length(fwidth(rvQ));
    rvN1 = mix(0.5, rvN1, (1.0 - smoothstep(0.3, 0.8, rvFw)) * photo);
    rvN2 = mix(0.5, rvN2, (1.0 - smoothstep(0.3, 0.8, rvFw * 0.214)) * photo);
    float rvMot = rvN1 * 0.4 + rvN2 * 0.6;
    float rvSlope = (1.0 - smoothstep(0.88, 0.97, nW.y)) * rvVeg;
    // Banks steeper than about 25-35 degrees near the road (the cut below
    // the wall at route 1900, POV f50-f52): about half scrub, then dry
    // grass, straw and green together, and bare ochre earth (#9a8064)
    // where the clumps thin out. Recoloured as a meadow, the photo's grass
    // read as one smooth khaki lawn (reviews2, 1900 back view: #7f855c,
    // luma std 12); keyed on the triplanar share (from 30 degrees) it
    // missed that bank.
    // Clumps there are the 2-5 m ones: on a bank 10-15 m high the 11 m
    // noise alone made it all scrub or all earth.
    float rvSteep = (1.0 - smoothstep(0.80, 0.93, nW.y)) * (1.0 - smoothstep(60.0, 200.0, rvDist)) * photo;
    float rvMb = mix(rvMot, rvN1 * 0.65 + rvN2 * 0.35, rvSteep);
    float rvScrub = smoothstep(0.5 - 0.1 * rvSteep, 0.68 - 0.12 * rvSteep, rvMb) * rvSlope;
    alb = mix(alb, float3(0.030, 0.044, 0.027) * (0.75 + 0.5 * rvN1), rvScrub * 0.7);
    float rvBank = rvSteep * rvVeg * (1.0 - rvScrub);
    alb = mix(alb, mix(float3(0.13, 0.13, 0.065), float3(0.28, 0.24, 0.13), saturate(d1.r * 0.8 + rvN1 * 0.6 - 0.2)), rvBank * 0.5);
    float rvBare = (1.0 - smoothstep(0.31, 0.43, rvMb + (rvN2 - 0.5) * 0.3)) * rvBank;
    alb = mix(alb, float3(0.25, 0.175, 0.105) * (0.8 + 0.4 * d2.g), rvBare * 0.8);
    float rvT = in.wy / 1.6 + (rvN2 - 0.5) * 1.6 + rvN1 * 0.35;
    float rvTw = fwidth(rvT);
    float rvRiser = (1.0 - smoothstep(0.15, 0.15 + max(rvTw, 0.04), fract(rvT))) * (1.0 - smoothstep(0.06, 0.15, rvTw));
    float rvTer = (1.0 - smoothstep(0.42, 0.56, rvMot)) * rvSlope * smoothstep(0.45, 0.7, nW.y) * photo;
    alb = mix(alb, float3(0.10, 0.083, 0.06) * (0.75 + 0.5 * rvN1), rvRiser * rvTer * 0.65);
    """

    /// The Riviera's land seen through its own air, on the lit colour (a
    /// fragment body; `WorldMaterials.groundMaterial`). SceneKit's fog
    /// (`WorldLook.fogEndDistance`) is kept light for the sea's sake, whose
    /// graded blues and soft horizon the reviewers counted as right; over
    /// land it left the hills 1-5 km away bright summer green and the Alpi
    /// Liguri at 10 km #7e8f99 (reviews2) against #85a3bb-#969daa (look.md
    /// section 2: Commons P1010130, P1010170) and the blue-grey in f104 and
    /// the 3410 m photo. Here the land alone takes a bluer haze, up to a
    /// fifth of it by 5-10 km, giving way to the fog where that takes over
    /// (the far coast stays the fog's #9fb3c8), and its colour greys by
    /// up to two fifths: the real airlight over 30 km visibility,
    /// 1 - exp(-d / 7.7 km), is 0.32 at 3 km and 0.73 at 10 km, where the
    /// fog alone gives 0.22 and 0.55. Distance is the camera's, so the
    /// shadows and sunlit slopes of a far hill flatten together.
    static let rivieraLandHaze: String = {
        let look = WorldLook.riviera
        let h = look.horizonLinear * SIMD3(0.62, 0.78, 0.95)
        func f(_ v: Double) -> String { String(format: "%.4f", v) }
        return """
        float rvHd = length(_surface.position);
        float rvHf = pow(saturate(rvHd / \(f(Double(look.fogEndDistance)))), \(f(Double(look.fogExponent))));
        float rvHa = (1.0 - exp(-rvHd / 6000.0)) * (1.0 - rvHf) * 0.5;
        float3 rvHc = _output.color.rgb;
        rvHc = mix(rvHc, float3(dot(rvHc, float3(0.2126, 0.7152, 0.0722))), smoothstep(500.0, 6000.0, rvHd) * 0.4);
        _output.color.rgb = mix(rvHc, float3(\(f(h.x)), \(f(h.y)), \(f(h.z))) * _output.color.a, rvHa);
        """
    }()

    /// `farc` for the Riviera (see `terrainSurfaceRiviera`). Declares its
    /// own names (`rv…`): the host's normal and distance come later.
    /// The far photo is sampled anisotropically: seen from the road at 1
    /// to 5 km it lies at a grazing angle, and a plain trilinear sample
    /// takes a level so coarse that its terraces, woods, greenhouses and
    /// villages blurred into one smooth green.
    static let rivieraFarGround = """
    constexpr sampler rvAn(filter::linear, mip_filter::linear, address::clamp_to_edge, max_anisotropy(16));
    float rvDist = length(_surface.position);
    float2 fuv = p * farUV.xy + farUV.zw;
    float2 fe = min(fuv, 1.0 - fuv);
    float fIn = smoothstep(0.0, 0.02, min(fe.x, fe.y)) * farK.y;
    float3 farc = farTex.sample(rvAn, fuv).rgb * farK.x;
    // Built-up land in the far photo (Sanremo's east end and port, Arma
    // di Taggia, Bussana, the greenhouse quarters): pale and grey over
    // 40 m (luminance over 0.13-0.2, blue 0.74-0.84 of green or more),
    // where scrub, woods and terraces are darker and yellower (blue about
    // 0.7). The March greening leaves it as the photo has it.
    float3 rvL = farTex.sample(clp, fuv, level(4.0)).rgb;
    float rvLb = rvL.b / max(rvL.g, 1e-4);
    float rvTown = smoothstep(0.13, 0.2, dot(rvL, float3(0.2126, 0.7152, 0.0722))) * smoothstep(0.74, 0.84, rvLb)
        * (1.0 - smoothstep(1.05, 1.3, rvLb)) * fIn;
    // Seen side-on from the road its roofs, walls and streets averaged to
    // one pinkish beige (reviews2): its own pixels with their contrast
    // about the 40 m mean stretched, so the pale blocks, the terracotta
    // and the dark gaps between them read as a town.
    farc = mix(farc, max(rvL * farK.x + (farc - rvL * farK.x) * 1.6, 0.0) * 1.1, rvTown);
    if (fIn < 0.999) {
        float3 rvN = normalize((scn_frame.inverseViewTransform * float4(normalize(_surface.normal), 0.0)).xyz);
        // Value noise at 150 m (fields, scrub, olive groves) and 600 m
        // (woods, the grain of the slopes): the detail texture's strokes
        // average to one grey at these distances, which left the ring a
        // uniform green.
        float2 rvLq = p * (1.0 / 150.0);
        float2 rvLi = floor(rvLq);
        float2 rvLu = rvLq - rvLi;
        rvLu = rvLu * rvLu * (3.0 - 2.0 * rvLu);
        float4 rvLh = fract(sin(float4(dot(rvLi, float2(127.1, 311.7)), dot(rvLi + float2(1.0, 0.0), float2(127.1, 311.7)),
                                       dot(rvLi + float2(0.0, 1.0), float2(127.1, 311.7)), dot(rvLi + float2(1.0, 1.0), float2(127.1, 311.7)))) * 43758.5453);
        float rvLn1 = mix(mix(rvLh.x, rvLh.y, rvLu.x), mix(rvLh.z, rvLh.w, rvLu.x), rvLu.y);
        float2 rvMq = p * (1.0 / 600.0) + float2(3.7, 9.2);
        float2 rvMi = floor(rvMq);
        float2 rvMu = rvMq - rvMi;
        rvMu = rvMu * rvMu * (3.0 - 2.0 * rvMu);
        float4 rvMh = fract(sin(float4(dot(rvMi, float2(269.5, 183.3)), dot(rvMi + float2(1.0, 0.0), float2(269.5, 183.3)),
                                       dot(rvMi + float2(0.0, 1.0), float2(269.5, 183.3)), dot(rvMi + float2(1.0, 1.0), float2(269.5, 183.3)))) * 43758.5453);
        float rvLn2 = mix(mix(rvMh.x, rvMh.y, rvMu.x), mix(rvMh.z, rvMh.w, rvMu.x), rvMu.y);
        // Houses and greenhouses come in blocks of about 14 m (a grid
        // turned 30 degrees off north, so no row lines up with the view
        // along the coast); a pixel wider than a block takes their mean.
        // At 40 m they stood out from 3-6 km as white and terracotta
        // squares, a checkerboard rather than a town.
        float2 rvCq = float2(p.x * 0.866 - p.y * 0.5, p.x * 0.5 + p.y * 0.866) * (1.0 / 14.0);
        float rvCh = fract(sin(dot(floor(rvCq), float2(127.1, 311.7))) * 43758.5453);
        float rvCs = 1.0 - smoothstep(0.3, 1.0, length(fwidth(rvCq)));
        // Terraces of olive, scrub and dry grass low down, darker maquis
        // in patches; pine and chestnut woods from about 600 m; bare rock
        // only on the steepest faces (the Alpi Liguri are wooded and
        // scrubby to their tops).
        // Between them, scrub and woods against terraced grass and olives
        // in clumps of 30-120 m, and the dry-stone tiers along the contour
        // every ~8 m of height: the scale the eye picks out on a hillside
        // 3-10 km away (f104 and the 3410 m photo: dark mottled maquis with
        // paler terraced bands). With the 150 and 600 m noise alone the
        // slopes were smooth green (reviews2, 2220 and 3700 eye). Both fade
        // to their mean before a clump or a tier shrinks to a pixel.
        float2 rvSq = p * (1.0 / 38.0) + float2(7.3, 1.9);
        float2 rvSi = floor(rvSq);
        float2 rvSu = rvSq - rvSi;
        rvSu = rvSu * rvSu * (3.0 - 2.0 * rvSu);
        float4 rvSh = fract(sin(float4(dot(rvSi, float2(127.1, 311.7)), dot(rvSi + float2(1.0, 0.0), float2(127.1, 311.7)),
                                       dot(rvSi + float2(0.0, 1.0), float2(127.1, 311.7)), dot(rvSi + float2(1.0, 1.0), float2(127.1, 311.7)))) * 43758.5453);
        float rvSn = mix(mix(rvSh.x, rvSh.y, rvSu.x), mix(rvSh.z, rvSh.w, rvSu.x), rvSu.y);
        rvSn = mix(0.5, rvSn, 1.0 - smoothstep(0.3, 0.8, length(fwidth(rvSq))));
        float rvSm = rvSn * 0.5 + rvLn1 * 0.3 + rvLn2 * 0.2;
        float rvTr = in.wy / 8.0 + (rvLn1 - 0.5) * 3.0 + rvSn * 0.6;
        float rvTrw = fwidth(rvTr);
        float rvTb = (1.0 - smoothstep(0.22, 0.22 + max(rvTrw, 0.05), fract(rvTr))) * (1.0 - smoothstep(0.15, 0.4, rvTrw));
        float3 land = mix(float3(0.15, 0.14, 0.10) * (1.0 - 0.3 * rvTb), float3(0.045, 0.055, 0.038), smoothstep(0.42, 0.58, rvSm));
        land = mix(land, float3(0.042, 0.056, 0.033) * (0.8 + 0.4 * rvLn1),
                   smoothstep(450.0, 900.0, in.wy + 500.0 * (rvLn2 - 0.5)));
        land = mix(land, float3(0.19, 0.18, 0.16), (1.0 - smoothstep(0.5, 0.7, rvN.y)) * 0.4);
        // Whitewashed greenhouses speckle the slopes by the sea, and the
        // towns fill the low land along the shore (Sanremo, Arma di
        // Taggia): pale render and terracotta roofs, block by block.
        float low = 1.0 - smoothstep(220.0, 420.0, in.wy);
        float gh = mix(0.1, step(0.9, rvCh), rvCs) * low * smoothstep(0.55, 0.8, rvN.y) * smoothstep(0.3, 0.6, rvLn1);
        land = mix(land, float3(0.26, 0.28, 0.27), gh * 0.5);
        // The towns stand on the coastal plain (Sanremo's west end, Arma di
        // Taggia, Riva Ligure: the flat land within ~25 m of the sea); on
        // the low hill flanks above it they drew a pink checkerboard
        // (reviews2, 1450 high). Blocks of about 30 m, pale render or
        // terracotta roofs, with the streets and courtyards in shade
        // between, so the band keeps its grain to 6-8 km, where 14 m
        // blocks had faded to one plain beige strip (look.md: render
        // #e8dcc4-#e2c6bf, roofs #c4876a; the Commons view east and the
        // PEZ 2007 view west: dense pale blocks with dark gaps).
        float town = smoothstep(0.2, 0.38, rvLn2) * (1.0 - smoothstep(18.0, 35.0, in.wy)) * smoothstep(0.9, 0.97, rvN.y);
        float2 rvBq = float2(p.x * 0.866 - p.y * 0.5, p.x * 0.5 + p.y * 0.866) * (1.0 / 32.0);
        float2 rvBf = fract(rvBq);
        float rvBh = fract(sin(dot(floor(rvBq), float2(269.5, 183.3))) * 43758.5453);
        // Faded by the footprint's short axis and a third of its long one:
        // flat land seen at a grazing angle otherwise lost the blocks first.
        float2 rvBw = float2(length(dfdx(rvBq)), length(dfdy(rvBq)));
        float rvBs = 1.0 - smoothstep(0.25, 0.7, max(max(rvBw.x, rvBw.y) / 3.0, min(rvBw.x, rvBw.y)));
        float3 roofs = rvBh < 0.55 ? float3(0.42, 0.39, 0.33) : (rvBh < 0.85 ? float3(0.30, 0.15, 0.09) : float3(0.34, 0.33, 0.30));
        roofs = mix(roofs, float3(0.05, 0.05, 0.045), max(step(0.82, rvBf.x), step(0.82, rvBf.y)));
        roofs = mix(float3(0.30, 0.285, 0.255), roofs, rvBs);
        land = mix(land, roofs, town * 0.85);
        // Close to the photo, its own colours carried on.
        float rvOut = max(max(-fuv.x, fuv.x - 1.0), max(-fuv.y, fuv.y - 1.0)) / max(farUV.x, 1e-6);
        float3 mean = float3(0.10, 0.104, 0.07);
        float3 edge = farK.y > 0.5 ? farTex.sample(clp, saturate(fuv), level(6.0)).rgb * farK.x : mean;
        land *= mix(edge, mean, smoothstep(0.0, 5000.0, rvOut)) / mean;
        farc = mix(land, farc, fIn);
    }
    """
}
