import Foundation
import simd

/// Procedural tree models at a reference size, scaled per tree when placed.
/// Each has a full version (trunk, limbs, leaf cards on the crown's lobes),
/// a light version for the middle distance and an impostor cell in
/// cj_impostor.png.
///
/// Mesh parts: 0 = bark, 1 = leaves. Texture channel 1 carries the wind
/// sway weight (x; y is the per-tree phase, filled in at placement),
/// channel 2 the leaf shading (x = ambient occlusion; y = the per-tree
/// colour, filled in at placement, see `WorldShaders.shadeDecode`) and
/// channel 3 a billboard card's corner offset.
struct TreeArchetype {
    /// Crown forms: a species and the way it grew, in the open or drawn up
    /// in a wood with a clean bole.
    enum Form: Int, CaseIterable {
        case beech, beechForest, oak, oakForest, ash, sycamore, hybridPoplar, lombardy, willow, conifer, orchard, copperBeech
    }

    /// A sub-crown of 1.5 to 4 m fed by one limb.
    struct Lobe {
        var c: SIMD3<Float>
        var r: Float
    }

    let form: Form
    let refHeight: Float
    let refRadius: Float
    var full: MeshBuffer
    var light: MeshBuffer
    /// The crown's lobes (empty for the conifer and the Lombardy column).
    var lobes: [Lobe] = []
    /// Height where the leaves begin.
    var crownBase: Float = 0
    /// Where each limb, branch or whip ends (each should end in leaves).
    var limbTips: [SIMD3<Float>] = []

    /// Leaf-card atlas quadrants (u0, v0, u1, v1) in cj_foliage.png.
    static let broadUV: SIMD4<Float> = SIMD4(0.005, 0.005, 0.495, 0.495)
    static let poplarUV: SIMD4<Float> = SIMD4(0.505, 0.005, 0.995, 0.495)
    static let ivyUV: SIMD4<Float> = SIMD4(0.005, 0.505, 0.495, 0.995)
    static let needleUV: SIMD4<Float> = SIMD4(0.505, 0.505, 0.995, 0.995)

    /// Hexagons round each quadrant's leaves (alpha over 0.3, a texel to
    /// spare), in card units: -1...1 over the quadrant's inset uv rect
    /// above, as `card` maps it, x right, y up, anticlockwise. A hexagon
    /// card covers 55-62 % of the square, so about 40 % fewer fragments are
    /// shaded only to be discarded, for two more triangles. Fitted to
    /// today's cj_foliage.png by scripts/courses/textures/fit_hulls.py,
    /// which a re-baked atlas needs run again (with the core texels below);
    /// `TreeArchetypeTests` checks both against the bundled atlas.
    static let broadHull: [SIMD2<Float>] = [
        SIMD2(0.517, 0.767), SIMD2(-0.763, 0.599), SIMD2(-0.975, 0.087),
        SIMD2(-0.145, -0.996), SIMD2(0.456, -0.917), SIMD2(0.930, 0.228),
    ]
    static let poplarHull: [SIMD2<Float>] = [
        SIMD2(0.299, 0.878), SIMD2(-0.891, 0.445), SIMD2(-0.991, -0.123),
        SIMD2(0.028, -0.978), SIMD2(0.577, -0.778), SIMD2(0.795, 0.461),
    ]
    static let ivyHull: [SIMD2<Float>] = [
        SIMD2(-0.083, 0.981), SIMD2(-0.835, 0.631), SIMD2(-0.916, -0.295),
        SIMD2(-0.025, -0.919), SIMD2(0.897, -0.488), SIMD2(0.962, 0.250),
    ]

    /// A leaf deep in each quadrant (a texel's centre) whose 7 x 7 texels
    /// are opaque and even in colour, at the 35th percentile of the
    /// quadrant's leaf brightness: a clipped hedge's core puts every
    /// texture coordinate here (`VegetationBuilder.buildHedges`), so it is
    /// drawn in that leaf's colour, never cut, at any distance.
    static let broadCore = SIMD2<Float>(0.2466, 0.1489)
    static let poplarCore = SIMD2<Float>(0.7681, 0.2583)
    static let ivyCore = SIMD2<Float>(0.1909, 0.5776)

    static func core(for uv: SIMD4<Float>) -> SIMD2<Float> {
        if uv == poplarUV { return poplarCore }
        if uv == ivyUV { return ivyCore }
        return broadCore
    }

    static func hull(for uv: SIMD4<Float>) -> [SIMD2<Float>]? {
        if uv == broadUV { return broadHull }
        if uv == poplarUV { return poplarHull }
        if uv == ivyUV { return ivyHull }
        return nil
    }

    /// Every form's archetypes, and their lane-side variants.
    static func makeAll() -> [TreeArchetype] {
        Form.allCases.flatMap { f in
            (0..<f.variants).flatMap { v in [make(f, variant: v), make(f, variant: v, towardsLane: true)] }
        }
    }

    /// One archetype of a form. `towardsLane` grows the crown's lobes
    /// towards +x (phototropism over a sunken lane): those on that side are
    /// larger, and the whole crown leans that way.
    static func make(_ form: Form, variant: Int, towardsLane: Bool = false) -> TreeArchetype {
        let seed = UInt64(form.rawValue * 16 + variant + 1) &* 7919
        switch form {
        case .lombardy: return lombardy(seed: seed, towardsLane: towardsLane)
        case .willow: return willow(seed: seed)
        case .conifer: return conifer(seed: seed)
        default: return lobed(form.spec!, form: form, seed: seed, towardsLane: towardsLane)
        }
    }

    // MARK: - Geometry helpers

    /// Tapered tube from `a` to `b` (bark, part 0).
    static func tube(_ m: inout MeshBuffer, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ r0: Float, _ r1: Float,
                     sides: Int, height: Float, vStart: Float = 0, baseY: Float = 0) {
        let axis = b - a
        let len = simd_length(axis)
        guard len > 1e-4 else { return }
        let dir = axis / len
        let ref: SIMD3<Float> = abs(dir.y) < 0.95 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let u = simd_normalize(simd_cross(ref, dir))
        let w = simd_cross(dir, u)
        let first = UInt32(m.vertexCount)
        for ring in 0...1 {
            let p = ring == 0 ? a : b
            let r = ring == 0 ? r0 : r1
            for k in 0...sides {
                let ang = Float(k) / Float(sides) * 2 * .pi
                let n = u * cos(ang) + w * sin(ang)
                let q = p + n * r
                m.vertex(q.x, q.y, q.z, n.x, n.y, n.z, Float(k) / Float(sides), vStart + Float(ring) * len * 0.5)
                let sway = swayWeight(y: q.y - baseY, height: height)
                m.texcoord2(sway, 0)
                m.texcoord3(1, 0)
                m.texcoord4(0, 0)
            }
        }
        for k in 0..<sides {
            let a0 = first + UInt32(k), a1 = a0 + 1
            let b0 = first + UInt32(sides + 1 + k), b1 = b0 + 1
            m.tri(a0, a1, b0, part: 0)
            m.tri(a1, b1, b0, part: 0)
        }
    }

    /// Tapering limb along a quadratic Bezier from `a` (radius `r0`)
    /// towards control point `c` to `b` (radius `r1`) (bark, part 0). The
    /// rings follow the curve, so the limb bends instead of kinking.
    static func limb(_ m: inout MeshBuffer, _ a: SIMD3<Float>, _ c: SIMD3<Float>, _ b: SIMD3<Float>,
                     _ r0: Float, _ r1: Float, sides: Int, segments: Int, height: Float, baseY: Float = 0) {
        var pts: [SIMD3<Float>] = []
        for i in 0...segments {
            let t = Float(i) / Float(segments), u = 1 - t
            pts.append(a * (u * u) + c * (2 * u * t) + b * (t * t))
        }
        let first = UInt32(m.vertexCount)
        var side = SIMD3<Float>.zero
        var v: Float = 0
        for i in 0...segments {
            let lo = pts[max(i - 1, 0)], hi = pts[min(i + 1, segments)]
            let axis = hi - lo
            guard simd_length(axis) > 1e-5 else { return }
            let dir = simd_normalize(axis)
            // Carry the ring's frame along the curve (no twist).
            if i == 0 {
                let ref: SIMD3<Float> = abs(dir.y) < 0.95 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
                side = simd_normalize(simd_cross(ref, dir))
            } else {
                side = simd_normalize(side - dir * simd_dot(side, dir))
                v += simd_length(pts[i] - pts[i - 1]) * 0.5
            }
            let w = simd_cross(dir, side)
            let t = Float(i) / Float(segments)
            let r = r0 + (r1 - r0) * t.squareRoot()
            for k in 0...sides {
                let ang = Float(k) / Float(sides) * 2 * .pi
                let n = side * cos(ang) + w * sin(ang)
                let q = pts[i] + n * r
                m.vertex(q.x, q.y, q.z, n.x, n.y, n.z, Float(k) / Float(sides), v)
                m.texcoord2(swayWeight(y: q.y - baseY, height: height), 0)
                m.texcoord3(1, 0)
                m.texcoord4(0, 0)
            }
        }
        let ring = UInt32(sides + 1)
        for i in 0..<UInt32(segments) {
            for k in 0..<UInt32(sides) {
                let a0 = first + i * ring + k, a1 = a0 + 1
                let b0 = a0 + ring, b1 = b0 + 1
                m.tri(a0, a1, b0, part: 0)
                m.tri(a1, b1, b0, part: 0)
            }
        }
    }

    /// Sway grows with height above the ground; roughly 1 at the top of a
    /// 14 m tree.
    @inline(__always)
    static func swayWeight(y: Float, height: Float) -> Float {
        let t = max(y, 0) / max(height, 1)
        return t * t * (height / 14)
    }

    /// One leaf card (part 1). `normal` faces outward; normals are bent away
    /// from the crown centre so a crown shades like a volume. Billboard
    /// cards keep all their corners at the centre and carry their (rolled)
    /// corner offsets in texture channel 3; the wind shader turns them to
    /// face the viewer, so a crown never shows a card edge-on. `mirror`
    /// flips the cell left to right (the same leaves, another outline);
    /// `hull` (see `broadHull`) trims the square to the cell's leaves.
    static func card(_ m: inout MeshBuffer, centre c: SIMD3<Float>, size: Float, normal: SIMD3<Float>,
                     roll: Float, uv: SIMD4<Float>, crownCentre: SIMD3<Float>, crownRadii: SIMD3<Float>,
                     height: Float, ao: Float, bend: Float = 0.75, aspect: Float = 1, baseY: Float = 0,
                     billboard: Bool = true, mirror: Bool = false, hull: [SIMD2<Float>]? = nil) {
        let n = simd_normalize(normal)
        let ref: SIMD3<Float> = abs(n.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        var right = simd_normalize(simd_cross(ref, n))
        var up = simd_cross(n, right)
        let cr = cos(roll), sr = sin(roll)
        let r2 = right * cr + up * sr
        up = -right * sr + up * cr
        right = r2
        let hx = size / 2 * aspect, hy = size / 2
        // Points in the cell (x right, y up), then on the card: mirrored,
        // the card shows the cell's x at -x, so the polygon flips with it.
        let cell: [SIMD2<Float>] = hull ?? [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1)]
        let first = UInt32(m.vertexCount)
        let count = cell.count
        for k in 0..<count {
            let t = cell[mirror ? count - 1 - k : k]
            let sx = mirror ? -t.x : t.x, sy = t.y
            let u = uv.x + (uv.z - uv.x) * (t.x + 1) / 2
            let v = uv.w + (uv.y - uv.w) * (t.y + 1) / 2
            let corner = c + right * (sx * hx) + up * (sy * hy)
            let p = billboard ? c : corner
            var out = (corner - crownCentre) / crownRadii
            if simd_length(out) < 1e-3 { out = n }
            let bn = simd_normalize(n * (1 - bend) + simd_normalize(out) * bend)
            m.vertex(p.x, p.y, p.z, bn.x, bn.y, bn.z, u, v)
            m.texcoord2(swayWeight(y: corner.y - baseY, height: height), 0)
            let depth = simd_length((corner - crownCentre) / crownRadii)
            let shade = ao * (0.55 + 0.45 * min(depth, 1)) * (0.8 + 0.2 * min(max((corner.y - crownCentre.y) / crownRadii.y * 0.5 + 0.5, 0), 1))
            m.texcoord3(shade, 0)
            if billboard {
                // Screen-space offset: x right, y up, rolled.
                let ox = sx * hx, oy = sy * hy
                m.texcoord4(ox * cr - oy * sr, ox * sr + oy * cr)
            } else {
                m.texcoord4(0, 0)
            }
        }
        for k in 1..<UInt32(count - 1) {
            m.tri(first, first + k, first + k + 1, part: 1)
        }
    }

    static func randomDir(_ r: inout WorldRandom, minY: Float = -1) -> SIMD3<Float> {
        while true {
            let v = SIMD3(r.range(-1, 1), r.range(-1, 1), r.range(-1, 1))
            let l = simd_length(v)
            if l > 0.05, l <= 1, v.y / l >= minY { return v / l }
        }
    }

    /// Share of 12 upper-hemisphere directions in which `p` sees past every
    /// lobe: the crown's ambient occlusion at a leaf, 0.45 to 1.
    static func skyVisibility(_ p: SIMD3<Float>, lobes: [Lobe]) -> Float {
        var open = 0
        for k in 0..<12 {
            let az = Float(k) * 0.5236, el: Float = k % 2 == 0 ? 0.45 : 1.05
            let d = SIMD3(cos(az) * cos(el), sin(el), sin(az) * cos(el))
            let blocked = lobes.contains { l in
                let oc = p - l.c, b = simd_dot(oc, d), c = simd_dot(oc, oc) - l.r * l.r
                // From outside, a hit ahead; from inside, more than 0.4 r of it to cross.
                return c > 0 ? (b < 0 && b * b > c) : (-b + (b * b - c).squareRoot() > 0.4 * l.r)
            }
            if !blocked { open += 1 }
        }
        return 0.45 + 0.55 * Float(open) / 12
    }

    /// Mean leaf shading (texture channel 2's x) of the vertices from
    /// `first` on; nil when there are none.
    static func meanShade(_ m: MeshBuffer, from first: Int) -> Float? {
        guard m.vertexCount > first else { return nil }
        var sum: Float = 0
        for k in first..<m.vertexCount { sum += m.uv3[2 * k] }
        return sum / Float(m.vertexCount - first)
    }

    /// Height of the full version's lowest leaf above the trunk base, as
    /// placed with these scales (`VegetationBuilder.appendPlant`), for a
    /// camera looking level: a billboard card reaches its centre's height
    /// less its corner's height on screen. `laneSide` counts only the
    /// leaves on +x, the side a lane-side crown turns to the road.
    func lowestLeaf(laneSide: Bool, sy: Float, cardScale: Float) -> Float {
        var low = Float.infinity
        for i in full.parts[1] {
            let k = Int(i)
            guard !laneSide || full.positions[3 * k] > 0 else { continue }
            low = min(low, full.positions[3 * k + 1] * sy + full.uv4[2 * k + 1] * cardScale)
        }
        return low
    }

    // MARK: - Lobed broadleaf crowns

    /// How a broadleaf form's crown is built (`lobed`), at its reference
    /// size in metres.
    struct CrownSpec {
        var leaf: SIMD4<Float> = broadUV
        var H: Float
        var R: Float
        /// Share of H where the leaves begin.
        var crownBase: Float
        var lobes: ClosedRange<Int>
        /// Lobe radius, times R.
        var lobeR: ClosedRange<Float>
        var clumpsPerLobe: Int
        var cardSize: ClosedRange<Float>
        /// 0 dense ... 1 airy: lobes further apart, more clumps left out.
        var gappiness: Float
    }

    /// A crown of lobes (sub-crowns, each fed by one limb) with leaf cards on
    /// each lobe's shell, bent outward from the lobe (85 %) and the crown
    /// (15 %): the light and shade of a real oak or beech, with sky between
    /// the lobes. Cards buried in a neighbouring lobe are left out.
    static func lobed(_ sp: CrownSpec, form: Form, seed: UInt64, towardsLane: Bool = false) -> TreeArchetype {
        var r = WorldRandom(seed: seed)
        let H = sp.H, R = sp.R, base = sp.crownBase * H
        let cc = SIMD3<Float>(0, (base + H) / 2, 0)
        let env = SIMD3<Float>(R, (H - base) / 2, R)
        // 1. Lobes on the outer part of the envelope, fewer low down, kept
        //    from merging, then the core.
        var lobes: [Lobe] = []
        let want = sp.lobes.lowerBound + Int(r.unit() * Float(sp.lobes.count))
        var tries = 0
        while lobes.count < want, tries < 500 {
            tries += 1
            let d = randomDir(&r, minY: -0.8)
            let lr = R * r.range(sp.lobeR.lowerBound, sp.lobeR.upperBound)
            let reach = simd_max(env - SIMD3(repeating: lr), SIMD3(repeating: 0.1 * R))
            let p = cc + d * reach * r.range(0.7, 1.0)
            // Lobes overlap (more so in a dense crown) but don't merge.
            let apart = 0.55 * (1 + 0.3 * sp.gappiness)
            if lobes.contains(where: { simd_distance($0.c, p) < apart * ($0.r + lr) }) { continue }
            lobes.append(Lobe(c: p, r: lr))
        }
        lobes.append(Lobe(c: cc + SIMD3(0, env.y * 0.1, 0), r: min(env.x, env.y) * 0.5))
        if towardsLane {
            // Over a holle weg the trees reach for the light above the lane:
            // the lobes on that side grow by up to a quarter, every lobe
            // moves 0.3 of its radius that way, and, as at a wood's edge, big
            // limbs low on the light side carry lobes out over the lane, so
            // the crowns from the banks close into a tunnel.
            for i in lobes.indices {
                let f = min(max((lobes[i].c.x - cc.x) / env.x, 0), 1)
                lobes[i].r *= 1 + 0.25 * f
                lobes[i].c.x += 0.3 * lobes[i].r
            }
            let core = lobes.removeLast()
            for k in 0..<3 {
                let lr = R * r.range(0.32, 0.42)
                // No lower than the rest of the crown's lobes (centres a
                // radius over the crown base), so none hangs into the lane.
                let y = max(base + lr, base + lr + (H - base) * Float(k) * 0.16 + r.range(-0.4, 0.4))
                lobes.append(Lobe(c: SIMD3(R * r.range(0.75, 1.05), y, R * (Float(k) - 1) * 0.45 + r.range(-0.3, 0.3)), r: lr))
            }
            lobes.append(core)
        }
        var full = MeshBuffer(parts: 2), light = MeshBuffer(parts: 2)
        // 2. Trunk to the crown base and on through the core; one limb per
        //    lobe, ending 0.35 r short of its centre, so no limb shows
        //    outside the leaves.
        let lean = SIMD3<Float>(r.range(-0.3, 0.3), 0, r.range(-0.3, 0.3)) * (R / 7)
        let top = SIMD3<Float>(0, base + 0.35 * (H - base), 0) + lean
        let r0 = 0.024 * H
        limb(&full, SIMD3(0, -0.4, 0), SIMD3(0, base * 0.5, 0) + lean * 0.3, top, r0, r0 * 0.45, sides: 8, segments: 4, height: H)
        tube(&light, SIMD3(0, -0.4, 0), top, r0, r0 * 0.45, sides: 5, height: H)
        // Limbs leave the trunk inside the crown: above the lowest lobe's
        // underside, so none hangs bare below the leaves.
        let under = lobes.reduce(H) { min($0, $1.c.y - 0.55 * $1.r) }
        let limbLow = min(max(base, under), top.y)
        var tips: [SIMD3<Float>] = []
        for l in lobes.dropLast() {
            let from = SIMD3<Float>(0, r.range(limbLow, top.y), 0) + lean * 0.8
            let to = l.c + simd_normalize(from - l.c) * (0.35 * l.r)
            let via = from + (to - from) * 0.5 + SIMD3(0, simd_distance(from, to) * 0.18, 0)
            limb(&full, from, via, to, r0 * 0.42, r0 * 0.12, sides: 4, segments: 3, height: H)
            tips.append(to)
        }
        // 3. Clumps on each lobe's shell; none buried in a neighbour.
        let hull = Self.hull(for: sp.leaf)
        for (i, l) in lobes.enumerated() {
            let n = i == lobes.count - 1 ? sp.clumpsPerLobe / 2 : sp.clumpsPerLobe
            let firstCard = full.vertexCount
            for _ in 0..<n {
                let d = randomDir(&r, minY: -0.7)
                let p = l.c + d * l.r * r.range(0.72, 1.0)
                let size = r.range(sp.cardSize.lowerBound, sp.cardSize.upperBound)
                let roll = r.range(0, 6.283)
                let mirror = r.unit() < 0.5
                if lobes.indices.contains(where: { $0 != i && simd_distance(lobes[$0].c, p) < lobes[$0].r * 0.8 }) { continue }
                if r.unit() < sp.gappiness * 0.25 { continue }
                let nrm = simd_normalize(d * 0.85 + simd_normalize((p - cc) / env) * 0.15)
                card(&full, centre: p, size: size, normal: nrm, roll: roll, uv: sp.leaf, crownCentre: l.c,
                     crownRadii: SIMD3(repeating: l.r), height: H, ao: skyVisibility(p, lobes: lobes),
                     bend: 0.85, mirror: mirror, hull: hull)
            }
            // Light version: one big card per lobe, so the silhouette
            // matches at the switch, trimmed to its leaves as theirs are,
            // and shaded on average as the lobe's leaf cards are (from a
            // lobe's own centre the sky is always hidden, which turned the
            // middle distance's woods dark). Without cards of its own, the
            // sky at the lobe's top.
            let firstLight = light.vertexCount
            let shade = Self.meanShade(full, from: firstCard)
            card(&light, centre: l.c, size: 2.15 * l.r, normal: simd_normalize((l.c - cc) / env + SIMD3(0, 0.2, 0)),
                 roll: r.range(0, 6.283), uv: sp.leaf, crownCentre: cc, crownRadii: env, height: H,
                 ao: shade == nil ? skyVisibility(l.c + SIMD3(0, 0.8 * l.r, 0), lobes: lobes) : 1, bend: 0.6,
                 mirror: r.unit() < 0.5, hull: hull)
            if let shade, let own = Self.meanShade(light, from: firstLight) {
                for k in firstLight..<light.vertexCount { light.uv3[2 * k] *= shade / own }
            }
        }
        var a = TreeArchetype(form: form, refHeight: H, refRadius: R, full: full, light: light)
        a.lobes = lobes
        a.crownBase = base
        a.limbTips = tips
        return a
    }

    // MARK: - Columns, pollards and conifers

    /// Lombardy poplar: whorls of three short, steep branches every 0.7 m
    /// up a slender trunk, each with leaf clumps spaced along it and its tip
    /// ending inside the last, so the column reads as dense foliage from
    /// near the ground to a pointed top, with the trunk only in the gaps.
    static func lombardy(seed: UInt64, towardsLane: Bool = false) -> TreeArchetype {
        var r = WorldRandom(seed: seed)
        let H: Float = 22, R: Float = 2.8
        let y0: Float = 1.2, y1 = 0.97 * H
        /// The column's radius at height y: widest about a third of the way
        /// up, pointed at the top.
        func profile(_ y: Float) -> Float {
            let t = min(max((y - y0) / (y1 - y0), 0), 1)
            return R * pow(sin(.pi * min(t * 1.05 + 0.04, 1)), 0.6) * (1 - 0.25 * t)
        }
        var full = MeshBuffer(parts: 2), light = MeshBuffer(parts: 2)
        let shift: Float = towardsLane ? 0.25 * R : 0
        tube(&full, SIMD3(0, -0.4, 0), SIMD3(0, 0.6 * H, 0), 0.36, 0.1, sides: 7, height: H)
        tube(&full, SIMD3(0, 0.6 * H, 0), SIMD3(0, 0.95 * H, 0), 0.1, 0.02, sides: 4, height: H, vStart: 6)
        tube(&light, SIMD3(0, -0.4, 0), SIMD3(0, 0.8 * H, 0), 0.36, 0.06, sides: 5, height: H)
        // (Small cards: square ones cost little in discarded fragments, and
        // a column needs about 300 of them.)
        var y = y0
        var whorl = 0
        var tips: [SIMD3<Float>] = []
        while y < y1 - 0.3 {
            for k in 0..<3 {
                let az = Float(whorl) * 2.4 + Float(k) * 2.094 + r.range(-0.4, 0.4)
                let rise = min(r.range(1.0, 2.4), y1 - y)
                let tipY = y + rise
                let reach = profile(tipY) * r.range(0.55, 0.9)
                let out = SIMD3<Float>(cos(az), 0, sin(az))
                let start = SIMD3<Float>(0, y, 0)
                let tip = SIMD3<Float>(0, tipY, 0) + out * reach + SIMD3(shift * (tipY / H), 0, 0)
                tube(&full, start, tip, 0.05, 0.015, sides: 3, height: H)
                tips.append(tip)
                // Clumps along the branch; the last one is centred 0.2 m past
                // the tip, so the tip ends inside it.
                let dir = simd_normalize(tip - start)
                let clumps = 3 + Int(r.unit() * 2)
                for c in 0..<clumps {
                    let t = 0.25 + 0.75 * Float(c) / Float(clumps - 1)
                    let p = start + (tip - start) * t + dir * (c == clumps - 1 ? 0.2 : 0) + randomDir(&r) * 0.15
                    let axis = SIMD3<Float>(shift * (p.y / H), p.y, 0)
                    let nrm = simd_normalize(p - axis + SIMD3(0, 0.3, 0))
                    card(&full, centre: p, size: r.range(1.1, 1.5), normal: nrm, roll: r.range(0, 6.283), uv: poplarUV,
                         crownCentre: axis, crownRadii: SIMD3(R, R * 1.5, R), height: H,
                         ao: 0.7 + 0.3 * min(simd_length(SIMD2(p.x - axis.x, p.z)) / max(profile(p.y), 0.3), 1),
                         aspect: 0.85, mirror: r.unit() < 0.5)
                }
            }
            y += 0.7
            whorl += 1
        }
        // Light version: 16 bands of cards up the column, overlapping by
        // 40 %, as wide as the column's profile. A band wider than 1.4
        // times its height takes two cards side by side on screen (their
        // corner offsets moved apart), so the column keeps its width and
        // taper at the switch without stretched leaves.
        let nL = 16
        let cardH = (y1 - y0) / (1 + 0.6 * Float(nL - 1))
        let size = cardH * 1.15
        for k in 0..<nL {
            let yc = y0 + cardH * (0.5 + 0.6 * Float(k))
            let az = Float(k) * 2.4
            let w = max(2.05 * profile(yc), 0.6)
            let pair = w > 1.4 * size
            for j in 0..<(pair ? 2 : 1) {
                let first = light.vertexCount
                // (ao: the full version's leaves average 0.57 with their
                // depth in the column.)
                card(&light, centre: SIMD3(shift * (yc / H), yc, 0) + SIMD3(cos(az), 0, sin(az)) * 0.2, size: size,
                     normal: SIMD3(cos(az), 0.1, sin(az)), roll: r.range(-0.15, 0.15), uv: poplarUV,
                     crownCentre: SIMD3(0, yc, 0), crownRadii: SIMD3(R, R, R), height: H, ao: 0.77,
                     aspect: (pair ? 0.6 * w : w) / size, mirror: j == 1)
                if pair {
                    for i in first..<light.vertexCount { light.uv4[2 * i] += (Float(j) - 0.5) * 0.4 * w }
                }
            }
        }
        var a = TreeArchetype(form: .lombardy, refHeight: H, refRadius: R, full: full, light: light)
        a.crownBase = y0
        a.limbTips = tips
        return a
    }

    /// Pollard willow (knotwilg), the tree of Flemish brooks and wet
    /// meadows: a short trunk swelling to a knot, crowned by straight whips
    /// with narrow leaves along them.
    static func willow(seed: UInt64) -> TreeArchetype {
        var r = WorldRandom(seed: seed)
        let knotY = r.range(1.8, 2.5)
        let H: Float = knotY + 4.6, R: Float = 3.2
        var full = MeshBuffer(parts: 2), light = MeshBuffer(parts: 2)
        let lean = SIMD3<Float>(r.range(-0.25, 0.25), 0, r.range(-0.25, 0.25))
        let knot = SIMD3<Float>(0, knotY, 0) + lean
        tube(&full, SIMD3(0, -0.3, 0), knot - SIMD3(0, 0.3, 0), 0.32, 0.36, sides: 8, height: H)
        tube(&full, knot - SIMD3(0, 0.3, 0), knot + SIMD3(0, 0.15, 0), 0.48, 0.4, sides: 8, height: H, vStart: 1)
        tube(&light, SIMD3(0, -0.3, 0), knot + SIMD3(0, 0.15, 0), 0.34, 0.42, sides: 5, height: H)
        let cc = knot + SIMD3(0, 2.4, 0)
        let radii = SIMD3<Float>(R, 2.4, R)
        let whips = 18 + Int(r.unit() * 9)
        var tips: [SIMD3<Float>] = []
        for k in 0..<whips {
            let az = Float(k) * 2.4 + r.range(-0.3, 0.3)
            let el = r.range(0.87, 1.4)
            let len = r.range(2.2, 4.2)
            let dir = SIMD3<Float>(cos(az) * cos(el), sin(el), sin(az) * cos(el))
            let foot = knot + SIMD3(cos(az) * 0.3, 0.1, sin(az) * 0.3)
            let tip = foot + dir * len
            // Whips arch out a little towards their tips.
            let via = foot + dir * (len * 0.5) - SIMD3(cos(az), 0, sin(az)) * 0.15
            limb(&full, foot, via, tip, 0.04, 0.012, sides: 3, segments: 2, height: H)
            tips.append(tip)
            let cards = 3 + Int(r.unit() * 2)
            for c in 0..<cards {
                let t = 0.4 + 0.6 * Float(c) / Float(cards - 1)
                let p = foot + (tip - foot) * t + dir * (c == cards - 1 ? 0.2 : 0)
                card(&full, centre: p, size: r.range(0.9, 1.3), normal: simd_normalize(dir + SIMD3(0, 0.3, 0)),
                     roll: r.range(0, 6.283), uv: broadUV, crownCentre: cc, crownRadii: radii, height: H,
                     ao: 0.75 + 0.25 * t, aspect: 0.8, mirror: r.unit() < 0.5, hull: broadHull)
            }
        }
        for k in 0..<8 {
            let az = Float(k) * 0.785 + r.range(-0.2, 0.2)
            let d = simd_normalize(SIMD3<Float>(cos(az), k % 2 == 0 ? 0.3 : 0.9, sin(az)))
            card(&light, centre: cc + d * radii * 0.55, size: 3.2, normal: d, roll: r.range(0, 6.283), uv: broadUV,
                 crownCentre: cc, crownRadii: radii, height: H, ao: 0.72, mirror: k % 2 == 0)
        }
        var a = TreeArchetype(form: .willow, refHeight: H, refRadius: R, full: full, light: light)
        a.crownBase = knotY
        a.limbTips = tips
        return a
    }

    static func conifer(seed: UInt64) -> TreeArchetype {
        var r = WorldRandom(seed: seed)
        let H: Float = 16, R: Float = 3.2
        var full = MeshBuffer(parts: 2)
        var light = MeshBuffer(parts: 2)
        tube(&full, SIMD3(0, -0.4, 0), SIMD3(0, H, 0), 0.3, 0.04, sides: 7, height: H)
        tube(&light, SIMD3(0, -0.4, 0), SIMD3(0, H, 0), 0.3, 0.04, sides: 4, height: H)
        let levels = 9
        for l in 0..<levels {
            let t = (Float(l) + 0.5) / Float(levels)
            let y = (0.14 + 0.84 * t) * H
            let rad = R * (1 - t) * 1.05 + 0.3
            let nb = 6
            for k in 0..<nb {
                let az = Float(k) / Float(nb) * 2 * .pi + Float(l) * 0.7 + r.range(-0.2, 0.2)
                let dir = SIMD3<Float>(cos(az), -0.25, sin(az))
                let start = SIMD3<Float>(0, y, 0)
                let tip = start + dir * rad
                if l % 2 == 0 { tube(&full, start, tip, 0.05, 0.015, sides: 3, height: H) }
                let mid = start + dir * rad * 0.6
                let n = simd_normalize(SIMD3(cos(az) * 0.3, 1, sin(az) * 0.3))
                card(&full, centre: mid, size: rad * 1.25 + 0.4, normal: n, roll: az, uv: needleUV,
                     crownCentre: SIMD3(0, y, 0), crownRadii: SIMD3(R, R, R), height: H, ao: 0.6 + 0.4 * t, bend: 0.5,
                     billboard: false)
                if l % 3 == 1 && k % 2 == 0 {
                    card(&light, centre: start + dir * rad * 0.45, size: rad * 1.6 + 0.6, normal: n, roll: az, uv: needleUV,
                         crownCentre: SIMD3(0, y, 0), crownRadii: SIMD3(R, R, R), height: H, ao: 0.6 + 0.4 * t, bend: 0.5,
                         billboard: false)
                }
            }
        }
        var a = TreeArchetype(form: .conifer, refHeight: H, refRadius: R, full: full, light: light)
        a.crownBase = 0.14 * H
        return a
    }
}

extension TreeArchetype.Form {
    /// Archetypes made per form (each another seed).
    var variants: Int { self == .copperBeech || self == .willow ? 2 : 3 }

    /// The lobed crown of a broadleaf form; nil for the forms with their
    /// own builders.
    var spec: TreeArchetype.CrownSpec? {
        typealias S = TreeArchetype.CrownSpec
        switch self {
        case .beech: return S(H: 20, R: 7, crownBase: 0.22, lobes: 7...9, lobeR: 0.36...0.5, clumpsPerLobe: 20, cardSize: 2.2...3.0, gappiness: 0.15)
        case .beechForest: return S(H: 30, R: 6, crownBase: 0.5, lobes: 5...7, lobeR: 0.4...0.55, clumpsPerLobe: 22, cardSize: 2.4...3.2, gappiness: 0.1)
        case .oak: return S(H: 18, R: 8, crownBase: 0.3, lobes: 8...11, lobeR: 0.28...0.42, clumpsPerLobe: 15, cardSize: 2.0...2.8, gappiness: 0.35)
        case .oakForest: return S(H: 26, R: 6.5, crownBase: 0.45, lobes: 6...8, lobeR: 0.32...0.45, clumpsPerLobe: 17, cardSize: 2.2...3.0, gappiness: 0.3)
        case .ash: return S(H: 20, R: 6, crownBase: 0.4, lobes: 6...8, lobeR: 0.3...0.42, clumpsPerLobe: 13, cardSize: 2.0...2.8, gappiness: 0.55)
        case .sycamore: return S(H: 16, R: 6, crownBase: 0.3, lobes: 6...8, lobeR: 0.4...0.5, clumpsPerLobe: 17, cardSize: 2.0...2.8, gappiness: 0.2)
        case .hybridPoplar: return S(leaf: TreeArchetype.poplarUV, H: 28, R: 7, crownBase: 0.45, lobes: 5...7, lobeR: 0.3...0.45, clumpsPerLobe: 14, cardSize: 2.2...3.0, gappiness: 0.45)
        case .orchard: return S(H: 6, R: 3.2, crownBase: 0.33, lobes: 5...7, lobeR: 0.4...0.5, clumpsPerLobe: 12, cardSize: 1.0...1.5, gappiness: 0.25)
        case .copperBeech: return S(H: 18, R: 7, crownBase: 0.2, lobes: 7...9, lobeR: 0.36...0.5, clumpsPerLobe: 20, cardSize: 2.2...3.0, gappiness: 0.12)
        case .lombardy, .willow, .conifer: return nil
        }
    }

    /// Cell in the impostor atlas (cj_impostor.png, 4 x 2).
    var impostorCell: Int {
        switch self {
        case .beech, .beechForest, .copperBeech: return 0
        case .oak, .oakForest: return 1
        case .ash, .sycamore: return 2
        case .hybridPoplar: return 3
        case .lombardy: return 4
        case .willow: return 5
        case .conifer: return 6
        case .orchard: return 7
        }
    }

    /// The species' leaf colour, as a multiplier on the atlas's (linear).
    /// Copper beech is the only purple: red and blue at the packing's
    /// limit, green cut to a quarter.
    var leafColour: SIMD3<Float> {
        switch self {
        case .beech, .beechForest: return SIMD3(1.0, 1.04, 0.85)
        case .oak, .oakForest: return SIMD3(0.84, 0.88, 0.74)
        case .ash: return SIMD3(0.95, 1.06, 1.0)
        case .sycamore: return SIMD3(0.8, 0.9, 0.82)
        case .hybridPoplar: return SIMD3(1.02, 1.02, 0.86)
        case .lombardy: return SIMD3(0.92, 0.98, 0.85)
        case .willow: return SIMD3(1.25, 1.08, 1.9)
        case .conifer: return SIMD3(1, 1, 1)
        case .orchard: return SIMD3(1.0, 1.0, 0.82)
        case .copperBeech: return SIMD3(1.95, 0.27, 1.95)
        }
    }

    /// Least crown radius for a tree of this form, as a share of its
    /// height scale: a broadleaf keeps a crown at least about half as wide
    /// as it is tall, however small its LiDAR crown, or it reads as a
    /// lollipop.
    var minSpread: Float {
        switch self {
        case .lombardy, .conifer: return 0.45
        default: return 0.55
        }
    }
}

extension TreeArchetype {
    /// A leaf colour multiplier packed for `WorldShaders.shadeDecode`:
    /// r << 16 | g << 8 | b with 128 = x1, so each channel is 1/128 to 2
    /// (exact in a float, which holds integers to 2^24).
    static func packColour(_ c: SIMD3<Float>) -> Float {
        let q = simd_clamp((c * 128).rounded(.toNearestOrAwayFromZero), SIMD3(repeating: 1), SIMD3(repeating: 255))
        return Float(Int(q.x) << 16 | Int(q.y) << 8 | Int(q.z))
    }
}

/// One world's tree archetypes, made the first time a tree needs one: a
/// few seeds per form, and their lane-side variants (`TreeArchetype.make`).
final class TreeLibrary {
    private var made: [Int: TreeArchetype] = [:]

    /// One of the form's archetypes, chosen by `rnd`.
    func pick(_ form: TreeArchetype.Form, _ rnd: inout WorldRandom, towardsLane: Bool = false) -> TreeArchetype {
        let v = min(Int(rnd.unit() * Float(form.variants)), form.variants - 1)
        let key = (form.rawValue * 16 + v) * 2 + (towardsLane ? 1 : 0)
        if let hit = made[key] { return hit }
        let a = TreeArchetype.make(form, variant: v, towardsLane: towardsLane)
        made[key] = a
        return a
    }
}
