import SceneKit

/// The sea (`SeaBuilder`, `WorldMaterials.makeSea`) and the earth's curve
/// that the Riviera's distant land and water bend down with.
extension WorldShaders {
    /// Lowers a vertex by the earth's curve, d^2 / 2R, d being its
    /// distance from the camera across the ground and R the radius with
    /// refraction (`WorldLook.earthRadiusM`): 7 m at 10 km, 27 m at 20 km,
    /// so the sea's horizon dips under the eye level as it does from a
    /// hill. Needs the vertex in world space as `ecW` (a float4); changes
    /// `_geometry.position`, whose node may only be moved, not turned.
    static let earthCurve = """
    float2 ecD = ecW.xz - scn_frame.inverseViewTransform[3].xz;
    _geometry.position.y -= dot(ecD, ecD) * \(0.5 / WorldLook.earthRadiusM);
    """

    /// Sea: world (x, z) and the distance to the shore (texcoord 1 x) for
    /// the surface; the node sits at the origin.
    static let seaGeometry = """
    #pragma varyings
    float2 wxz;
    float shore;
    float wy;
    #pragma body
    float4 ecW = _geometry.position;
    out.wxz = ecW.xz;
    out.shore = _geometry.texcoords[1].x;
    \(earthCurve)
    out.wy = _geometry.position.y;
    """

    /// The sea's colour, drawn unlit (the lighting model is constant, so
    /// this is the radiance before fog and the tone curve): the water's own
    /// colour, with the sky mirrored by Fresnel's law and the sun's glitter.
    ///
    /// Waves: two layers of the baked wind sea (cj_sea_detail.rgbz, slopes
    /// in RG), 32 m and 11 m across, drifting with the south-westerly
    /// breeze. As they shrink to under a pixel their slopes average out
    /// in the mip chain; that slope variance is kept as roughness, so the
    /// total stays Cox and Munk's 0.023 (a 4 m/s breeze) at every distance.
    /// Near the camera the glitter breaks into sparkles; far out it is a
    /// smooth silver path under the sun.
    ///
    /// Reflection: the sky above the horizon (cj_sea_sky.jpg, azimuth by
    /// u, 1 - sin(elevation) by v, stored at 1 / skyScale), mirrored by the
    /// wave facet, its elevation kept above 1.6 times the RMS slope (14
    /// degrees: the facets that face the eye on a rough sea mirror the
    /// higher, bluer sky, not the white haze band); the Fresnel term uses
    /// an effective angle that never gets fully grazing, because the far
    /// sea's facets lean towards the eye (its reflectance stays near 0.2,
    /// not the flat mirror's 0.9, so the far water stays blue under the
    /// haze: #889fba-#7c93b1 against the GoPro's #849abc-#6d88b2).
    ///
    /// Glitter: Beckmann facets of mean square slope m2, Schlick Fresnel
    /// for water (F0 0.02) and Smith masking (Walter et al. 2007's
    /// rational fit) for the level sea, lit by the sun's irradiance
    /// `seaK.x` (radiance of a white board facing the sun: `lightK.x` times
    /// the calibrated ambient, 4.8 x 0.454, times pi). Its path runs from
    /// under the sun to the horizon when the road points at it; rolled off
    /// above 0.6, its core still blooms.
    ///
    /// The water: deep Ligurian blue offshore, turquoise over the shallows
    /// within about 80 m of the rocks (look.md section 2: #4f8ea0 at Capo
    /// Verde), and, where the course's aerial photo of the sea covers it
    /// (the far grid's, `seaK.z` = 1), the photo's own colour near the
    /// coast: its shallows, weed beds and wash. A band of white water
    /// breaks along the shore itself.
    static let seaSurface = """
    #pragma arguments
    texture2d<float> seaWaves;
    texture2d<float> seaSky;
    texture2d<float> seaPhoto;
    float4 seaPhotoUV;
    float4 seaK;
    float3 lightSun;
    float exposureGain;
    float seaDebug;
    #pragma body
    constexpr sampler rep(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));
    constexpr sampler clp(filter::linear, mip_filter::linear, address::clamp_to_edge);
    constexpr sampler skySm(filter::linear, mip_filter::linear, s_address::repeat, t_address::clamp_to_edge);
    float2 p = in.wxz;
    // Towards the eye, from world positions: SceneKit doesn't set up
    // `_surface.view` for a constant-lit material (the far sea's
    // reflection broke into fine rings, and the glitter never showed).
    float3 V = normalize(scn_frame.inverseViewTransform[3].xyz - float3(p.x, in.wy, p.y));
    float t = scn_frame.time;
    // Two layers drifting north-east with the wind, the second turned 60
    // degrees and smaller: their slopes add (a sum of seas).
    float2 uvA = p * (1.0 / 32.0) + float2(0.026, -0.026) * t;
    float2 q = float2(0.5 * p.x - 0.866 * p.y, 0.866 * p.x + 0.5 * p.y);
    float2 uvB = q * (1.0 / 11.3) + float2(0.31, 0.77) + float2(0.03, -0.045) * t;
    float4 wA = seaWaves.sample(rep, uvA);
    float4 wB = seaWaves.sample(rep, uvB);
    float2 sB = wB.rg - 0.5;
    float2 s = ((wA.rg - 0.5) + 0.6 * float2(0.5 * sB.x + 0.866 * sB.y, -0.866 * sB.x + 0.5 * sB.y)) * 0.8575;
    // Texels per pixel of the larger layer: as the waves shrink below a
    // pixel their slopes go into the roughness instead (no moire).
    float fp = sqrt(length(dfdx(uvA)) * length(dfdy(uvA))) * 512.0;
    float lost = smoothstep(0.6, 6.0, fp);
    s *= 1.0 - lost;
    float m2 = 0.011 + 0.012 * lost;
    float3 n = normalize(float3(-s.x, 1.0, -s.y));
    float nv = saturate(dot(n, V));
    // Fresnel, with the far sea's facets leaning towards the eye.
    float nvE = sqrt(nv * nv + 3.5 * m2);
    float F = 0.02 + 0.98 * pow(1.0 - saturate(nvE), 5.0);
    float3 R = reflect(-V, n);
    R.y = max(R.y, 1.6 * sqrt(m2));
    R = normalize(R);
    float u = atan2(R.x, -R.z) * 0.15915494 + 1.0;
    float lod = 1.0 + 3.0 * lost;
    float3 sky = seaSky.sample(skySm, float2(u, 1.0 - R.y), level(lod)).rgb * \(SkyLighting.skyScale);
    // The water's own colour.
    float shore = in.shore;
    float3 deep = float3(0.020, 0.080, 0.230);
    float3 shallow = float3(0.040, 0.165, 0.200);
    float3 water = mix(deep, shallow, smoothstep(90.0, 12.0, shore));
    if (seaK.z > 0.5) {
        float2 puv = p * seaPhotoUV.xy + seaPhotoUV.zw;
        float2 pe = min(puv, 1.0 - puv);
        float inPhoto = smoothstep(0.0, 0.01, min(pe.x, pe.y));
        // Softened (mip bias 2.5, about 15 m): the photo's sun sparkle
        // and the hard seams between its mosaic tiles (a straight
        // pale strip along the coast east of Capo Verde) are not the
        // water's.
        float3 photo = seaPhoto.sample(clp, puv, bias(2.5)).rgb * seaK.w;
        // Not where the aerial camera caught the sun's glitter (grey
        // sheets off Capo Verde): water itself is never grey.
        float pMax = max(photo.r, max(photo.g, photo.b));
        float pSat = (pMax - min(photo.r, min(photo.g, photo.b))) / max(pMax, 1e-4);
        water = mix(water, photo, inPhoto * smoothstep(200.0, 40.0, shore) * smoothstep(0.3, 0.55, pSat));
    }
    // White water where the waves break on the rocks.
    float foam = smoothstep(9.0, 1.5, shore) * smoothstep(0.35, 0.8, wA.b * 0.7 + wB.b * 0.5);
    // The sun's glitter on the facets.
    float3 L = lightSun;
    float3 H = normalize(L + V);
    float nh = max(dot(n, H), 1e-3);
    float nh2 = nh * nh;
    float D = exp(-(1.0 - nh2) / (nh2 * m2)) / (3.14159265 * m2 * nh2 * nh2);
    float Fh = 0.02 + 0.98 * pow(1.0 - saturate(dot(V, H)), 5.0);
    float sm = sqrt(m2);
    float av = max(V.y, 1e-3) / (sm * sqrt(max(1.0 - V.y * V.y, 1e-6)));
    float al = max(L.y, 1e-3) / (sm * sqrt(max(1.0 - L.y * L.y, 1e-6)));
    float Gv = av < 1.6 ? (3.535 * av + 2.181 * av * av) / (1.0 + 2.276 * av + 2.577 * av * av) : 1.0;
    float Gl = al < 1.6 ? (3.535 * al + 2.181 * al * al) / (1.0 + 2.276 * al + 2.577 * al * al) : 1.0;
    float glint = D * Fh * Gv * Gl / (4.0 * max(V.y, 0.02)) * seaK.x;
    // Rolled off above 0.6 towards 1.15, as the sky bake rolls off the
    // glare round the sun: the path's core still blooms, its flanks keep
    // a gradient instead of clipping to a flat white sheet.
    glint = glint < 0.6 ? glint : 0.6 + (glint - 0.6) / (1.0 + (glint - 0.6) / 0.55);
    float3 c = water * (1.0 - F) + sky * F + glint * float3(1.0, 0.94, 0.86);
    c = mix(c, float3(0.95, 0.97, 0.98) * seaK.y, foam * 0.75);
    if (seaDebug > 0.5) { c = seaDebug > 1.5 ? float3(fp * 0.01, lost, F) : deep * 4.0; }
    if (seaDebug > 8.5) {
        // Four bands across the screen: water, reflection, glitter, the above.
        float4 clipP = scn_frame.projectionTransform * float4(_surface.position, 1.0);
        float sx = clipP.x / clipP.w;
        c = sx < -0.5 ? water * 3.0 : sx < 0.0 ? sky * F * 2.0 : sx < 0.5 ? float3(glint) : float3(fp * 0.01, lost, F * 2.0);
    }
    _surface.diffuse = float4(c * exposureGain, 1.0);
    """
}
