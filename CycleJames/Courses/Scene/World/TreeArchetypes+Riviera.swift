import Foundation
import simd

/// The Riviera's trees (`WorldLook.riviera`): the Aleppo and stone pines,
/// cypresses, Canary and fan palms, olives, Norfolk Island pines, holm oaks
/// and eucalypts of the Ligurian coast, as the photos of the Poggio show
/// them in late March (research look bible, section 3). Their leaves are
/// cells of cj_foliage_med.png and their bark tiles of cj_bark_med_*, both
/// baked by scripts/courses/textures/bake_riviera_plants.py; the parts and
/// texture channels are the Flemish forms' (`TreeArchetype`), and a bark
/// vertex's u carries its tile of the bark atlas (`setBark`).
extension TreeArchetype {
    // MARK: - Atlas

    /// A cell of cj_foliage_med.png (2048 px, 4 x 4 cells of 512 px), `cols`
    /// wide, inset 5 px; (u0, v0, u1, v1), v0 at the top.
    static func medCell(_ col: Int, _ row: Int, cols: Int = 1) -> SIMD4<Float> {
        let i: Float = 5.0 / 2048
        return SIMD4(Float(col) * 0.25 + i, Float(row) * 0.25 + i, Float(col + cols) * 0.25 - i, Float(row + 1) * 0.25 - i)
    }

    static let medAleppoUV = medCell(0, 0)
    static let medPineaUV = medCell(1, 0)
    static let medOliveUV = medCell(2, 0)
    /// Glossy evergreen leaves: pittosporum, laurel, holm oak.
    static let medEvergreenUV = medCell(3, 0)
    static let medCypressUV = medCell(0, 1)
    /// A metre of Norfolk Island pine branch from above, axis along the
    /// middle, tileable along u.
    static let medAraucariaUV = medCell(1, 1)
    static let medOleanderUV = medCell(2, 1)
    static let medBougainvilleaUV = medCell(3, 1)
    /// One Canary palm frond, the whole row: base at u0, tip at u1, 5 m
    /// long and 1.25 m across, the rachis along the middle.
    static let medFrondUV = medCell(0, 2, cols: 4)
    /// A fan leaf face on, its hastula 0.06 of the cell below the middle.
    static let medFanUV = medCell(0, 3)
    /// A dead fan hanging from the cell's top edge.
    static let medDeadFanUV = medCell(1, 3)
    static let medIceplantUV = medCell(2, 3)
    /// Giant reed, 4 m, rooted on the cell's bottom edge.
    static let medReedUV = medCell(3, 3)

    /// Hexagons round each trimmed cell's leaves, as `broadHull`; fitted to
    /// today's cj_foliage_med.png by `fit_hulls.py --med` (the oleander, the
    /// ice plant and the reed reach their cells' corners and stay square).
    static let medAleppoHull: [SIMD2<Float>] = [
        SIMD2(0.585, 0.346), SIMD2(-0.014, 0.658), SIMD2(-0.752, 0.187),
        SIMD2(-0.733, -0.258), SIMD2(-0.029, -0.625), SIMD2(0.610, -0.217),
    ]
    static let medPineaHull: [SIMD2<Float>] = [
        SIMD2(0.269, 0.763), SIMD2(-0.387, 0.676), SIMD2(-0.817, -0.361),
        SIMD2(-0.565, -0.689), SIMD2(0.632, -0.532), SIMD2(0.853, 0.002),
    ]
    static let medOliveHull: [SIMD2<Float>] = [
        SIMD2(0.496, 0.360), SIMD2(-0.689, 0.097), SIMD2(-0.837, -0.372),
        SIMD2(-0.433, -0.813), SIMD2(0.808, -0.538), SIMD2(0.939, -0.123),
    ]
    static let medEvergreenHull: [SIMD2<Float>] = [
        SIMD2(0.863, 0.520), SIMD2(-0.377, 0.852), SIMD2(-0.881, 0.347),
        SIMD2(-0.575, -0.795), SIMD2(0.048, -0.962), SIMD2(1.000, -0.006),
    ]
    static let medCypressHull: [SIMD2<Float>] = [
        SIMD2(0.347, 0.960), SIMD2(-0.554, 0.842), SIMD2(-0.970, -0.162),
        SIMD2(-0.379, -0.932), SIMD2(0.560, -0.809), SIMD2(0.961, 0.160),
    ]
    static let medBougainvilleaHull: [SIMD2<Float>] = [
        SIMD2(0.845, 0.484), SIMD2(-0.005, 0.926), SIMD2(-0.840, 0.394),
        SIMD2(-0.795, -0.644), SIMD2(-0.140, -0.985), SIMD2(0.881, -0.334),
    ]
    static let medFanHull: [SIMD2<Float>] = [
        SIMD2(0.276, 0.808), SIMD2(-0.650, 0.602), SIMD2(-0.900, -0.190),
        SIMD2(-0.148, -1.000), SIMD2(0.608, -0.843), SIMD2(0.910, 0.116),
    ]
    static let medDeadFanHull: [SIMD2<Float>] = [
        SIMD2(0.040, 0.902), SIMD2(-0.034, 0.902), SIMD2(-0.705, -0.260),
        SIMD2(-0.401, -0.787), SIMD2(0.449, -0.787), SIMD2(0.732, -0.297),
    ]

    /// The leaf a clipped hedge's core is drawn in (`core(for:)`), for the
    /// cells hedges are made of.
    static let medEvergreenCore = SIMD2<Float>(0.8875, 0.0759)
    static let medBougainvilleaCore = SIMD2<Float>(0.8562, 0.3977)
    static let medCypressCore = SIMD2<Float>(0.1716, 0.3943)

    static func medHull(for uv: SIMD4<Float>) -> [SIMD2<Float>]? {
        switch uv {
        case medAleppoUV: return medAleppoHull
        case medPineaUV: return medPineaHull
        case medOliveUV: return medOliveHull
        case medEvergreenUV: return medEvergreenHull
        case medCypressUV: return medCypressHull
        case medBougainvilleaUV: return medBougainvilleaHull
        case medFanUV: return medFanHull
        case medDeadFanUV: return medDeadFanHull
        default: return nil
        }
    }

    static func medCore(for uv: SIMD4<Float>) -> SIMD2<Float>? {
        switch uv {
        case medEvergreenUV: return medEvergreenCore
        case medBougainvilleaUV: return medBougainvilleaCore
        case medCypressUV: return medCypressCore
        default: return nil
        }
    }

    // MARK: - Bark atlas

    /// Tiles of cj_bark_med_albedo.jpg (4 x 2), in order.
    enum MedBark: Int {
        case stonePine, aleppo, phoenix, washingtonia, windmill, olive, opuntia, agave
    }

    /// A bark vertex's u is its tile times this plus its u within the tile,
    /// which repeats every 1 (`WorldShaders.barkAtlasSurface`).
    static let barkTileStride: Float = 8

    /// Moves every bark vertex (part 0) of `m` from `first` on onto a tile
    /// of the bark atlas, its u around the trunk repeated `uScale` times (a
    /// palm's trunk is 3 m round; a tile is 1 m round by 2 m up).
    static func setBark(_ m: inout MeshBuffer, from first: Int = 0, tile: MedBark, uScale: Float = 1) {
        var seen = Set<UInt32>()
        for i in m.parts[0] where Int(i) >= first && seen.insert(i).inserted {
            m.uvs[2 * Int(i)] = Float(tile.rawValue) * barkTileStride + min(m.uvs[2 * Int(i)] * uScale, barkTileStride - 0.01)
        }
    }

    // MARK: - Builders

    static func makeRiviera(_ form: Form, seed: UInt64, variant: Int, towardsLane: Bool) -> TreeArchetype {
        var a: TreeArchetype
        switch form {
        case .aleppoPine: a = aleppoPine(seed: seed, variant: variant)
        case .stonePine: a = stonePine(seed: seed, variant: variant)
        case .cypress: a = cypress(seed: seed)
        case .phoenixPalm: a = phoenixPalm(seed: seed, variant: variant)
        case .washingtonia: a = fanPalm(seed: seed, variant: variant, tall: true)
        case .fanPalm: a = fanPalm(seed: seed, variant: variant, tall: false)
        case .araucaria: a = araucaria(seed: seed)
        case .olive: a = olive(seed: seed, towardsLane: towardsLane)
        default: a = lobed(form.spec!, form: form, seed: seed, towardsLane: towardsLane)
        }
        let bark = form.medBark
        setBark(&a.full, tile: bark.tile, uScale: bark.uScale)
        setBark(&a.light, tile: bark.tile, uScale: bark.uScale)
        return a
    }

    /// A point on the quadratic Bezier a, c, b.
    @inline(__always)
    static func bezier(_ a: SIMD3<Float>, _ c: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        let u = 1 - t
        return a * (u * u) + c * (2 * u * t) + b * (t * t)
    }

    /// A flattened clump of needle tufts (`aleppoPine`, `stonePine`).
    struct Cloud {
        var c: SIMD3<Float>
        var rx: Float
        var ry: Float
    }

    /// Clouds of tuft cards (part 1) on the shells of flattened ellipsoids,
    /// most of them on top, shaded by the crown's other clouds; and for the
    /// light version one flattened card per cloud, shaded on average as its
    /// cards are. `under` keeps that share of the cards facing down (a
    /// stone pine's dark ceiling).
    static func tuftClouds(_ clouds: [Cloud], full: inout MeshBuffer, light: inout MeshBuffer, uv: SIMD4<Float>,
                           size: ClosedRange<Float>, perArea: Float, under: Float, height H: Float, crownCentre: SIMD3<Float>,
                           crownRadii: SIMD3<Float>, r: inout WorldRandom) {
        let lobes = clouds.map { Lobe(c: $0.c, r: $0.rx * 0.85) }
        let hull = Self.hull(for: uv)
        for cl in clouds {
            let radii = SIMD3(cl.rx, cl.ry, cl.rx)
            let first = full.vertexCount
            let count = Int(cl.rx * cl.rx * perArea) + 5
            for _ in 0..<count {
                let d = randomDir(&r, minY: -0.6)
                if d.y < -0.15, r.unit() > under { continue }
                let p = cl.c + d * radii * r.range(0.5, 0.95)
                let nrm = simd_normalize(d * 0.75 + SIMD3(0, 0.35, 0))
                let ao = skyVisibility(p + SIMD3(0, 0.2, 0), lobes: lobes) * (d.y < -0.15 ? 0.82 : 1)
                card(&full, centre: p, size: r.range(size.lowerBound, size.upperBound), normal: nrm, roll: r.range(0, 6.283), uv: uv,
                     crownCentre: cl.c, crownRadii: radii, height: H, ao: ao, bend: 0.8, mirror: r.unit() < 0.5, hull: hull)
            }
            let firstL = light.vertexCount
            let shade = meanShade(full, from: first)
            let out = simd_normalize((cl.c - crownCentre) / crownRadii + SIMD3(0, 0.3, 0))
            card(&light, centre: cl.c + SIMD3(0, cl.ry * 0.1, 0), size: 2.3 * cl.ry, normal: out, roll: r.range(-0.2, 0.2), uv: uv,
                 crownCentre: crownCentre, crownRadii: crownRadii, height: H, ao: 1, bend: 0.6, aspect: cl.rx / cl.ry,
                 mirror: r.unit() < 0.5, hull: hull)
            if let shade, let own = meanShade(light, from: firstL) {
                for k in firstL..<light.vertexCount { light.uv3[2 * k] *= shade / own }
            }
        }
    }

    /// Aleppo pine (Pinus halepensis), the pine of the sea front and the
    /// ridge: a leaning, kinked bole and an irregular, flat-topped crown of
    /// separate clouds of tufts on bare limbs, sky between them. Variant 0
    /// is the wind-bent pine silhouetted against the sea at the start, a
    /// tall crooked bole under a small flat crown; 1 forks and spreads; 2
    /// is an irregular dome.
    static func aleppoPine(seed: UInt64, variant: Int) -> TreeArchetype {
        var r = WorldRandom(seed: seed)
        let shape = variant % 3
        let H: Float = 14, R: Float = 5
        let base: Float = [0.66, 0.5, 0.42][shape] * H
        let spread: Float = [0.62, 1.0, 0.86][shape] * R
        let az = r.range(0, 6.283)
        let leanDir = SIMD3<Float>(cos(az), 0, sin(az)), side = SIMD3<Float>(-sin(az), 0, cos(az))
        let lean = r.range(0.06, 0.15) * (shape == 0 ? 1.7 : 1)
        let top = SIMD3<Float>(0, base + (H - base) * 0.3, 0) + leanDir * (lean * H * 0.7)
        let kink = SIMD3<Float>(0, base * 0.5, 0) + leanDir * (lean * H * 0.15) + side * r.range(-0.6, 0.6)
        var full = MeshBuffer(parts: 2), light = MeshBuffer(parts: 2)
        let r0 = 0.021 * H
        let foot = SIMD3<Float>(0, -0.4, 0)
        limb(&full, foot, kink, top, r0, r0 * 0.5, sides: 8, segments: 6, height: H)
        limb(&light, foot, kink, top, r0, r0 * 0.5, sides: 5, segments: 3, height: H)
        // A forked pine's second leader.
        var leaders: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [(foot, kink, top)]
        if shape == 1 {
            let from = bezier(foot, kink, top, 0.62)
            let to = top + side * (r.unit() < 0.5 ? -1 : 1) * r.range(1.4, 2.2) - SIMD3(0, r.range(0.3, 1.0), 0)
            let via = (from + to) / 2 + SIMD3(0, 0.6, 0)
            limb(&full, from, via, to, r0 * 0.6, r0 * 0.35, sides: 6, segments: 4, height: H)
            tube(&light, from, to, r0 * 0.6, r0 * 0.35, sides: 4, height: H)
            leaders.append((from, via, to))
        }
        // Clouds: kept apart, the outer ones lower, so the top is flat.
        var clouds: [Cloud] = []
        let want = [5, 8, 9][shape] + Int(r.unit() * 2)
        var tries = 0
        while clouds.count < want, tries < 400 {
            tries += 1
            let rx = r.range(1.3, 2.1) * (shape == 0 ? 0.85 : 1)
            let ry = rx * r.range(0.42, 0.58)
            let out = max(spread - rx, 0.3) * r.range(0.05, 1).squareRoot()
            let a = r.range(0, 6.283)
            let y = max(H - ry - (H - base) * r.range(0, 0.4) - out / spread * (H - base) * 0.25, base + ry)
            let c = SIMD3<Float>(top.x + cos(a) * out, y, top.z + sin(a) * out)
            let clash = clouds.contains {
                simd_distance(SIMD2($0.c.x, $0.c.z), SIMD2(c.x, c.z)) < 0.8 * ($0.rx + rx) && abs($0.c.y - c.y) < 0.9 * ($0.ry + ry)
            }
            if clash { continue }
            clouds.append(Cloud(c: c, rx: rx, ry: ry))
        }
        // A limb to each cloud from a leader, ending inside it, and a twig
        // to its far side. The wind-bent pine's leave its bole high, so
        // they don't run up beside it like more stems.
        var tips: [SIMD3<Float>] = []
        for cl in clouds {
            let l = leaders[Int(r.unit() * Float(leaders.count)) % leaders.count]
            let from = bezier(l.0, l.1, l.2, r.range(shape == 0 ? 0.82 : 0.55, 1.0))
            let to = cl.c + simd_normalize(from - cl.c) * (0.3 * cl.rx)
            let via = (from + to) / 2 + SIMD3(0, simd_distance(from, to) * 0.2, 0)
            limb(&full, from, via, to, r0 * 0.38, r0 * 0.12, sides: 4, segments: 3, height: H)
            // (The light version's limbs too: its one card per cloud
            // otherwise floats beside the bole like a lily pad.)
            tube(&light, from, to, r0 * 0.38, r0 * 0.14, sides: 3, height: H)
            tips.append(to)
            let a = r.range(0, 6.283)
            let twig = cl.c + SIMD3(cos(a), 0, sin(a)) * (0.35 * cl.rx)
            limb(&full, bezier(from, via, to, 0.6), (via + twig) / 2 + SIMD3(0, 0.3, 0), twig, r0 * 0.14, r0 * 0.05,
                 sides: 3, segments: 2, height: H)
            tips.append(twig)
        }
        let cc = SIMD3<Float>(top.x, (base + H) / 2, top.z), env = SIMD3<Float>(spread, (H - base) / 2, spread)
        tuftClouds(clouds, full: &full, light: &light, uv: medAleppoUV, size: 1.15...1.55, perArea: 3.2, under: 0.6,
                   height: H, crownCentre: cc, crownRadii: env, r: &r)
        // (Its radius is the crown it has, so a measured crown is drawn as
        // wide: the wind-bent pine's is little more than half another's.)
        var a = TreeArchetype(form: .aleppoPine, refHeight: H, refRadius: spread, full: full, light: light)
        a.lobes = clouds.map { Lobe(c: $0.c, r: $0.rx * 0.85) }
        a.crownBase = base
        a.limbTips = tips
        return a
    }

    /// Stone pine (Pinus pinea), the umbrella of the sanctuary's park and
    /// the ridge: a clean, plated bole forking at about half its height
    /// into limbs rising in a vase, under a broad, flat-topped canopy of
    /// long-needled tufts with a dark ceiling.
    static func stonePine(seed: UInt64, variant: Int) -> TreeArchetype {
        var r = WorldRandom(seed: seed)
        let H: Float = 15, R: Float = 7
        let az = r.range(0, 6.283)
        let leanDir = SIMD3<Float>(cos(az), 0, sin(az))
        let forkY = r.range(0.44, 0.56) * H
        let fork = SIMD3<Float>(0, forkY, 0) + leanDir * (r.range(0.02, 0.1) * forkY)
        var full = MeshBuffer(parts: 2), light = MeshBuffer(parts: 2)
        let foot = SIMD3<Float>(0, -0.4, 0)
        let mid = SIMD3<Float>(0, forkY * 0.5, 0) + leanDir * (r.range(-0.1, 0.25))
        limb(&full, foot, mid, fork, 0.46, 0.32, sides: 9, segments: 5, height: H)
        limb(&light, foot, mid, fork, 0.46, 0.32, sides: 5, segments: 2, height: H)
        // The umbrella: a centre lobe, an inner ring and an outer one, the
        // ring lobes a little lower, all flattened.
        let centre = SIMD3<Float>(fork.x, 0, fork.z) + leanDir * r.range(0, 0.8)
        var clouds: [Cloud] = []
        func lobe(_ dist: Float, _ angle: Float, _ rx: Float, flat: ClosedRange<Float>, drop: Float) {
            let ry = rx * r.range(flat.lowerBound, flat.upperBound)
            let c = centre + SIMD3(cos(angle) * dist, H - ry - drop, sin(angle) * dist)
            clouds.append(Cloud(c: c, rx: rx, ry: ry))
        }
        lobe(0, 0, R * r.range(0.3, 0.36), flat: 0.4...0.5, drop: r.range(0, 0.2))
        let inner = 3 + Int(r.unit() * 2)
        let a0 = r.range(0, 6.283)
        for k in 0..<inner {
            lobe(R * r.range(0.3, 0.4), a0 + Float(k) * 6.283 / Float(inner) + r.range(-0.3, 0.3), R * r.range(0.28, 0.34),
                 flat: 0.4...0.5, drop: r.range(0.15, 0.5))
        }
        // (Six or seven broad, flat lobes round the ring, their undersides
        // near one level: an umbrella is one canopy from the road, flat
        // beneath. With 8-10 smaller ones at mixed drops it read as a
        // ring of separate puffs, scalloped above and ragged below.)
        let outer = 6 + Int(r.unit() * 2)
        for k in 0..<outer {
            lobe(R * r.range(0.6, 0.68), a0 + 0.4 + Float(k) * 6.283 / Float(outer) + r.range(-0.12, 0.12), R * r.range(0.38, 0.43),
                 flat: 0.32...0.38, drop: r.range(0.4, 0.62))
        }
        // Limbs: three to five rising in a vase from the fork, each parting
        // in two towards the ring lobes.
        var tips: [SIMD3<Float>] = []
        let bottom = clouds.map { $0.c.y - $0.ry }.min() ?? 0.7 * H
        let nPrimary = 3 + Int(r.unit() * 3)
        let ringLobes = Array(clouds.dropFirst())
        for k in 0..<nPrimary {
            let a = a0 + Float(k) * 6.283 / Float(nPrimary) + r.range(-0.3, 0.3)
            let p = centre + SIMD3(cos(a) * R * r.range(0.25, 0.38), bottom - r.range(0.6, 1.2), sin(a) * R * r.range(0.25, 0.38))
            let via = (fork + p) / 2 + SIMD3(0, 0.4, 0)
            limb(&full, fork, via, p, 0.24, 0.14, sides: 6, segments: 3, height: H)
            tube(&light, fork, p, 0.22, 0.12, sides: 4, height: H)
            // The two ring lobes nearest this limb's direction.
            let near = ringLobes.sorted {
                simd_distance(SIMD2($0.c.x, $0.c.z), SIMD2(p.x, p.z)) < simd_distance(SIMD2($1.c.x, $1.c.z), SIMD2(p.x, p.z))
            }.prefix(2)
            for (j, cl) in near.enumerated() {
                let to = cl.c + simd_normalize(p - cl.c) * (0.3 * cl.rx)
                limb(&full, p, (p + to) / 2 + SIMD3(0, 0.3, 0), to, 0.13, 0.05, sides: 4, segments: 3, height: H)
                // (In the light version, on into its nearest lobe's card.)
                if j == 0 { tube(&light, p, to, 0.12, 0.06, sides: 3, height: H) }
                tips.append(to)
            }
        }
        let cc = SIMD3<Float>(centre.x, H - 1.5, centre.z), env = SIMD3<Float>(R, 2.0, R)
        tuftClouds(clouds, full: &full, light: &light, uv: medPineaUV, size: 1.8...2.4, perArea: 1.8, under: 0.45,
                   height: H, crownCentre: cc, crownRadii: env, r: &r)
        var a = TreeArchetype(form: .stonePine, refHeight: H, refRadius: R, full: full, light: light)
        a.lobes = clouds.map { Lobe(c: $0.c, r: $0.rx * 0.85) }
        a.crownBase = bottom
        a.limbTips = tips
        return a
    }

    /// Italian cypress (Cupressus sempervirens): a dense, near-black column
    /// of scale-leaf sprays from near the ground to a sharp top, widest a
    /// fifth of the way up. Built as the Lombardy column is, closer and
    /// narrower.
    static func cypress(seed: UInt64) -> TreeArchetype {
        var r = WorldRandom(seed: seed)
        let H: Float = 12, R: Float = 1.05
        let y0: Float = 0.35, y1 = 0.985 * H
        func profile(_ y: Float) -> Float {
            let t = min(max((y - y0) / (y1 - y0), 0), 1)
            let w: Float = t < 0.14 ? 0.72 + 0.28 * t / 0.14 : t < 0.5 ? 1 : pow((1 - t) / 0.5, 0.85)
            return R * max(w, 0.06)
        }
        var full = MeshBuffer(parts: 2), light = MeshBuffer(parts: 2)
        tube(&full, SIMD3(0, -0.4, 0), SIMD3(0, 0.75 * H, 0), 0.2, 0.05, sides: 6, height: H)
        tube(&light, SIMD3(0, -0.4, 0), SIMD3(0, 0.6 * H, 0), 0.2, 0.06, sides: 4, height: H)
        let hull = medCypressHull
        var y = y0
        var whorl = 0
        var tips: [SIMD3<Float>] = []
        while y < y1 - 0.25 {
            for k in 0..<3 {
                let az = Float(whorl) * 2.4 + Float(k) * 2.094 + r.range(-0.4, 0.4)
                let tipY = y + min(r.range(0.6, 1.3), y1 - y)
                let out = SIMD3<Float>(cos(az), 0, sin(az))
                let start = SIMD3<Float>(0, y, 0)
                let tip = SIMD3<Float>(0, tipY, 0) + out * (profile(tipY) * r.range(0.45, 0.78))
                if k == 0, whorl % 2 == 0 { tube(&full, start, tip, 0.035, 0.012, sides: 3, height: H) }
                tips.append(tip)
                let clumps = 2 + Int(r.unit() * 2)
                for c in 0..<clumps {
                    let t = 0.35 + 0.65 * Float(c) / Float(clumps - 1)
                    let p = start + (tip - start) * t + simd_normalize(tip - start) * (c == clumps - 1 ? 0.12 : 0) + randomDir(&r) * 0.08
                    let axis = SIMD3<Float>(0, p.y, 0)
                    let size = max(0.55, profile(p.y) * 0.95) * r.range(0.85, 1.1)
                    card(&full, centre: p, size: size, normal: simd_normalize(p - axis + SIMD3(0, 0.25, 0)), roll: r.range(0, 6.283),
                         uv: medCypressUV, crownCentre: axis, crownRadii: SIMD3(R, R * 1.5, R), height: H,
                         ao: 0.68 + 0.32 * min(simd_length(SIMD2(p.x, p.z)) / max(profile(p.y), 0.3), 1), aspect: 0.9,
                         mirror: r.unit() < 0.5, hull: hull)
                }
            }
            y += 0.42
            whorl += 1
        }
        // The light version: bands of cards up the column (as the
        // Lombardy's), two side by side where a band is wide.
        let nL = 14
        let cardH = (y1 - y0) / (1 + 0.6 * Float(nL - 1))
        let size = cardH * 1.15
        for k in 0..<nL {
            let yc = y0 + cardH * (0.5 + 0.6 * Float(k))
            let az = Float(k) * 2.4
            let w = max(2.05 * profile(yc), 0.35)
            let pair = w > 1.4 * size
            for j in 0..<(pair ? 2 : 1) {
                let first = light.vertexCount
                card(&light, centre: SIMD3(0, yc, 0) + SIMD3(cos(az), 0, sin(az)) * 0.1, size: size,
                     normal: SIMD3(cos(az), 0.1, sin(az)), roll: r.range(-0.1, 0.1), uv: medCypressUV,
                     crownCentre: SIMD3(0, yc, 0), crownRadii: SIMD3(R, R, R), height: H, ao: 0.8,
                     aspect: (pair ? 0.6 * w : w) / size, mirror: j == 1, hull: hull)
                if pair {
                    for i in first..<light.vertexCount { light.uv4[2 * i] += (Float(j) - 0.5) * 0.4 * w }
                }
            }
        }
        var a = TreeArchetype(form: .cypress, refHeight: H, refRadius: R, full: full, light: light)
        a.crownBase = y0
        a.limbTips = tips
        return a
    }

    // MARK: - Palms

    /// The leaflets' reach across cj_foliage_med's frond strip at `t` from
    /// its base (0) to its tip (1), as a share of the half width: the
    /// spines of the petiole, then leaflets longest a third of the way out
    /// (bake_riviera_plants.frond_strip), with a margin.
    static func frondWidth(_ t: Float) -> Float {
        if t < 0.16 { return 0.12 + 0.56 * t / 0.165 }
        let prof = (0.45 + 0.55 * min((t - 0.16) / 0.22, 1)) * (1 - max(t - 0.38, 0) / 0.62 * 0.72)
        return min(1, prof * 0.96 + 0.06)
    }

    /// The lowest height a `frond` from `base` reaches (its rachis, as
    /// `frond` steps it).
    static func frondLowest(base: SIMD3<Float>, elevation: Float, droop: Float, length: Float) -> Float {
        var y = base.y, low = base.y
        let steps = 30
        for k in 1...steps {
            let t = (Float(k) - 0.5) / Float(steps)
            y += sin(elevation - droop * t * t) * (length / Float(steps))
            low = min(low, y)
        }
        return low
    }

    /// A Canary palm frond (part 1): a ribbon along a rachis leaving `base`
    /// at `elevation` above the horizontal towards `dirH`, bending down by
    /// `droop` at its tip, `length` long; across it a V, the leaflets rising
    /// from the rachis by 25 degrees, as wide as they are drawn at each
    /// point of the strip, so none is cut. Its shading darkens towards the
    /// crown's heart. Two triangles a side per segment.
    static func frond(_ m: inout MeshBuffer, base: SIMD3<Float>, dirH: SIMD3<Float>, elevation: Float, droop: Float,
                      length: Float, segments: Int, twist: Float, crownCentre: SIMD3<Float>, height: Float, shade: Float) {
        let uv = medFrondUV
        let up = SIMD3<Float>(0, 1, 0)
        let sideH = SIMD3<Float>(-dirH.z, 0, dirH.x)
        let vMid = (uv.y + uv.w) / 2
        let half: Float = 0.625, vee: Float = 0.44
        var p = base
        var pts: [SIMD3<Float>] = [base]
        var tangents: [SIMD3<Float>] = []
        let steps = segments * 6
        func dir(_ t: Float) -> SIMD3<Float> {
            let e = elevation - droop * t * t
            return dirH * cos(e) + up * sin(e)
        }
        tangents.append(dir(0))
        for k in 1...steps {
            let t = (Float(k) - 0.5) / Float(steps)
            p += dir(t) * (length / Float(steps))
            if k % 6 == 0 {
                pts.append(p)
                tangents.append(dir(Float(k) / Float(steps)))
            }
        }
        let first = UInt32(m.vertexCount)
        for (i, q) in pts.enumerated() {
            let t = Float(i) / Float(segments)
            let T = tangents[i]
            var S = simd_normalize(sideH - T * simd_dot(sideH, T))
            var N = simd_normalize(simd_cross(S, T))
            let ct = cos(twist), st = sin(twist)
            (S, N) = (S * ct + N * st, N * ct - S * st)
            let w = half * frondWidth(t)
            let u = uv.x + (uv.z - uv.x) * (0.012 + 0.976 * t)
            let out = simd_normalize(q - crownCentre + SIMD3(0, 0.3, 0))
            let n = simd_normalize(N * 0.65 + out * 0.35)
            let corners: [(SIMD3<Float>, Float)] = [
                (q - S * (w * cos(vee)) + N * (w * sin(vee)), vMid - (vMid - uv.y) * (w / half)),
                (q, vMid),
                (q + S * (w * cos(vee)) + N * (w * sin(vee)), vMid + (uv.w - vMid) * (w / half)),
            ]
            for (c, v) in corners {
                m.vertex(c.x, c.y, c.z, n.x, n.y, n.z, u, v)
                m.texcoord2(swayWeight(y: c.y, height: height) + 0.3 * t * t, 0)
                m.texcoord3(shade * (0.55 + 0.45 * t), 0)
                m.texcoord4(0, 0)
            }
        }
        for i in 0..<UInt32(segments) {
            let a = first + i * 3, b = a + 3
            m.quad(a, a + 1, b + 1, b, part: 1)
            m.quad(a + 1, a + 2, b + 2, b + 1, part: 1)
        }
    }

    /// Canary Island date palm (Phoenix canariensis), the palm on the walls
    /// and at the summit: a thick, straight trunk of diamond leaf bases, a
    /// pineapple-like knob under a dense round crown of 60 arching fronds,
    /// the young ones rising, the old ones drooping. Variant 1 is younger
    /// (a short trunk), 2 leans.
    static func phoenixPalm(seed: UInt64, variant: Int) -> TreeArchetype {
        var r = WorldRandom(seed: seed)
        let Ht: Float = [6.4, 3.6, 5.2][variant % 3]
        let H = Ht + 4.3, R: Float = 5
        let la = r.range(0, 6.283)
        let topXZ = variant % 3 == 2 ? SIMD3<Float>(cos(la), 0, sin(la)) * 0.9 : .zero
        var full = MeshBuffer(parts: 2), light = MeshBuffer(parts: 2)
        let foot = SIMD3<Float>(0, -0.4, 0), top = SIMD3<Float>(0, Ht - 0.4, 0) + topXZ
        let via = SIMD3<Float>(0, Ht * 0.5, 0) + topXZ * 0.25
        limb(&full, foot, via, top, 0.44, 0.46, sides: 10, segments: 5, height: H)
        limb(&light, foot, via, top, 0.44, 0.46, sides: 6, segments: 2, height: H)
        // The knob of old leaf bases under the crown.
        let crown = SIMD3<Float>(top.x, Ht + 0.25, top.z)
        tube(&full, top - SIMD3(0, 0.2, 0), crown + SIMD3(0, 0.15, 0), 0.56, 0.36, sides: 10, height: H, vStart: Ht * 0.5)
        tube(&light, top - SIMD3(0, 0.2, 0), crown + SIMD3(0, 0.15, 0), 0.56, 0.36, sides: 6, height: H, vStart: Ht * 0.5)
        let count = 60
        for k in 0..<count {
            let az = Float(k) * 2.39996 + r.range(-0.15, 0.15)
            let age = Float(k) / Float(count - 1)
            var el = 1.2 - 1.75 * pow(age, 0.9) + r.range(-0.1, 0.1)
            let len = r.range(4.3, 5.2) * (0.72 + 0.28 * min(1, age / 0.2))
            let dirH = SIMD3<Float>(cos(az), 0, sin(az))
            let base = crown + dirH * 0.3 - SIMD3(0, 0.35 * age, 0)
            var droop = r.range(0.85, 1.2) * (0.6 + 0.4 * age)
            // On a young palm the old fronds rest on those below them,
            // their tips a metre clear of the ground, not in it.
            for _ in 0..<40 where frondLowest(base: base, elevation: el, droop: droop, length: len) < 1.2 {
                if droop > 0.05 { droop *= 0.8 } else { el += 0.1 }
            }
            let shade = 0.78 + 0.22 * (1 - age)
            let twist = r.range(-0.25, 0.25)
            frond(&full, base: base, dirH: dirH, elevation: el, droop: droop, length: len, segments: 5, twist: twist,
                  crownCentre: crown, height: H, shade: shade)
            if k % 3 == 0 {
                frond(&light, base: base, dirH: dirH, elevation: el, droop: droop, length: len, segments: 2, twist: twist,
                      crownCentre: crown, height: H, shade: shade)
            }
        }
        var a = TreeArchetype(form: .phoenixPalm, refHeight: H, refRadius: R, full: full, light: light)
        a.crownBase = Ht - 1.5
        a.limbTips = [crown]
        return a
    }

    /// A card from `uv` with its axes given: `right` and `up` (unit), centre
    /// `centre`, trimmed to `hull`, not turned to the viewer (a palm's fan,
    /// a hanging dead leaf, an agave's leaf print). Part 1.
    static func orientedCard(_ m: inout MeshBuffer, centre: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>, width: Float,
                             height cardH: Float, uv: SIMD4<Float>, hull: [SIMD2<Float>]?, normal: SIMD3<Float>, ao: Float,
                             treeHeight: Float, sway: Float = 0, baseY: Float = 0) {
        let cell: [SIMD2<Float>] = hull ?? [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1)]
        let first = UInt32(m.vertexCount)
        for t in cell {
            let u = uv.x + (uv.z - uv.x) * (t.x + 1) / 2
            let v = uv.w + (uv.y - uv.w) * (t.y + 1) / 2
            let p = centre + right * (t.x * width / 2) + up * (t.y * cardH / 2)
            m.vertex(p.x, p.y, p.z, normal.x, normal.y, normal.z, u, v)
            m.texcoord2(swayWeight(y: p.y - baseY, height: treeHeight) + sway * (t.y + 1) / 2, 0)
            m.texcoord3(ao, 0)
            m.texcoord4(0, 0)
        }
        for k in 1..<UInt32(cell.count - 1) { m.tri(first, first + k, first + k + 1, part: 1) }
    }

    /// A crown of palmate fans (part 1) on petioles (bark) from `crown`:
    /// the young ones rising, the old ones out and down, each fan face on
    /// to the side, its hastula on its petiole's end. Returns the petioles'
    /// ends.
    @discardableResult
    static func fanCrown(_ m: inout MeshBuffer, crown: SIMD3<Float>, count: Int, petiole: ClosedRange<Float>, size: ClosedRange<Float>,
                         height H: Float, light: Bool, r: inout WorldRandom) -> [SIMD3<Float>] {
        let up = SIMD3<Float>(0, 1, 0)
        var tips: [SIMD3<Float>] = []
        for k in 0..<count {
            let az = Float(k) * 2.39996 + r.range(-0.2, 0.2)
            let age = Float(k) / Float(max(count - 1, 1))
            let el = 1.25 - 1.85 * age + r.range(-0.12, 0.12)
            let dirH = SIMD3<Float>(cos(az), 0, sin(az))
            let d = dirH * cos(el) + up * sin(el)
            let len = r.range(petiole.lowerBound, petiole.upperBound)
            let base = crown + dirH * 0.12
            let tip = base + d * len
            if !light { tube(&m, base, tip, 0.045, 0.03, sides: 3, height: H) }
            // The blade: in the plane of the petiole and the horizontal
            // across it, bowed down a little by its weight.
            let across = SIMD3<Float>(-sin(az), 0, cos(az))
            let bladeUp = simd_normalize(d - up * 0.25)
            var n = simd_normalize(simd_cross(across, bladeUp))
            if simd_dot(n, dirH) + n.y < 0 { n = -n }
            let s = r.range(size.lowerBound, size.upperBound)
            let centre = tip + bladeUp * (0.06 * s)
            let shade = 0.62 + 0.38 * (1 - age) * (0.7 + 0.3 * max(d.y, 0))
            orientedCard(&m, centre: centre, right: across, up: bladeUp, width: s, height: s, uv: medFanUV, hull: medFanHull,
                         normal: simd_normalize(n * 0.7 + d * 0.3), ao: shade, treeHeight: H, sway: 0.15)
            tips.append(tip)
        }
        return tips
    }

    /// A skirt of dead fans hanging round the trunk under the crown
    /// (`ring` of them from `top` down `drop`). Part 1.
    static func deadSkirt(_ m: inout MeshBuffer, top: SIMD3<Float>, ring: Int, radius: Float, size: Float, height H: Float,
                          r: inout WorldRandom) {
        for k in 0..<ring {
            let az = Float(k) * 6.283 / Float(ring) + r.range(-0.25, 0.25)
            let out = SIMD3<Float>(cos(az), 0, sin(az))
            let across = SIMD3<Float>(-sin(az), 0, cos(az))
            let s = size * r.range(0.85, 1.15)
            let upv = simd_normalize(SIMD3(0, 1, 0) - out * 0.15)
            let attach = top + out * radius
            orientedCard(&m, centre: attach - upv * (0.44 * s), right: across, up: upv, width: s, height: s, uv: medDeadFanUV,
                         hull: medDeadFanHull, normal: simd_normalize(out + SIMD3(0, 0.2, 0)), ao: 0.6 * r.range(0.9, 1.1),
                         treeHeight: H)
        }
    }

    /// Fan palms. `tall`: Washingtonia, a slender grey trunk to 18 m, a
    /// skirt of dead leaves (variant 1 trimmed clean) and a small round
    /// crown of fans. Otherwise the windmill palm (Trachycarpus), a hairy
    /// brown trunk of 5 m under a ball of stiff fans, and in variant 2 a
    /// clump of dwarf fan palms (Chamaerops), a few short stems.
    static func fanPalm(seed: UInt64, variant: Int, tall: Bool) -> TreeArchetype {
        var r = WorldRandom(seed: seed)
        var full = MeshBuffer(parts: 2), light = MeshBuffer(parts: 2)
        let up = SIMD3<Float>(0, 1, 0)
        if !tall, variant % 3 == 2 {
            let H: Float = 3.2, R: Float = 1.6
            var tips: [SIMD3<Float>] = []
            for k in 0..<4 {
                let az = Float(k) * 1.7 + r.range(-0.3, 0.3)
                let out = SIMD3<Float>(cos(az), 0, sin(az))
                let foot = out * 0.25 + SIMD3(0, -0.3, 0)
                let top = foot + out * r.range(0.2, 0.6) + up * r.range(0.6, 2.1)
                tube(&full, foot, top, 0.13, 0.11, sides: 6, height: H)
                tube(&light, foot, top, 0.13, 0.11, sides: 4, height: H)
                tips += fanCrown(&full, crown: top, count: 9, petiole: 0.35...0.55, size: 0.6...0.8, height: H, light: false, r: &r)
                fanCrown(&light, crown: top, count: 4, petiole: 0.35...0.55, size: 0.75...0.9, height: H, light: true, r: &r)
            }
            var a = TreeArchetype(form: .fanPalm, refHeight: H, refRadius: R, full: full, light: light)
            a.crownBase = 0.4
            a.limbTips = tips
            return a
        }
        let Ht: Float = tall ? r.range(15.2, 16.4) : r.range(4.4, 5.2)
        let H = Ht + (tall ? 1.8 : 1.2), R: Float = tall ? 2.3 : 1.5
        let r0: Float = tall ? 0.26 : 0.13, r1: Float = tall ? 0.21 : 0.11
        let bend = SIMD3<Float>(r.range(-1, 1), 0, r.range(-1, 1)) * (tall ? 0.5 : 0.15)
        let foot = SIMD3<Float>(0, -0.4, 0), top = SIMD3<Float>(0, Ht, 0) + bend
        limb(&full, foot, SIMD3(0, Ht * 0.5, 0) + bend * 0.2, top, r0, r1, sides: 8, segments: 5, height: H)
        tube(&light, foot, top, r0, r1, sides: 5, height: H)
        if tall {
            // The flared foot.
            tube(&full, foot, SIMD3(0, 0.9, 0), r0 * 1.6, r0 * 1.05, sides: 8, height: H)
        }
        let skirt = tall ? variant % 2 == 0 : true
        if skirt {
            deadSkirt(&full, top: top - SIMD3(0, 0.1, 0), ring: tall ? 10 : 5, radius: r1 + 0.05, size: tall ? 1.9 : 0.9, height: H, r: &r)
            deadSkirt(&light, top: top - SIMD3(0, 0.1, 0), ring: 4, radius: r1 + 0.05, size: tall ? 2.0 : 0.95, height: H, r: &r)
        }
        // (A Washingtonia's crown is a dense ball of 30-odd fans: with
        // fewer it read as a parasol from the road.)
        let tips = fanCrown(&full, crown: top, count: tall ? 34 : 18, petiole: tall ? 1.0...1.5 : 0.5...0.8,
                            size: tall ? 1.4...1.75 : 0.85...1.05, height: H, light: false, r: &r)
        fanCrown(&light, crown: top, count: tall ? 14 : 7, petiole: tall ? 1.0...1.5 : 0.5...0.8, size: tall ? 1.6...1.9 : 1.0...1.15,
                 height: H, light: true, r: &r)
        var a = TreeArchetype(form: tall ? .washingtonia : .fanPalm, refHeight: H, refRadius: R, full: full, light: light)
        a.crownBase = Ht - (skirt ? 2.0 : 1.0)
        a.limbTips = tips
        return a
    }

    // MARK: - Norfolk Island pine and olive

    /// A Norfolk Island pine branch (part 1): `segments` lengths of
    /// cj_foliage_med's branch cell (tileable along u, so each length shows
    /// it whole) along a branch sagging a little and turning up at its tip,
    /// its section a shallow trough (the branchlets curve up), so from the
    /// side it is a shelf, not a line.
    static func araucariaBranch(_ m: inout MeshBuffer, from p0: SIMD3<Float>, dirH: SIMD3<Float>, length: Float, segments: Int,
                                halfWidth: Float, height H: Float, shade: Float) {
        let uv = medAraucariaUV
        let up = SIMD3<Float>(0, 1, 0)
        let side = SIMD3<Float>(-dirH.z, 0, dirH.x)
        func at(_ t: Float) -> SIMD3<Float> {
            p0 + dirH * (length * t) + up * (-0.12 * length * sin(.pi * t) * 0.5 + 0.45 * t * t * t)
        }
        let vMid = (uv.y + uv.w) / 2
        for i in 0..<segments {
            let first = UInt32(m.vertexCount)
            for j in 0...1 {
                let t = (Float(i) + Float(j)) / Float(segments)
                let q = at(t)
                let w = halfWidth * (1 - 0.35 * t)
                let n = simd_normalize(up * 0.8 + dirH * 0.35)
                let u = j == 0 ? uv.x : uv.z
                let corners: [(SIMD3<Float>, Float)] = [(q - side * w + up * (0.32 * w), uv.y), (q, vMid), (q + side * w + up * (0.32 * w), uv.w)]
                for (c, v) in corners {
                    m.vertex(c.x, c.y, c.z, n.x, n.y, n.z, u, v)
                    m.texcoord2(swayWeight(y: c.y, height: H) + 0.12 * t, 0)
                    m.texcoord3(shade * (0.6 + 0.4 * t), 0)
                    m.texcoord4(0, 0)
                }
            }
            m.quad(first, first + 1, first + 4, first + 3, part: 1)
            m.quad(first + 1, first + 2, first + 5, first + 4, part: 1)
        }
    }

    /// Norfolk Island pine (Araucaria heterophylla), the Riviera's
    /// signature conifer: a straight trunk and level tiers of five branches,
    /// closer near the top, the whole a narrow cone with sky between the
    /// tiers.
    static func araucaria(seed: UInt64) -> TreeArchetype {
        var r = WorldRandom(seed: seed)
        let H: Float = 20, R: Float = 4.2
        var full = MeshBuffer(parts: 2), light = MeshBuffer(parts: 2)
        tube(&full, SIMD3(0, -0.4, 0), SIMD3(0, H, 0), 0.34, 0.04, sides: 7, height: H)
        tube(&light, SIMD3(0, -0.4, 0), SIMD3(0, H, 0), 0.34, 0.04, sides: 5, height: H)
        let y0 = r.range(0.14, 0.24) * H
        var y = y0
        var tier = 0
        var tips: [SIMD3<Float>] = []
        while y < 0.97 * H {
            let t = (y - y0) / (H - y0)
            let reach = R * pow(1 - t, 0.85) * (t < 0.1 ? 0.8 + 2 * t : 1) + 0.35
            let a0 = Float(tier) * 0.63 + r.range(-0.2, 0.2)
            let shade = 0.72 + 0.28 * t
            for k in 0..<5 {
                let az = a0 + Float(k) * 1.2566 + r.range(-0.15, 0.15)
                let dirH = SIMD3<Float>(cos(az), 0, sin(az))
                let len = reach * r.range(0.85, 1.05)
                let from = SIMD3<Float>(0, y, 0) + dirH * 0.15
                let segs = len > 2.4 ? 3 : 2
                // (Branchlets 1.4 m across: at 1 m the tiers read as fishbones
                // beside the photos' dense dark shelves.)
                araucariaBranch(&full, from: from, dirH: dirH, length: len, segments: segs, halfWidth: 0.68, height: H, shade: shade)
                if k % 2 == 0 || k == 3 {
                    araucariaBranch(&light, from: from, dirH: dirH, length: len, segments: 1, halfWidth: 0.74, height: H, shade: shade)
                }
                if k == 0 { tips.append(from + dirH * len + SIMD3(0, 0.45, 0)) }
            }
            y += (1.15 - 0.5 * t) * r.range(0.9, 1.1)
            tier += 1
        }
        var a = TreeArchetype(form: .araucaria, refHeight: H, refRadius: R, full: full, light: light)
        a.crownBase = y0
        a.limbTips = tips
        return a
    }

    /// Olive (the Taggiasca of the Ligurian terraces): an open, rounded,
    /// silvery crown (`lobed`, as `spec` sets it) on a short, gnarled trunk
    /// splitting low into twisting stems.
    static func olive(seed: UInt64, towardsLane: Bool) -> TreeArchetype {
        var a = lobed(Form.olive.spec!, form: .olive, seed: seed, towardsLane: towardsLane)
        var r = WorldRandom(seed: seed ^ 0x0A11_CE)
        let base = a.crownBase
        // The swollen foot, then two or three stems twisting up into the
        // crown's lowest lobes.
        tube(&a.full, SIMD3(0, -0.3, 0), SIMD3(0, 0.9, 0), 0.34, 0.22, sides: 8, height: a.refHeight)
        tube(&a.light, SIMD3(0, -0.3, 0), SIMD3(0, 0.9, 0), 0.34, 0.22, sides: 5, height: a.refHeight)
        let low = a.lobes.dropLast().sorted { $0.c.y < $1.c.y }.prefix(3)
        for l in low {
            let from = SIMD3<Float>(r.range(-0.1, 0.1), 0.7, r.range(-0.1, 0.1))
            let to = l.c + simd_normalize(from - l.c) * (0.35 * l.r)
            let out = SIMD3<Float>(to.x, 0, to.z)
            let via = SIMD3<Float>(0, base * 0.6, 0) + out * 0.25 + SIMD3(r.range(-0.4, 0.4), 0, r.range(-0.4, 0.4))
            limb(&a.full, from, via, to, 0.15, 0.06, sides: 6, segments: 4, height: a.refHeight)
            tube(&a.light, from, to, 0.14, 0.06, sides: 4, height: a.refHeight)
            a.limbTips.append(to)
        }
        return a
    }
}

extension TreeArchetype.Form {
    /// The Riviera's forms, drawn only with its atlases.
    var isRiviera: Bool { rawValue >= Self.aleppoPine.rawValue }

    var rivieraVariants: Int {
        switch self {
        case .washingtonia, .araucaria, .eucalyptus: return 2
        default: return 3
        }
    }

    /// The lobed crowns among the Riviera's forms.
    var rivieraSpec: TreeArchetype.CrownSpec? {
        typealias S = TreeArchetype.CrownSpec
        switch self {
        case .olive:
            return S(leaf: TreeArchetype.medOliveUV, H: 7, R: 3.6, crownBase: 0.3, lobes: 7...10, lobeR: 0.3...0.42,
                     clumpsPerLobe: 13, cardSize: 1.0...1.4, gappiness: 0.5)
        case .holmOak:
            return S(leaf: TreeArchetype.medEvergreenUV, H: 12, R: 5.5, crownBase: 0.3, lobes: 7...10, lobeR: 0.32...0.46,
                     clumpsPerLobe: 18, cardSize: 1.5...2.1, gappiness: 0.15)
        case .eucalyptus:
            return S(leaf: TreeArchetype.medOliveUV, H: 22, R: 6, crownBase: 0.45, lobes: 5...7, lobeR: 0.28...0.38,
                     clumpsPerLobe: 11, cardSize: 1.8...2.6, gappiness: 0.6)
        default: return nil
        }
    }

    /// Cell in cj_impostor_med.png (4 x 2, bake_riviera_plants.py).
    var rivieraImpostorCell: Int {
        switch self {
        case .aleppoPine: return 0
        case .stonePine: return 1
        case .cypress: return 2
        case .phoenixPalm, .fanPalm: return 3
        case .washingtonia: return 4
        case .olive: return 5
        case .araucaria: return 6
        default: return 7
        }
    }

    /// The impostor quad's width over the tree's radius as scaled: the
    /// painted crowns fill their cells to about these shares.
    var impostorWidthFactor: Float {
        switch self {
        case .cypress: return 2.5
        case .washingtonia: return 2.35
        case .olive: return 2.2
        default: return 2.1
        }
    }

    var rivieraLeafColour: SIMD3<Float> {
        switch self {
        case .fanPalm: return SIMD3(0.82, 0.9, 0.82)
        // (Its tufts' light through them read yellow against the sun on
        // the start ramp, where the photos have near-black crowns.)
        case .aleppoPine: return SIMD3(0.84, 0.88, 0.88)
        case .holmOak: return SIMD3(0.88, 0.95, 0.9)
        case .eucalyptus: return SIMD3(0.92, 1.0, 1.12)
        default: return SIMD3(1, 1, 1)
        }
    }

    /// Least and most crown radius as a share of the height scale
    /// (`minSpread`, `maxSpread`).
    var rivieraSpread: ClosedRange<Float> {
        switch self {
        case .aleppoPine: return 0.45...1.6
        case .stonePine: return 0.5...1.5
        // (A LiDAR crown merges a cypress with its neighbours: at 1.6 the
        // sanctuary's columns were drawn 4-5 m across at 12 m, where the
        // photos have 2-3 m.)
        case .cypress: return 0.08...1.15
        case .phoenixPalm, .washingtonia, .fanPalm: return 0.3...1.2
        case .olive: return 0.5...1.6
        case .araucaria: return 0.15...1.2
        case .eucalyptus: return 0.3...1.5
        default: return 0.55...1.9
        }
    }

    /// The bark tile and how often it goes round the trunk.
    var medBark: (tile: TreeArchetype.MedBark, uScale: Float) {
        switch self {
        case .stonePine: return (.stonePine, 1.5)
        case .phoenixPalm: return (.phoenix, 3)
        case .washingtonia: return (.washingtonia, 1.5)
        case .fanPalm: return (.windmill, 1)
        case .olive, .holmOak: return (.olive, 1)
        // (A blue gum's smooth grey bark peeling in rust-brown strips is
        // the pine tile's; in the fan palm's ringed grey, an 18 m bare
        // bole read as a chimney at hairpin 1, reviews2.)
        default: return (.aleppo, 1)
        }
    }
}
