import SceneKit

/// Procedural setts (kasseien): the cobbled carriageway, the draped cobbled
/// side roads and the raised sett pavements.
extension WorldShaders {
    /// Setts: texcoord 0 = (lateral m, distance along the road m), texcoord
    /// 1 = (0 centre .. 1 edge, mud). Every mesh drawn with `settSurface`
    /// must carry both channels: without one SceneKit drops the modifiers
    /// silently and the road shows its plain diffuse, the joint grit (only
    /// the Simulator log says "Compiler error").
    static let settGeometry = """
    #pragma varyings
    float2 ruv;
    float2 rdat;
    #pragma body
    out.ruv = _geometry.texcoords[0];
    out.rdat = _geometry.texcoords[1];
    """

    /// `settGeometry` pulled towards the camera, as `drapedGeometry`.
    static let drapedSettGeometry = settGeometry + "\n" + """
    float3 cam = scn_frame.inverseViewTransform[3].xyz;
    float3 toCam = cam - _geometry.position.xyz;
    float dist = length(toCam);
    _geometry.position.xyz += toCam / max(dist, 0.001) * min(0.05 + dist * 0.002, 0.4);
    """

    /// Procedural setts, laid out per pixel from texcoord 0 = (lateral m,
    /// s m) so no stone ever repeats (a course's layout and colours recur
    /// only after 4096 courses, `SettFarMap`): wandering courses of
    /// jittered setts (`CourseArt.SettStyle`), each with its own rounded,
    /// chipped outline, domed and tilted crown, colour, joint widths and
    /// damage, and its own window of the bombed stone grain; split stones
    /// (`settSplit`) also fall short of their neighbours here and there and
    /// lose a corner. The joints' grit is the diffuse. Each domed stone
    /// shades its joint and its neighbour's shoulder from the sun
    /// (`microShadow`; the shadow map is far too coarse for that).
    /// Wheel-track polish, dust, damp, moss and the holle weg's mud as on
    /// the other paved surfaces (texcoord 1 = (edge, mud)). Where a course
    /// would be under about two pixels only the mean is drawn, from
    /// `SettFarMap` (`farTex`): the same stones filtered, so the far road
    /// keeps its courses, its stones' mottle and their joints. A course's
    /// layout and colour are keyed on its index from the
    /// climb's first sett course modulo the far map's 4096 courses (as the
    /// map has them), everything else on the index itself. See
    /// scripts/courses/textures/bake_setts.py for the other textures.
    static let settSurface = """
    #pragma arguments
    texture2d<float> grainTex;
    texture2d<float> macroTex;
    texture2d<float> farTex;
    float mudAmount;
    float settSeed;
    float4 settFar;
    float4 settLayout;
    float4 settJoint;
    float4 settShape;
    float4 settWear;
    float4 settMean;
    float4 settLod;
    float4 settSplit;
    float3 toSun;
    float microShadow;
    float grainNormal;
    \(lightArgs)
    #pragma declaration
    // lowbias32 (Wellons): one integer hash per lookup, four 8-bit draws each.
    static inline uint cjsHash(uint x) {
        x ^= x >> 16;
        x *= 0x7feb352du;
        x ^= x >> 15;
        x *= 0x846ca68bu;
        x ^= x >> 16;
        return x;
    }
    static inline float4 cjsUnit(uint h) {
        return float4((uint4(h) >> uint4(0u, 8u, 16u, 24u)) & 0xffu) * (1.0 / 255.0);
    }
    static inline uint cjsKey(float a, uint salt) {
        return cjsHash(uint(int(a)) * 0x9E3779B1u + salt);
    }
    // Boundary k between two courses, at lateral u, hashed on `key`:
    // jittered along the road, turning slowly from course to course, gently
    // wavy across it (SettFarMap.CourseEdge lays the map's the same way).
    // The strays (CourseArt.SettStyle.courseTurn, courseWave) must stay
    // under half a course: SettStyleTests.
    static inline float cjsCourseEdge(float k, float key, float u, float depth, float jitter, uint seed) {
        float4 r = cjsUnit(cjsKey(key, 0x2545F491u ^ seed));
        float tilt = 0.0045 * sin(key * 0.173 + 0.6) + 0.004 * (r.w - 0.5);
        return k * depth + depth * jitter * (r.x - 0.5) + tilt * u
             + 0.006 * (r.z - 0.5) * sin(u * (1.7 + 4.0 * r.w) + 6.2832 * r.y);
    }
    // Boundary m between two setts of the course hashed `hk`, `n` setts in
    // the far map's span (its layout repeats across the road from there),
    // at `d` metres from the course's middle line: jittered across the road
    // and skewed (CourseArt.SettStyle.settSkew).
    static inline float cjsSettEdge(float m, float n, uint hk, float d, float len, float off, float jitter) {
        float4 r = cjsUnit(cjsHash(hk ^ (uint(int(m - n * floor(m / n))) * 0x27D4EB2Fu)));
        return off + m * len + len * jitter * (r.x - 0.5) + 0.12 * (r.y - 0.5) * d;
    }
    #pragma body
    constexpr sampler rep(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));
    uint seed = uint(settSeed) * 0x01000193u;
    uint fseed = uint(settFar.w) * 0x01000193u;
    float2 p = in.ruv;                       // (lateral m, distance along the road m)
    float edge = saturate(in.rdat.x);
    float mud = in.rdat.y * mudAmount;
    float3 N0 = normalize(_surface.normal);
    float3 P = _surface.position;
    float3 dp1 = dfdx(P);
    float3 dp2 = dfdy(P);
    float du1 = dfdx(p.x);
    float du2 = dfdy(p.x);
    // Road frame from u alone: u stays within a few metres, so its derivatives
    // are exact, while s reaches 2.5 km, where a float steps 0.24 mm and its
    // derivatives would be noise close up. Ts = N0 x Tu points down the road.
    float3 Tu = cross(dp2, N0) * du1 + cross(N0, dp1) * du2;
    Tu -= N0 * dot(N0, Tu);
    Tu *= rsqrt(max(dot(Tu, Tu), 1e-24));
    float3 Ts = cross(N0, Tu);
    // Metres of (u, s) per pixel step in x and in y.
    float2 fx = float2(du1, dot(dp1, Ts));
    float2 fy = float2(du2, dot(dp2, Ts));
    float D0 = settLayout.x;
    float L0 = settLayout.y;
    float fpS = abs(fx.y) + abs(fy.y);
    // 0 where every sett is several pixels big; 1 once a course would be
    // under about two pixels, where only the mean is drawn.
    float lod = smoothstep(settLod.x, settLod.y, max(fpS / D0, (abs(fx.x) + abs(fy.x)) / L0));
    float3 V = normalize(-P);
    float vn = max(dot(V, N0), 0.03);
    float2 vt = float2(dot(V, Tu), dot(V, Ts));
    // The sun in the road frame: its horizontal direction, and how far its
    // ray runs across the road for each metre it rises.
    float3 sunV = normalize((scn_frame.viewTransform * float4(toSun, 0.0)).xyz);
    float2 l2 = float2(dot(sunV, Tu), dot(sunV, Ts));
    float lh = length(l2);
    float2 lu = l2 / max(lh, 1e-4);
    float cotE = lh / max(dot(sunV, N0), 0.02);

    // Courses across the road: their depth drifts by up to about 15 % over
    // tens of metres.
    float sw = p.y + 0.9 * sin(p.y * 0.071 + 1.3) + 0.45 * sin(p.y * 0.213 + 0.4);
    // The far map: two rows per course, `settFar.y` courses (this surface's
    // course 0 is the map's `settFar.z`), `settFar.x` metres across.
    // Filtered over the pixel's footprint in (u, s), so the far road keeps
    // its stones, joints and courses and fades to their mean before it could
    // shimmer.
    constexpr sampler aniso(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(16));
    float2 fsc = float2(1.0 / settFar.x, 1.0 / (D0 * settFar.y));
    float4 fm = farTex.sample(aniso, float2(p.x * fsc.x + 0.5, (sw / D0 + settFar.z + 0.25) / settFar.y),
                              gradient2d(fx * fsc, fy * fsc));

    // Macro, at every distance. A (6.1 m across x 14.3 m along, slid sideways
    // along the road so its repeats never line up): slope of a gentle
    // unevenness, wear noise, the unevenness height. B (41 m): damp and
    // stone-batch noise.
    float4 mA = macroTex.sample(rep, p * float2(0.164, 0.0699) + float2(0.13 + 0.31 * sin(p.y * 0.0091), 0.71));
    float4 mB = macroTex.sample(rep, p * 0.0242 + float2(0.57 + 0.2 * sin(p.y * 0.0037), 0.29));
    float2 slopeM = (mA.rg - 0.5) * 0.25 * settLod.z;
    float wearN = mA.b;
    float lowN = mA.a;
    float dampN = mB.b;
    // Clusters of lighter and darker setts are in the far map's colours.
    float batch = 1.0 + (mB.a - 0.5) * 0.16;

    // Wheel tracks (clean, polished crowns), dust between and outside them,
    // damp in the holle weg's hollows, dirt, moss and grass towards the edges.
    float halfW = edge > 0.02 ? abs(p.x) / edge : 4.0;   // edge = |u| / half width
    float trackU = min(settWear.x, 0.55 * halfW);
    float track = (1.0 - smoothstep(0.3, 1.0, abs(abs(p.x) - trackU) / settWear.y)) * (0.5 + 0.5 * wearN);
    float damp = saturate(mud * (0.5 + 0.6 * dampN + 0.5 * (0.5 - lowN)) + (dampN - 0.8) * 1.5);
    float edgeDirt = smoothstep(0.6, 1.0, edge + 0.3 * (wearN - 0.5));
    float dust = saturate((0.2 + 0.8 * wearN) * (1.0 - track)) * (1.0 - damp);
    float mossy = saturate((0.8 * edgeDirt + 0.25 * (1.0 - track)) * (0.2 + damp + 0.6 * smoothstep(0.55, 0.85, dampN)));
    float grassy = edgeDirt * (1.0 - mud) * smoothstep(0.45, 0.75, wearN);

    // Joint fill: the baked grit (the diffuse, tiled), soil, moss, grass.
    float3 sand = _surface.diffuse.rgb;
    float3 soil = float3(0.048, 0.038, 0.026) * (0.8 + 0.4 * lowN);
    float3 jointC = mix(sand, soil, saturate(0.7 * edgeDirt + 0.6 * damp));
    jointC = mix(jointC, float3(0.026, 0.045, 0.014) * (0.7 + 0.6 * dampN), mossy * 0.85);
    jointC = mix(jointC, float3(0.055, 0.095, 0.024), grassy * 0.7);
    float3 dustC = sand * 1.15;

    // The mean surface, drawn alone far away: the far map's stones (their
    // shoulders darkened) and its joints, between courses and between
    // setts, and the rounded corners' share (settMean.y); at grazing angles
    // the stone in front hides a joint's floor (most of those between
    // courses: settMean.x is their share of the joints) and its far flank
    // shows instead. settMean.z: the domes' shading, which the flat mean
    // cannot show; settMean.w: the stones' ambient occlusion (the two
    // calibrated so near and far match in sun and in shade).
    float jAll = min(fm.a + settMean.y, 1.0);
    float3 stoneU = fm.rgb * (batch * settMean.z / 3.5) / max(1.0 - fm.a, 0.3);   // SettFarMap.colourScale
    stoneU = mix(stoneU, dustC, dust * 0.3);
    stoneU *= 1.0 - 0.1 * track * settWear.z;
    float visT = saturate(1.0 - settJoint.z * abs(vt.y) / vn);
    float visL = saturate(1.0 - settJoint.z * abs(vt.x) / vn);
    float jVis = jAll * mix(visL, visT, settMean.x);
    float jHid = jAll - jVis;
    float3 alb = stoneU * (1.0 - jAll + 0.62 * jHid) + jointC * jVis;
    float rough = mix(mix(0.82, 0.6, track * settWear.z), 0.95, jVis);
    float hN = 0.55;
    float ao = mix(settMean.w, 0.35, jAll);
    float2 nxy = float2(0.0);
    // The stones' own sun shadows fall in and beside their joints
    // (settJoint.w of the surface per unit of joint share).
    float sunOcc = settJoint.w * jAll;

    if (lod < 0.999) {
        // The course this pixel lies in: no boundary strays more than half a
        // course from its nominal place, so three cover it.
        float kf = floor(sw / D0);
        float kz = settFar.z;
        float b0 = cjsCourseEdge(kf, kf + kz, p.x, D0, settLayout.z, fseed);
        float b1 = cjsCourseEdge(kf + 1.0, kf + kz + 1.0, p.x, D0, settLayout.z, fseed);
        bool below = sw < b0;
        bool above = sw >= b1;
        float kx = below ? kf - 1.0 : kf + 2.0;
        float bx = cjsCourseEdge(kx, kx + kz, p.x, D0, settLayout.z, fseed);
        float kc = below ? kf - 1.0 : (above ? kf + 1.0 : kf);
        float bLo = below ? bx : (above ? b1 : b0);
        float bHi = below ? b0 : (above ? bx : b1);
        // Setts along the course: its batch length and stagger, hashed on
        // its course of the far map (kw), which lays them out the same way.
        float kn = kc + kz;
        float kw = kn - settFar.y * floor(kn / settFar.y);
        uint hk = cjsKey(kw, 0x68E31DA4u ^ fseed);
        float4 rk = cjsUnit(hk);
        float Nk = max(round(settFar.x / (L0 * (0.88 + 0.24 * rk.x))), 1.0);
        float Lk = settFar.x / Nk;
        float ok = rk.y * Lk;
        float cMid = 0.5 * (bLo + bHi);
        float dmid = sw - cMid;
        float mf = floor((p.x - ok) / Lk);
        float c0 = cjsSettEdge(mf, Nk, hk, dmid, Lk, ok, settLayout.w);
        float c1 = cjsSettEdge(mf + 1.0, Nk, hk, dmid, Lk, ok, settLayout.w);
        bool left = p.x < c0;
        bool right = p.x >= c1;
        float cx = cjsSettEdge(left ? mf - 1.0 : mf + 2.0, Nk, hk, dmid, Lk, ok, settLayout.w);
        float mc = left ? mf - 1.0 : (right ? mf + 1.0 : mf);
        float cLo = left ? cx : (right ? c1 : c0);
        float cHi = left ? c0 : (right ? cx : c1);
        float cu = 0.5 * (cLo + cHi);
        float hu = 0.5 * (cHi - cLo);
        float hs = 0.5 * (bHi - bLo);
        float2 q = float2(p.x - cu, dmid);

        // This sett: its joints hashed on its course and place in the far
        // map, as the map has them (h1; its colour is the map's texel); its
        // shape on its own course index and place, so no stone repeats (hv,
        // stretched to 128 bits by LCG steps).
        uint mk = uint(int(mc)) * 0x165667B1u;
        uint h1 = cjsHash(hk ^ (uint(int(mc - Nk * floor(mc / Nk))) * 0x165667B1u) ^ 0x9E3779B9u);
        uint h2 = h1 * 747796405u + 2891336453u;
        h2 ^= h2 >> 13;
        uint hv = cjsHash(cjsKey(kn, 0x7A3B9C5Du ^ seed) ^ mk);
        uint hv2 = hv * 747796405u + 2891336453u;
        hv2 ^= hv2 >> 13;
        uint hv3 = hv2 * 747796405u + 2891336453u;
        hv3 ^= hv3 >> 13;
        float4 r1 = cjsUnit(hv);    // crown height, damage, dome, grain scale
        float4 r2 = cjsUnit(hv2);   // grain offset x, y; tilt across, along
        float4 r3 = cjsUnit(h2);    // joint left, right, below, above
        float4 r4 = cjsUnit(hv3);   // shoulder, burial; grain flip and turn (top bits)

        // A relaid band (a trench reinstated across the road, or half of it)
        // in some 250 m sections, at most one each: a fresh batch within 8 %
        // of the stones around it, tighter joints, sharper arrises.
        float sec = floor(cMid / 250.0);
        float4 rq = cjsUnit(cjsKey(sec, 0x51ED270Bu ^ seed));
        float bandS = sec * 250.0 + 5.0 + 240.0 * rq.x;
        float sideOK = rq.z < 0.5 ? 1.0 : step(-0.05, rq.z < 0.75 ? cu : -cu);
        float relaid = step(rq.w, settWear.w * 16.0) * step(bandS, cMid) * step(cMid, bandS + 0.6 + 2.2 * rq.y) * sideOK;
        float bandV = fract(rq.x * 61.0 + rq.y * 17.0);
        float missing = step(r1.y, settWear.w * 0.1) * (1.0 - relaid);
        float sunk = (step(r1.y, settWear.w) - missing) * (1.0 - relaid);

        // Rounded-rectangle outline from the four jittered edges (joint half
        // widths per side, most narrow, a few wide, and split stones short
        // of their neighbours: settSplit.x), inside distance `ins` and its
        // gradient in (u, s).
        float4 r3s = r3 * r3;
        float4 jws = (mix(float4(settJoint.x), float4(settJoint.y), r3s) + settSplit.x * r3s * r3s) * (1.0 - 0.45 * relaid) + 0.003 * sunk;
        float eU0 = (p.x - cLo) - jws.x;
        float eU1 = (cHi - p.x) - jws.y;
        float eS0 = (sw - bLo) - jws.z;
        float eS1 = (bHi - sw) - jws.w;
        float ex = min(eU0, eU1);
        float ey = min(eS0, eS1);
        // Each corner rounded its own way: worn loaves, not moulded pavers.
        uint hv4 = hv3 * 747796405u + 2891336453u;
        hv4 ^= hv4 >> 13;
        float4 r5 = cjsUnit(hv4);
        float rCorner = eU0 < eU1 ? (eS0 < eS1 ? r5.x : r5.y) : (eS0 < eS1 ? r5.z : r5.w);
        float rc = settShape.w * (0.2 + 0.9 * rCorner) * (1.0 - 0.5 * relaid);
        float2 qq = float2(rc - ex, rc - ey);
        float2 qp = max(qq, 0.0);
        float lq = length(qp);
        float ins = rc - lq - min(max(qq.x, qq.y), 0.0);
        float2 gIns = lq > 1e-6 ? qp / lq : (qq.x > qq.y ? float2(1.0, 0.0) : float2(0.0, 1.0));
        // Split stones lose a corner here and there: cut straight across,
        // up to settSplit.y along each edge (none where it is 0).
        float chipR = fract(rCorner * 31.0);
        float insC = (ex + ey - settSplit.y * chipR * chipR) * 0.70711;
        bool chipped = insC < ins;
        ins = chipped ? insC : ins;
        gIns = chipped ? float2(0.70711) : gIns;
        gIns *= float2(eU0 < eU1 ? 1.0 : -1.0, eS0 < eS1 ? 1.0 : -1.0);
        float jNear = ex < ey ? (eU0 < eU1 ? jws.x : jws.y) : (eS0 < eS1 ? jws.z : jws.w);

        // Stone grain, bombed: this sett's own offset, one of 8 flips and turns,
        // and scale, so no two setts share a face and the texture's seams fall
        // in the joints. Explicit gradients: q jumps at every joint.
        uint dih = hv3 >> 29;
        float gsc = settLod.w * (0.85 + 0.3 * r1.w);
        bool swp = (dih & 1u) != 0u;
        float2 sg = float2((dih & 2u) != 0u ? -1.0 : 1.0, (dih & 4u) != 0u ? -1.0 : 1.0);
        float2 tq = (swp ? q.yx : q) * sg * gsc;
        float2 tgx = (swp ? fx.yx : fx) * sg * gsc;
        float2 tgy = (swp ? fy.yx : fy) * sg * gsc;
        float4 g = grainTex.sample(rep, tq + r2.xy, gradient2d(tgx, tgy));
        float2 gn = (g.rg * 2.0 - 1.0) * sg;
        gn = swp ? gn.yx : gn;
        ins += (g.a - 0.5) * settSplit.z * (1.0 - 0.6 * relaid);   // split, chipped outlines

        // Height above the fill (m): a domed, tilted crown on a rounded shoulder.
        float crownH = settShape.x * (0.65 + 0.7 * r1.x) * (1.0 - 0.6 * sunk) * (1.0 - 0.35 * relaid);
        float dome = settShape.y * (0.5 + fract(r1.z * 7.0));
        float2 inv = 1.0 / max(float2(hu, hs), 0.03);
        float2 nq = q * inv;
        float2 tilt = (r2.zw - 0.5) * 2.0 * settShape.z * (1.0 + 2.0 * sunk);
        float crown = crownH * (1.0 - 0.5 * dome * dot(nq, nq)) + dot(tilt, nq);
        float2 dCrown = (tilt - crownH * dome * nq) * inv;
        float R = (0.012 + 0.6 * settShape.w * r4.x) * (1.0 - 0.4 * relaid);
        float e = saturate(ins / R);
        float prof = 1.0 - (1.0 - e) * (1.0 - e);
        float dProf = (ins > 0.0 && ins < R) ? 2.0 * (1.0 - e) / R : 0.0;
        // Setts at the very edge sink under the verge's soil.
        float bury = smoothstep(0.82, 1.0, edge + 0.14 * (r4.y - 0.5));
        float keep = (1.0 - bury) * (1.0 - missing);
        float hStone = prof * crown * keep;
        float2 dh = (dProf * crown * gIns + prof * dCrown) * keep;
        float hD = saturate(hStone / max(settShape.x * 1.35, 1e-3));

        // Joint coverage: the pixel footprint's share of the joint band (box
        // filter across it), then how much of the joint floor shows past the
        // stone in front at this viewing angle.
        float hwF = 0.5 * (abs(dot(gIns, fx)) + abs(dot(gIns, fy))) + 1e-5;
        float t = max(ins + jNear, 0.0);
        float cj = saturate((min(t + hwF, jNear) - max(t - hwF, -jNear)) / (2.0 * hwF));
        cj = max(cj, missing);
        float vis = mix(saturate(1.0 - settJoint.z * abs(dot(vt, gIns)) / vn), 1.0, missing);

        // Sun shadows of the domes: this sett's own (on its joint, when the
        // sett lies towards the sun) or the neighbour's across the nearest
        // joint (on the joint and this sett's shoulder). A rounded shoulder
        // casts from below its crown (0.6-0.65 of it), so a wide joint
        // keeps a strip of sunlit grit; the neighbour's crown is the style's
        // mean: it is not evaluated.
        float gl = dot(gIns, lu);
        float hEdge = crownH * keep * 0.6;
        float soft = 0.0015 + hwF / max(cotE, 0.3);
        float sOwn = (gl > 0.02 && ins < 0.0) ? smoothstep(-soft, soft, hEdge + ins / (gl * cotE)) : 0.0;
        float sNb = gl < -0.02 ? smoothstep(-soft, soft, settShape.x * 0.65 - hStone - max(ins + 2.0 * jNear, 0.0) / (-gl * cotE)) : 0.0;
        float occD = max(sOwn, sNb) * (1.0 - missing) * (1.0 - bury);

        // Colour: the far map's texel at this sett's centre, in its course's
        // middle row (its stone family, lightness, hue and course), the
        // grain, grime at the arrises, dust in the low parts, polish on
        // crowns in the wheel tracks.
        constexpr sampler pt(filter::nearest, address::repeat);
        float4 fc = farTex.sample(pt, float2(cu * fsc.x + 0.5, (kw + 0.75) / settFar.y), level(0.0));
        float3 stone = fc.rgb * (batch / 3.5) / max(1.0 - fc.a, 0.25);
        stone *= 1.0 + relaid * (0.16 * bandV - 0.08);
        stone *= 1.0 + settSplit.w * (g.b - 0.5);
        stone *= 0.82 + 0.18 * prof;
        stone = mix(stone, dustC, dust * (0.45 - 0.3 * hD) * (1.0 - 0.5 * relaid));
        stone *= 1.0 - 0.12 * track * settWear.z * hD;
        float3 jc = mix(jointC, soil * 1.1, 0.5 * missing);
        float3 albD = mix(stone, mix(stone * 0.62, jc, vis), cj);
        albD = mix(albD, soil, 0.8 * bury);
        // Rough crowns (0.72-0.85); polish only in the wheel tracks.
        float roughD = 0.785 + 0.1 * (g.a - 0.5) + 0.06 * (r1.w - 0.5);
        roughD = mix(roughD, 0.5, track * settWear.z * hD * (1.0 - relaid));
        roughD = mix(roughD, 0.95, cj);

        alb = mix(albD, alb, lod);
        rough = mix(roughD, rough, lod);
        hN = mix(hD, hN, lod);
        ao = mix((0.7 + 0.3 * prof) * (1.0 - 0.5 * cj * (1.0 - 0.5 * missing)), ao, lod);
        sunOcc = mix(occD, sunOcc, lod);
        nxy = (gn * (0.5 * grainNormal) * (1.0 - cj) - dh) * (settLod.z * (1.0 - lod));
    }

    // Damp darkens and adds a sheen. Mud (the holle weg) fills the joints
    // first, then creeps over the stones towards the edges.
    alb *= (1.0 - 0.3 * damp) * (1.0 - 0.15 * edgeDirt);
    rough = mix(rough, 0.5, 0.5 * damp);
    float patchy = saturate(0.8 * dampN + 0.6 * (1.0 - lowN));
    float m = mud * (smoothstep(0.62, 1.0, edge) * 0.85 + 0.1) * (0.55 + 0.9 * patchy);
    float fill = smoothstep(0.15, 0.6, m - hN * 0.55);
    alb = mix(alb, float3(0.062, 0.048, 0.03) * (0.85 + 0.3 * wearN), 0.9 * fill);
    rough = mix(rough, 0.38, fill);
    nxy = nxy * (1.0 - 0.7 * fill) - slopeM;
    float3 nF = normalize(N0 + Tu * nxy.x + Ts * nxy.y);
    // The light raster (`WorldShaders+Light`): its sun visibility switches
    // the stones' sun shadows off in the shade of trees, banks and houses.
    float3 lgtP = (scn_frame.inverseViewTransform * float4(P, 1.0)).xyz;
    \(lightFetch)
    // The stones' sun shadows, diffuse-exact for a sunlit pixel:
    // (sky + k NL (1 - occ)) / (sky + k NL), k the sun-to-sky ratio where
    // the raster sees the sun. The raster holds only the static shade
    // (terrain, trees, houses): in the shadow map's own shadows (the rider,
    // poles, signs) the joints stay darkened as in sun, up to about half
    // too dark. The surface stage can't read the shadow map, and there it
    // reads as deeper joints.
    float kNL = microShadow * lgtQ.g * saturate(dot(nF, sunV));
    alb *= (1.0 + kNL * (1.0 - sunOcc * (1.0 - fill))) / (1.0 + kNL);
    // Specular anti-aliasing: the normal's spread over the pixel widens the
    // highlight (GGX alpha = roughness squared), so domes don't sparkle.
    float3 dnx = dfdx(nF);
    float3 dny = dfdy(nF);
    float a2 = rough * rough;
    a2 *= a2;
    a2 = saturate(a2 + min(0.5 * (dot(dnx, dnx) + dot(dny, dny)), 0.18));
    // Sky occlusion and the sun's shade beyond the shadow map.
    float3 lgtN = normalize((scn_frame.inverseViewTransform * float4(N0, 0.0)).xyz);
    float lgtD = -P.z;
    \(lightApply)
    _surface.diffuse = float4(alb, 1.0);
    _surface.roughness = sqrt(sqrt(a2));
    _surface.ambientOcclusion *= ao;
    _surface.normal = nF;
    """
}
