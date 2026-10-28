import Foundation
import simd

/// Landuse polygons with a bounding-box prefilter, for "what is here?".
struct LanduseIndex: Sendable {
    struct Poly: Sendable {
        let kind: String
        let ring: [SIMD2<Double>]
        let minE: Double, maxE: Double, minN: Double, maxN: Double
    }
    let polys: [Poly]

    init(_ landuse: [SceneryFile.Landuse]) {
        polys = landuse.compactMap { l in
            let ring = l.ring.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }
            guard ring.count >= 3 else { return nil }
            return Poly(kind: l.kind, ring: ring,
                        minE: ring.map(\.x).min()!, maxE: ring.map(\.x).max()!,
                        minN: ring.map(\.y).min()!, maxN: ring.map(\.y).max()!)
        }
    }

    func kind(east: Double, north: Double) -> String? {
        for p in polys where east >= p.minE && east <= p.maxE && north >= p.minN && north <= p.maxN {
            if Self.contains(p.ring, east, north) { return p.kind }
        }
        return nil
    }

    static func contains(_ ring: [SIMD2<Double>], _ x: Double, _ y: Double) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.y > y) != (b.y > y), x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}

/// Brooks and ditches (`scenery.water` of kind "stream"), for "is there
/// running water near here?".
struct StreamIndex: Sendable {
    private let segments: [(a: SIMD2<Double>, b: SIMD2<Double>)]

    init(_ water: [SceneryFile.Water]) {
        var segs: [(SIMD2<Double>, SIMD2<Double>)] = []
        for w in water where w.kind == "stream" {
            let pts = w.points.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }
            for i in pts.indices.dropLast() { segs.append((pts[i], pts[i + 1])) }
        }
        segments = segs
    }

    func near(east: Double, north: Double, within d: Double) -> Bool {
        let p = SIMD2(east, north)
        for (a, b) in segments {
            if p.x < min(a.x, b.x) - d || p.x > max(a.x, b.x) + d || p.y < min(a.y, b.y) - d || p.y > max(a.y, b.y) + d { continue }
            let ab = b - a
            let t = min(max(simd_dot(p - a, ab) / max(simd_dot(ab, ab), 1e-9), 0), 1)
            if simd_distance(p, a + ab * t) < d { return true }
        }
        return false
    }
}

/// Tree crowns on a 6 m grid, for "how crowded is this tree?".
struct TreeCrowding: Sendable {
    private var cells: [Int: [SIMD2<Double>]] = [:]
    private static let cellM = 6.0

    init(_ trees: [SceneryFile.Tree]) {
        for t in trees { cells[Self.key(t.e, t.n), default: []].append(SIMD2(t.e, t.n)) }
    }

    private static func key(_ e: Double, _ n: Double) -> Int {
        Int(floor((n + 4000) / cellM)) * 10_000 + Int(floor((e + 4000) / cellM))
    }

    /// Other crowns within `d` (up to 6 m) of a tree's own position.
    func neighbours(east: Double, north: Double, within d: Double) -> Int {
        let p = SIMD2(east, north)
        var count = 0
        for dz in -1...1 {
            for dx in -1...1 {
                let k = Self.key(east, north) + dz * 10_000 + dx
                for o in cells[k] ?? [] where o != p && simd_distance(o, p) < d { count += 1 }
            }
        }
        return count
    }
}

/// The course's baked sky visibility (`<id>_light.rgbz`, red; see
/// WorldMaterials+Light) on the CPU, at 1 px per metre, so the plants can be
/// shaded as the raster shades the ground under them, at no cost on the GPU.
/// The canopy height (blue) tells where a plant's own crown is in it.
struct SkyRaster: Sendable {
    private let sky: [UInt8]
    /// Canopy height over the ground, 255 = 40 m; empty for none anywhere.
    private let canopy: [UInt8]
    private let width: Int, height: Int
    private let originEast: Double, originNorth: Double
    private let metresPerPixel: Double
    /// The ground's floor on sky visibility (`WorldMaterials.lightK`'s w).
    let minSky: Float

    init(sky: [UInt8], canopy: [UInt8] = [], width: Int, height: Int, originEast: Double, originNorth: Double,
         metresPerPixel: Double, minSky: Float) {
        self.sky = sky
        self.canopy = canopy.count == sky.count ? canopy : []
        self.width = width; self.height = height
        self.originEast = originEast; self.originNorth = originNorth
        self.metresPerPixel = metresPerPixel
        self.minSky = minSky
    }

    /// From the course's raster as the world build decodes it (once, for
    /// the lane meter and the GPU too: `CourseWorldBuilder`). Nil without
    /// one, as with `-lightRasterOff`.
    init?(pixels: WorldTextures.Pixels?, bundle: CourseBundle, config: WorldConfig) {
        #if DEBUG
        // -plantSkyOff: plants unshaded by the raster, to judge it against
        // none in the same build.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-lightRasterOff") || args.contains("-plantSkyOff") { return nil }
        #endif
        guard let raw = pixels, raw.width > 1, raw.height > 1 else { return nil }
        var red = [UInt8](repeating: 0, count: raw.width * raw.height)
        var blue = red
        raw.rgba.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for i in 0..<red.count {
                red[i] = p[4 * i]
                blue[i] = p[4 * i + 2]
            }
        }
        let t = bundle.terrainNear
        self.init(sky: red, canopy: blue, width: raw.width, height: raw.height, originEast: t.originEast,
                  originNorth: t.originNorth, metresPerPixel: t.widthM / Double(raw.width),
                  minSky: WorldMaterials.skyFloor(config))
    }

    /// Sky visibility at a point, as the ground shader reads it: filtered,
    /// fading to open sky over the raster's last 2 %, 1 off it, and never
    /// under `minSky`.
    func visibility(east: Double, north: Double) -> Float {
        let u = (east - originEast) / (metresPerPixel * Double(width))
        let v = (originNorth - north) / (metresPerPixel * Double(height))
        let edge = min(min(u, 1 - u), min(v, 1 - v))
        guard edge > 0 else { return 1 }
        let fx = u * Double(width) - 0.5, fy = v * Double(height) - 0.5
        let x0 = min(max(Int(fx.rounded(.down)), 0), width - 2), y0 = min(max(Int(fy.rounded(.down)), 0), height - 2)
        let tx = Float(min(max(fx - Double(x0), 0), 1)), ty = Float(min(max(fy - Double(y0), 0), 1))
        let k = y0 * width + x0
        let top = Float(sky[k]) * (1 - tx) + Float(sky[k + 1]) * tx
        let bottom = Float(sky[k + width]) * (1 - tx) + Float(sky[k + width + 1]) * tx
        let s = (top * (1 - ty) + bottom * ty) / 255
        let t = Float(min(edge / 0.02, 1)), fade = t * t * (3 - 2 * t)
        return max(1 + (s - 1) * fade, minSky)
    }

    /// Whether the nearest texel has canopy over 0.5 m: what the bake
    /// counts as leaves.
    func hasCanopy(east: Double, north: Double) -> Bool {
        guard !canopy.isEmpty else { return false }
        let x = Int(floor((east - originEast) / metresPerPixel))
        let y = Int(floor((originNorth - north) / metresPerPixel))
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        return Float(canopy[y * width + x]) * 40 / 255 > 0.5
    }

    /// The sky a plant of crown radius `radius` stands in, less its own
    /// crown. The bake counts every crown as an occluder, the one straight
    /// over the receiver included, so the sky at a tree's foot is mostly its
    /// own crown, which the leaves already carry
    /// (`TreeArchetype.skyVisibility`). Where the foot is under canopy, this
    /// takes the upper quartile of the sky on a ring 1.5 radii out (at
    /// least 1.5 m), clear of the crown overhead: in a lane or a wood the
    /// ring is shaded all round, at a wood's edge its open side counts.
    /// Never darker than the foot; in the open, the foot.
    func plantSky(east: Double, north: Double, radius: Double) -> Float {
        let foot = visibility(east: east, north: north)
        guard radius > 0, hasCanopy(east: east, north: north) else { return foot }
        let d = max(1.5 * radius, 1.5)
        var ring = (0..<8).map { k -> Float in
            let a = Double(k) * .pi / 4
            return visibility(east: east + d * cos(a), north: north + d * sin(a))
        }
        ring.sort()
        return max(foot, ring[5] + (ring[6] - ring[5]) * 0.25)
    }
}

/// Places trees, shrubs, the sunken lane's bank plants and the verge grass.
///
/// Trees and shrubs are merged into 48 m clusters, each with three levels
/// of detail (full, light, impostor) that SceneKit switches by camera
/// distance. Grass is cut into short route sections that the frame updater
/// shows only near the camera.
///
/// A cluster is taken out of the dictionary while plants are added to it
/// (`take`), so its buffers grow in place instead of being copied whole on
/// every append. A cancelled task gets back what was placed so far.
///
/// With the course's light raster (`sky`), every plant is shaded by the
/// sky it stands in, less its own crown (`SkyRaster.plantSky`), opening
/// to the full sky at its top (`skyShade`), so the plants in a holle weg
/// or a wood are as dim as the ground there and those in the open keep
/// their light.
enum VegetationBuilder {
    struct Cluster {
        var full = MeshBuffer(parts: 2)
        var light = MeshBuffer(parts: 2)
        var impostor = MeshBuffer(parts: 2)
    }

    struct Output {
        var clusters: [Cluster] = []
        /// Clipped hedges: part 0 bark (none), part 1 their cores and leaves.
        var hedges = MeshBuffer(parts: 2)
        var grassCells: [(s: Double, mesh: MeshBuffer)] = []
        var counts: [String: Int] = [:]
    }

    static let clusterSize = 48.0
    /// Length of a streamed verge-grass section, metres of route.
    static let grassCellM = 4.0

    /// Least height of a lane-side crown's leaves over the road: above the
    /// rider and the chase camera (3.5 m).
    static let laneLeafClearance: Float = 4

    static func build(corridor: RoadCorridor, scenery: SceneryFile?, config: WorldConfig,
                      ground: GroundColor? = nil, sky: SkyRaster? = nil) -> Output {
        var out = Output()
        /// `skyShade` with the sky a plant of crown radius `radius` stands
        /// in at (east, north); radius 0 (ivy lying on the bank) takes the
        /// sky at that point.
        func shadeBySky(_ m: inout MeshBuffer, from first: Int, east: Double, north: Double, baseY: Float, height: Float,
                        radius: Float = 0) {
            guard let sky else { return }
            skyShade(&m, from: first, sky: sky.plantSky(east: east, north: north, radius: Double(radius)),
                     baseY: baseY, height: height)
        }
        let landuse = LanduseIndex(scenery?.landuse ?? [])
        let terrain = corridor.terrain
        var clusters: [Int: Cluster] = [:]
        func key(_ e: Double, _ n: Double) -> Int {
            let cx = Int(floor((e + 4000) / clusterSize)), cz = Int(floor((n + 4000) / clusterSize))
            return cz * 10_000 + cx
        }
        /// The cluster for a key, removed from the dictionary so it is
        /// uniquely referenced while it grows; put it back with `clusters[k] = c`.
        func take(_ k: Int) -> Cluster {
            clusters.removeValue(forKey: k) ?? Cluster()
        }
        func finish() -> Output {
            out.clusters = Array(clusters.values).filter { !$0.light.isEmpty || !$0.full.isEmpty }
            return out
        }
        let sideRoads = RoadBuilder.SideRoadMask(scenery: scenery)
        let near = corridor.near
        let nearRaster = terrain.near
        /// Lateral push-off from the carriageway at a point, or nil if the
        /// point is clear of it.
        func roadClearance(_ e: Double, _ n: Double, margin: Double) -> (dE: Double, dN: Double)? {
            let col = Int(floor((e - nearRaster.originEast) / nearRaster.cellM))
            let row = Int(floor((nearRaster.originNorth - n) / nearRaster.cellM))
            guard let f = near.lookup(col: col, row: row) else { return nil }
            let st = corridor.station(f.segment, Double(f.fraction))
            let need = st.halfWidth + margin
            let d = Double(f.dist)
            guard d < need else { return nil }
            let side: Double = f.lateral >= 0 ? 1 : -1
            let push = (need - d) * side
            return (st.rightE * push, st.rightN * push)
        }

        // Trees.
        let library = TreeLibrary()
        let streams = StreamIndex(scenery?.water ?? [])
        let crowns = TreeCrowding(scenery?.trees ?? [])
        var nFull = 0, nLight = 0, nLane = 0
        var formCounts = [Int](repeating: 0, count: TreeArchetype.Form.allCases.count)
        for t in (scenery?.trees ?? []) + extraTrees(corridor) {
            if Task.isCancelled { return finish() }
            var e = t.e, n = t.n
            let crowded = crowns.neighbours(east: t.e, north: t.n, within: 6) >= 3
            let q = corridor.coarse.query(east: e, north: n)
            // (Any distance from the route: the road's extensions past its
            // ends are in the near field too.)
            if let push = roadClearance(e, n, margin: 1.1) {
                e += push.dE; n += push.dN
            }
            let y = Float(terrain.height(east: e, north: n))
            guard y.isFinite else { continue }
            var rnd = WorldRandom(e, n, salt: 17)
            let h = Float(t.heightM)
            let lu = landuse.kind(east: e, north: n)
            let sunk = corridor.art.sunkenWeight(q.s)
            let stQ = corridor.station(at: q.s)
            let treeSide: Double = (e - stQ.east) * stQ.rightE + (n - stQ.north) * stQ.rightN >= 0 ? 1 : -1
            let form = corridor.art.isPollard(s: q.s, side: treeSide, routeDistance: q.dist, height: Double(h)) ? .willow
                : pickForm(kind: t.kind, h: h, r: Float(t.crownRadiusM), landuse: lu, sunk: sunk,
                           nearStream: streams.near(east: e, north: n, within: 8), crowded: crowded, rnd: &rnd)
            // Leaf-off LiDAR (February) under-measures a hybrid poplar's
            // broad crown.
            let r = form == .hybridPoplar ? max(Float(t.crownRadiusM), 0.22 * h) : Float(t.crownRadiusM)
            var yaw = rnd.range(0, 6.283)
            let phase = rnd.range(0, 6.283)
            let yellowing = max(0, rnd.range(-0.25, 0.55))
            let shade = rnd.range(0.93, 1.07)
            var colour = form.leafColour * shade
            if form != .copperBeech { colour *= SIMD3(1, 1, 1) + (SIMD3(1.16, 1.06, 0.72) - SIMD3(1, 1, 1)) * yellowing }
            let tint = TreeArchetype.packColour(colour)
            let x = Float(e), z = Float(-n)
            /// Height and crown-width scales of an archetype for this tree.
            func scales(_ a: TreeArchetype) -> (sy: Float, sxz: Float) {
                let sy = h / a.refHeight
                return (sy, min(max(r / a.refRadius, sy * form.minSpread), sy * 1.9))
            }
            // On the holle weg's banks the trees reach out over the lane
            // for light, closing the tunnel above the steepest part; those
            // right beside it grow their crowns towards it too (turned so
            // their lane side faces the road), where that keeps their
            // leaves clear of the rider and the camera: most of them stand
            // at the road's level, not on the bank top.
            var lean = SIMD2<Float>.zero
            var laneArch: TreeArchetype?
            if sunk > 0.2, q.dist < 16 {
                let st = corridor.station(at: q.s)
                let side: Double = ((e - st.east) * st.rightE + (n - st.north) * st.rightN) >= 0 ? 1 : -1
                let amount = Float(sunk) * min(0.35 * r, 2.5) * (1 - Float(q.dist) / 20)
                let toRoad = SIMD2<Float>(Float(-st.rightE * side), Float(st.rightN * side))
                // (A Lombardy column stays nearly upright.)
                lean = toRoad * amount * (form == .lombardy ? 0.3 : 1)
                if q.dist < 7, form.spec != nil {
                    // (The same draw as the plain pick below.)
                    var laneRnd = rnd
                    let a = library.pick(form, &laneRnd, towardsLane: true)
                    let k = scales(a)
                    if y + a.lowestLeaf(laneSide: true, sy: k.sy, cardScale: (k.sxz + k.sy) / 2) >= Float(st.elev) + laneLeafClearance {
                        laneArch = a
                        rnd = laneRnd
                        yaw = atan2(-toRoad.y, toRoad.x) + (yaw - 3.14) * 0.1
                    }
                }
            }
            let arch = laneArch ?? library.pick(form, &rnd)
            let (sy, sxz) = scales(arch)
            let ck = key(e, n)
            var c = take(ck)
            let skyHere = sky?.plantSky(east: e, north: n, radius: t.crownRadiusM) ?? 1
            if q.dist < config.treeDetailRouteRadius {
                appendPlant(&c.full, arch.full, sx: sxz, sy: sy, yaw: yaw, x: x, y: y, z: z, phase: phase, tint: tint,
                            lean: lean, height: h, sky: skyHere)
                nFull += 1
            }
            appendPlant(&c.light, arch.light, sx: sxz, sy: sy, yaw: yaw, x: x, y: y, z: z, phase: phase,
                        tint: tint, lean: lean, height: h, sky: skyHere)
            nLight += 1
            if laneArch != nil { nLane += 1 }
            formCounts[form.rawValue] += 1
            impostor(&c.impostor, cell: form.impostorCell, width: max(2.1 * r, h * 0.25), height: h * 1.02,
                     x: x, y: y - 0.2, z: z, yaw: yaw, phase: phase, tint: tint, sky: skyHere)
            clusters[ck] = c
        }
        for f in TreeArchetype.Form.allCases where formCounts[f.rawValue] > 0 {
            out.counts["trees: \(f)"] = formCounts[f.rawValue]
        }
        out.counts["trees towards the lane"] = nLane
        out.counts["trees full"] = nFull
        out.counts["trees"] = nLight

        // Shrubs and hedges.
        var nShrubD = 0, nShrubL = 0
        for (i, sh) in (scenery?.shrubs ?? []).enumerated() {
            if i % 256 == 0, Task.isCancelled { return finish() }
            let q = corridor.coarse.query(east: sh.e, north: sh.n)
            if q.dist > config.shrubMaxRouteRadius { continue }
            if roadClearance(sh.e, sh.n, margin: 0.25) != nil { continue }
            let y = Float(terrain.height(east: sh.e, north: sh.n))
            guard y.isFinite else { continue }
            var rnd = WorldRandom(sh.e, sh.n, salt: 29)
            let sunken = corridor.art.sunkenWeight(q.s) > 0.4 && q.dist < 16
            let uv = TreeArchetype.broadUV
            let shrubTint: Float = sunken ? -0.15 : 0
            let r = Float(sh.radiusM) * 1.25, h = Float(sh.heightM) * 1.1
            let centre = SIMD3<Float>(Float(sh.e), y + h * 0.5, Float(-sh.n))
            let radii = SIMD3<Float>(r, h * 0.5, r)
            let phase = rnd.range(0, 6.28), tint = max(0, rnd.range(-0.3, 0.35) + shrubTint)
            let ck = key(sh.e, sh.n)
            var c = take(ck)
            if q.dist < config.shrubDetailRouteRadius {
                // Several smaller cards through the shrub's volume give a
                // lumpy, leafy outline instead of one disc.
                let first = c.full.vertexCount
                let span = max(2 * r, h)
                let cards = min(9, max(3, Int((span * span * 1.6).rounded())))
                let cardSize = max(0.9, span * 0.62)
                for _ in 0..<cards {
                    let d = TreeArchetype.randomDir(&rnd, minY: -0.3)
                    let reach = rnd.range(0.15, 0.6)
                    let o: SIMD3<Float> = (d * radii) * reach
                    // Clumps have no "up": any roll, either way round.
                    let cuv = sunken && rnd.unit() < 0.5 ? TreeArchetype.ivyUV : uv
                    TreeArchetype.card(&c.full, centre: centre + o, size: cardSize * rnd.range(0.85, 1.15), normal: d,
                                       roll: rnd.range(0, 6.283), uv: cuv,
                                       crownCentre: centre - SIMD3(0, h * 0.3, 0), crownRadii: radii, height: max(h, 2) * 3,
                                       ao: 0.88, bend: 0.6, baseY: y, mirror: rnd.unit() < 0.5, hull: TreeArchetype.hull(for: cuv))
                }
                patchPhase(&c.full, from: first, phase: phase, tint: tint)
                shadeBySky(&c.full, from: first, east: sh.e, north: sh.n, baseY: y, height: h, radius: r)
                nShrubD += 1
            }
            let firstL = c.light.vertexCount
            for k in 0..<2 {
                let az = rnd.range(0, 3.14) + Float(k) * 1.57
                // (Upright, the atlas's clump read as the same heart shape
                // all over the fields.)
                TreeArchetype.card(&c.light, centre: centre, size: max(2 * r, h) * 1.1, normal: SIMD3(cos(az), 0.2, sin(az)),
                                   roll: rnd.range(0, 6.283), uv: uv, crownCentre: centre - SIMD3(0, h * 0.3, 0), crownRadii: radii,
                                   height: max(h, 2) * 3, ao: 0.85, bend: 0.6, baseY: y, mirror: k == 1)
            }
            patchPhase(&c.light, from: firstL, phase: phase, tint: tint)
            shadeBySky(&c.light, from: firstL, east: sh.e, north: sh.n, baseY: y, height: h, radius: r)
            nShrubL += 1
            clusters[ck] = c
        }
        out.counts["shrubs detailed"] = nShrubD
        out.counts["shrubs"] = nShrubL

        // The holle weg's banks: ivy creeping over the earth, cushions of
        // ivy and bramble along the bank tops (the silhouette against the
        // sky), brambles arching over the stones at the foot and coppice
        // stools above. Everything is small and ragged-edged; the cushions
        // face the viewer, so no card is ever seen edge-on. Brambles and
        // stools need a measured bank on their side (`bankTop`): a span can
        // be open on one side, and nothing grows on a side road.
        var nBank = 0, nBankShrub = 0
        if config.bankPlantDensity > 0 {
            var rnd = WorldRandom(seed: 4242)
            // Its own sequence, so the other bank plants stay where they were.
            var shrubRnd = WorldRandom(seed: 4343)
            let step = 0.55 / config.bankPlantDensity
            for span in corridor.art.sunkenLane {
                var s = span.lowerBound - 10
                while s < span.upperBound + 10 {
                    if Task.isCancelled { return finish() }
                    let st = corridor.station(at: s)
                    let w = corridor.art.sunkenWeight(s)
                    for side in [-1.0, 1.0] {
                        let verge = side > 0 ? st.vergeRight : st.vergeLeft
                        let top = bankTop(corridor, st, side: side, maxOffset: min(verge - 0.5, 8))
                        let toRoad = SIMD3<Float>(Float(-st.rightE * side), 0, Float(st.rightN * side))
                        // Ivy lying on the bank face.
                        for _ in 0..<3 where Double(rnd.unit()) < w {
                            let oMax = top.map { $0.offset + 0.4 } ?? min(4.0, verge - 0.5)
                            guard oMax > 0.3 else { continue }
                            let o = Double(rnd.range(0.2, Float(oMax)))
                            let p = RoadBuilder.vergePoint(corridor, st, side: side, offset: o)
                            guard p.y - p.edgeY > 0.15, !sideRoads.covers(east: p.east, north: p.north) else { continue }
                            let pn = surfaceNormal(corridor, st, side: side, offset: o)
                            let pos = SIMD3<Float>(Float(p.east), Float(p.y), Float(-p.north)) + pn * rnd.range(0.04, 0.1)
                            let tilt = simd_normalize(pn + TreeArchetype.randomDir(&rnd) * 0.25)
                            let ck = key(p.east, p.north)
                            var cl = take(ck)
                            let first = cl.full.vertexCount
                            TreeArchetype.card(&cl.full, centre: pos, size: rnd.range(0.75, 1.3), normal: tilt, roll: rnd.range(0, 6.28),
                                               uv: TreeArchetype.ivyUV, crownCentre: pos - pn * 0.6, crownRadii: SIMD3(1, 1, 1),
                                               height: 3, ao: rnd.range(0.82, 0.95), bend: 0.35, baseY: pos.y - 1, billboard: false,
                                               mirror: rnd.unit() < 0.5, hull: TreeArchetype.ivyHull)
                            patchPhase(&cl.full, from: first, phase: rnd.range(0, 6.28), tint: rnd.range(0, 0.12))
                            shadeBySky(&cl.full, from: first, east: p.east, north: p.north, baseY: Float(p.y), height: 1)
                            clusters[ck] = cl
                            nBank += 1
                        }
                        // Cushions along the bank top, two or three cards each.
                        if let top, Double(rnd.unit()) < 0.85 * w,
                           case let p = RoadBuilder.vergePoint(corridor, st, side: side,
                                                               offset: max(0.3, top.offset + Double(rnd.range(-0.7, 0.5)))),
                           !sideRoads.covers(east: p.east, north: p.north) {
                            let size = rnd.range(0.9, 1.5)
                            let base = SIMD3<Float>(Float(p.east), Float(p.y), Float(-p.north))
                            let ck = key(p.east, p.north)
                            var cl = take(ck)
                            let first = cl.full.vertexCount
                            let cards = 2 + Int(rnd.unit() * 2)
                            for k in 0..<cards {
                                let jitter = SIMD3<Float>(rnd.range(-0.35, 0.35), size * rnd.range(0.25, 0.45), rnd.range(-0.35, 0.35))
                                let lean: SIMD3<Float> = toRoad * (Float(k) * 0.12)
                                let c = base + jitter + lean
                                let cuv = rnd.unit() < 0.65 ? TreeArchetype.ivyUV : TreeArchetype.broadUV
                                TreeArchetype.card(&cl.full, centre: c, size: size * rnd.range(0.8, 1.05), normal: TreeArchetype.randomDir(&rnd, minY: -0.2),
                                                   roll: rnd.range(0, 6.283), uv: cuv,
                                                   crownCentre: base, crownRadii: SIMD3(size, size * 0.7, size), height: 3,
                                                   ao: rnd.range(0.8, 0.95), bend: 0.6, baseY: base.y, mirror: rnd.unit() < 0.5,
                                                   hull: TreeArchetype.hull(for: cuv))
                            }
                            patchPhase(&cl.full, from: first, phase: rnd.range(0, 6.28), tint: rnd.range(0.05, 0.25))
                            shadeBySky(&cl.full, from: first, east: p.east, north: p.north, baseY: base.y, height: size,
                                       radius: size)
                            clusters[ck] = cl
                            nBank += 1
                        }
                        // Brambles at the foot, leaning out over the stones:
                        // only below a real bank, never on an open field edge.
                        let brambleRoll = Double(rnd.unit())
                        let brambleO = Double(rnd.range(0.15, 0.9))
                        let brambleP = RoadBuilder.vergePoint(corridor, st, side: side, offset: brambleO)
                        if let top, top.rise > 0.5, brambleRoll < 0.6 * w,
                           !sideRoads.covers(east: brambleP.east, north: brambleP.north) {
                            let p = brambleP
                            let size = rnd.range(0.55, 0.95)
                            let base = SIMD3<Float>(Float(p.east), Float(p.y), Float(-p.north))
                            let ck = key(p.east, p.north)
                            var cl = take(ck)
                            let first = cl.full.vertexCount
                            for k in 0..<2 {
                                let lift = SIMD3<Float>(0, size * (0.32 + 0.12 * Float(k)), 0)
                                let lean: SIMD3<Float> = toRoad * (0.1 + Float(k) * 0.12)
                                let c = base + lift + lean
                                TreeArchetype.card(&cl.full, centre: c, size: size, normal: TreeArchetype.randomDir(&rnd, minY: 0),
                                                   roll: rnd.range(-0.6, 0.6), uv: k == 0 ? TreeArchetype.ivyUV : TreeArchetype.broadUV,
                                                   crownCentre: base, crownRadii: SIMD3(size, size, size), height: 2,
                                                   ao: rnd.range(0.78, 0.9), bend: 0.5, baseY: base.y)
                            }
                            patchPhase(&cl.full, from: first, phase: rnd.range(0, 6.28), tint: 0.12)
                            shadeBySky(&cl.full, from: first, east: p.east, north: p.north, baseY: base.y, height: size,
                                       radius: size)
                            clusters[ck] = cl
                            nBank += 1
                        }
                        // Coppice stools on the bank tops: hazel bushes of a few
                        // near-upright stems, leafy along most of their height.
                        let stoolRoll = Double(rnd.unit())
                        if config.quality != .battery, let top, stoolRoll < 0.09 * w {
                            let o = top.offset + Double(rnd.range(0.3, 1.5))
                            let p = RoadBuilder.vergePoint(corridor, st, side: side, offset: min(o, verge - 0.8))
                            let base = SIMD3<Float>(Float(p.east), Float(p.y) - 0.2, Float(-p.north))
                            let ck = key(p.east, p.north)
                            var cl = take(ck)
                            let first = cl.full.vertexCount
                            let stems = 3 + Int(rnd.unit() * 3)
                            let bush = rnd.range(1.8, 3.2)
                            for _ in 0..<stems {
                                let hgt = bush * rnd.range(0.75, 1.05)
                                let dir = simd_normalize(SIMD3<Float>(rnd.range(-0.12, 0.12), 1, rnd.range(-0.12, 0.12)) + toRoad * 0.08)
                                let foot = base + SIMD3(rnd.range(-0.2, 0.2), 0, rnd.range(-0.2, 0.2))
                                let tip = foot + dir * hgt
                                TreeArchetype.tube(&cl.full, foot, tip, rnd.range(0.03, 0.05), 0.015, sides: 4, height: hgt, baseY: base.y)
                                for _ in 0..<(5 + Int(rnd.unit() * 2)) {
                                    let at = foot + dir * (hgt * rnd.range(0.3, 1.0))
                                    TreeArchetype.card(&cl.full, centre: at, size: rnd.range(0.7, 1.1),
                                                       normal: TreeArchetype.randomDir(&rnd, minY: -0.2),
                                                       roll: rnd.range(0, 6.28), uv: TreeArchetype.broadUV,
                                                       crownCentre: foot + dir * (hgt * 0.6),
                                                       crownRadii: SIMD3(0.9, hgt * 0.5, 0.9), height: hgt, ao: 0.9, baseY: base.y)
                                }
                            }
                            patchPhase(&cl.full, from: first, phase: rnd.range(0, 6.28), tint: 0.15)
                            shadeBySky(&cl.full, from: first, east: p.east, north: p.north, baseY: base.y, height: bush,
                                       radius: 1)
                            clusters[ck] = cl
                            nBank += 1
                        }
                        // Shrubs on the steep faces (over 30 degrees, within
                        // 8 m of the road), so a bank reads as overgrown
                        // earth rather than one smooth slope.
                        let shrubO = min(8.0, verge - 0.3)
                        if w > 0.4, shrubO > 0.6, Double(shrubRnd.unit()) < 0.7 * w {
                            let o = Double(shrubRnd.range(0.4, Float(shrubO)))
                            let p = RoadBuilder.vergePoint(corridor, st, side: side, offset: o)
                            let pn = surfaceNormal(corridor, st, side: side, offset: o)
                            if pn.y < 0.866, !sideRoads.covers(east: p.east, north: p.north) {
                                let rad = shrubRnd.range(0.45, 0.95), hgt = shrubRnd.range(0.7, 1.5)
                                let base = SIMD3<Float>(Float(p.east), Float(p.y), Float(-p.north))
                                let centre = base + SIMD3(0, hgt * 0.4, 0) + pn * 0.12
                                let radii = SIMD3<Float>(rad, hgt * 0.5, rad)
                                let ck = key(p.east, p.north)
                                var cl = take(ck)
                                let first = cl.full.vertexCount
                                for _ in 0..<(3 + Int(shrubRnd.unit() * 3)) {
                                    let d = TreeArchetype.randomDir(&shrubRnd, minY: -0.3)
                                    let size = max(rad, hgt * 0.5) * shrubRnd.range(1.1, 1.5)
                                    let roll = shrubRnd.range(0, 6.283)
                                    let cuv = shrubRnd.unit() < 0.45 ? TreeArchetype.ivyUV : TreeArchetype.broadUV
                                    TreeArchetype.card(&cl.full, centre: centre + d * radii * shrubRnd.range(0.15, 0.6),
                                                       size: size, normal: d, roll: roll, uv: cuv,
                                                       crownCentre: centre - SIMD3(0, hgt * 0.3, 0), crownRadii: radii,
                                                       height: max(hgt, 2) * 3, ao: shrubRnd.range(0.8, 0.92), bend: 0.6,
                                                       baseY: base.y, mirror: shrubRnd.unit() < 0.5, hull: TreeArchetype.hull(for: cuv))
                                }
                                patchPhase(&cl.full, from: first, phase: shrubRnd.range(0, 6.28), tint: shrubRnd.range(0, 0.2))
                                shadeBySky(&cl.full, from: first, east: p.east, north: p.north, baseY: base.y, height: hgt,
                                           radius: rad)
                                clusters[ck] = cl
                                nBankShrub += 1
                            }
                        }
                    }
                    s += step
                }
            }
        }
        out.counts["bank plants"] = nBank
        out.counts["bank shrubs"] = nBankShrub
        out.clusters = Array(clusters.values).filter { !$0.light.isEmpty || !$0.full.isEmpty }

        buildHedges(corridor: corridor, sideRoads: sideRoads, sky: sky, into: &out.hedges)
        out.counts["hedge metres"] = Int(corridor.art.hedges.reduce(0) { $0 + $1.span.upperBound - $1.span.lowerBound })

        // Verge grass, in short route sections; none on side-road tarmac:
        // tufts (grass, flowers, nettles), the sward (a row of short tufts
        // over the road's edge, ribbons of rough grass beyond the mown
        // strip), and in the holle weg nettle beds at the foot of the banks
        // and ferns on their shaded faces.
        if config.grassDensity > 0 {
            var rnd = WorldRandom(seed: 777)
            // Their own sequences: changing the sward or the bank flora
            // leaves the tufts where they are, and each other.
            var finRnd = WorldRandom(seed: 778)
            var floraRnd = WorldRandom(seed: 779)
            let cell = grassCellM
            var s0 = 0.0
            var tufts = 0, fins = 0, flora = 0
            let toSunH = simd_normalize(SIMD3<Float>(WorldSun.toSun.x, 0, WorldSun.toSun.z))
            while s0 < corridor.route.length {
                if Task.isCancelled { return out }
                var mesh = MeshBuffer(parts: 1)
                var s = s0
                while s < s0 + cell {
                    let st = corridor.station(at: s)
                    let sunk = corridor.art.sunkenWeight(s)
                    let village = corridor.art.villageWeight(s)
                    for side in [-1.0, 1.0] {
                        let verge = side > 0 ? st.vergeRight : st.vergeLeft
                        var oMax = 3.2 + (0.45 - 3.2) * village
                        oMax = oMax * (1 - sunk) + 0.7 * sunk
                        oMax = min(oMax, verge - 0.4)
                        guard oMax > 0.15 else { continue }
                        // A lawn is a close sward: twice the tufts, short and wide.
                        let lawnSide = corridor.art.isLawn(s, side: side)
                        let density = config.grassDensity * (1 - 0.65 * village) * (1 - 0.6 * sunk) * (lawnSide ? 2.2 : 1)
                        let count = Int(density * (oMax - 0.1) * 0.5 + Double(rnd.unit()))
                        for _ in 0..<count {
                            let o = Double(rnd.range(0.1, Float(oMax)))
                            let ss = s + Double(rnd.unit()) * 0.5
                            // None on a pavement.
                            let pave = corridor.art.pavedWidth(ss, side: side)
                            if pave > 0, o < pave + 0.15 { continue }
                            let st2 = corridor.station(at: ss)
                            let p = RoadBuilder.vergePoint(corridor, st2, side: side, offset: o)
                            if (p.y - p.edgeY) / max(o, 0.1) > 1.3 { continue }
                            if sideRoads.covers(east: p.east, north: p.north) { continue }
                            // A mown lawn is watered green, whatever the dry
                            // summer photo says, and grows no tall tufts (the
                            // draw is kept so the tufts elsewhere stay put).
                            let lawn = corridor.art.isLawn(ss, side: side)
                            let tint = lawn ? Self.lawnTint : grassTint(ground?.color(east: p.east, north: p.north), sunk: Float(sunk))
                            let tall = Double(rnd.unit()) >= village && sunk < 0.3 && !lawn
                            // Late August: past the mown strip some tufts
                            // flower, some have gone to straw, and nettles
                            // come up.
                            let pick = rnd.unit()
                            var kind: GrassCell = tall && rnd.unit() < 0.45 ? .seeded : .green
                            if tall, o > 1.0 {
                                let flowers = Float(config.flowerShare)
                                if pick < flowers {
                                    kind = [GrassCell.carrot, .knapweed, .tansy][min(Int(pick / flowers * 3), 2)]
                                } else if pick < flowers + 0.08 {
                                    kind = .nettle
                                } else if pick < flowers + 0.26 {
                                    kind = .dry
                                }
                            }
                            grassTuft(&mesh, x: Float(p.east), y: Float(p.y) - 0.02, z: Float(-p.north), rnd: &rnd,
                                      tall: tall, tint: tint, cell: kind, height: lawn ? 0.1...0.2 : nil,
                                      width: lawn ? 0.45...0.75 : nil)
                            tufts += 1
                        }
                        // Bank flora: nettle beds at the foot; up the faces,
                        // ferns (hart's-tongue, male fern) where the face is
                        // turned from the sun, grasses and nettles where it
                        // gets it.
                        if sunk > 0.2, config.bankPlantDensity > 0 {
                            let dens = Float(config.bankPlantDensity * sunk)
                            if floraRnd.unit() < 0.5 * dens {
                                let o = Double(floraRnd.range(0.1, 0.8))
                                let p = RoadBuilder.vergePoint(corridor, st, side: side, offset: o)
                                if !sideRoads.covers(east: p.east, north: p.north) {
                                    grassTuft(&mesh, x: Float(p.east), y: Float(p.y) - 0.03, z: Float(-p.north), rnd: &floraRnd,
                                              tall: true, tint: SIMD3(0.9, 0.95, 0.9), cell: .nettle, height: 0.6...1.1)
                                    flora += 1
                                }
                            }
                            for _ in 0..<2 where floraRnd.unit() < 0.45 * dens {
                                let o = Double(floraRnd.range(0.5, Float(max(min(verge - 0.5, 6), 0.6))))
                                let p = RoadBuilder.vergePoint(corridor, st, side: side, offset: o)
                                let pn = surfaceNormal(corridor, st, side: side, offset: o)
                                guard pn.y < 0.9, p.y - p.edgeY > 0.3, !sideRoads.covers(east: p.east, north: p.north) else { continue }
                                let pnH = simd_normalize(SIMD3(pn.x, 0, pn.z) + SIMD3(1e-4, 0, 0))
                                let base = SIMD3<Float>(Float(p.east), Float(p.y), Float(-p.north))
                                if simd_dot(pnH, toSunH) < 0.2 {
                                    let along = SIMD3<Float>(Float(st.dirE), 0, Float(-st.dirN))
                                    fern(&mesh, base: base, normal: pn, along: along, size: floraRnd.range(0.5, 0.9), rnd: &floraRnd)
                                } else {
                                    let kind: GrassCell = floraRnd.unit() < 0.3 ? .nettle : (floraRnd.unit() < 0.5 ? .seeded : .dry)
                                    grassTuft(&mesh, x: base.x, y: base.y - 0.03, z: base.z, rnd: &floraRnd, tall: true,
                                              tint: SIMD3(0.9, 0.92, 0.85), cell: kind)
                                }
                                flora += 1
                            }
                        }
                    }
                    s += 0.5
                }
                // Sward: a first row of short tufts straddling the road's
                // edge, leaning out over the stones, so the edge is not a
                // ruled line; and beyond the mown strip, short ribbons of
                // grass standing at random angles, mostly across the road,
                // so the verge reads as a sward with parallax rather than
                // tufts on felt.
                if config.swardFinSpacing > 0 {
                    let spacing = config.swardFinSpacing
                    func reach(_ st: RoadCorridor.Station, _ side: Double) -> (oMax: Double, sunk: Double, village: Double) {
                        let sunk = corridor.art.sunkenWeight(st.s), village = corridor.art.villageWeight(st.s)
                        var oMax = 3.2 + (0.45 - 3.2) * village
                        oMax = oMax * (1 - sunk) + 0.7 * sunk
                        return (min(oMax, (side > 0 ? st.vergeRight : st.vergeLeft) - 0.4), sunk, village)
                    }
                    // (No denser than every 0.3 m: closer, the roots make a
                    // serrated line of their own.)
                    let edgeSpacing = max(spacing, 0.3)
                    var sf = s0 + Double(finRnd.unit()) * edgeSpacing
                    while sf < s0 + cell {
                        let st = corridor.station(at: sf)
                        for side in [-1.0, 1.0] {
                            let r = reach(st, side)
                            guard corridor.art.pavedWidth(sf, side: side) == 0, r.sunk < 0.5, r.oMax > 0.3 else { continue }
                            // In patches with bare gaps between, not a row of
                            // plugs; in a village, where the edge is kept,
                            // only the odd one.
                            let patch = 0.5 + 0.5 * sin(sf * 1.3 + side * 2) * sin(sf * 0.37 + 1)
                            if Double(finRnd.unit()) > (0.06 + 0.94 * patch * patch) * (1 - 0.75 * r.village) { continue }
                            // Rooted at -4 ... +10 cm, 20-35 cm wide: from 5 to
                            // 12 cm or so over the stones.
                            let o = Double(finRnd.range(-0.04, 0.1))
                            let lat = side * (st.halfWidth + o)
                            let pt = st.point(lateral: lat)
                            if sideRoads.covers(east: pt.east, north: pt.north) { continue }
                            let y = o < 0 ? Float(corridor.roadHeight(st, lateral: lat)) + 0.005
                                          : Float(RoadBuilder.vergePoint(corridor, st, side: side, offset: o).y) - 0.015
                            let tint = grassTint(ground?.color(east: pt.east, north: pt.north), sunk: Float(r.sunk))
                            let out = SIMD2<Float>(Float(st.rightE * side), Float(-st.rightN * side))
                            grassTuft(&mesh, x: Float(pt.east), y: y, z: Float(-pt.north), rnd: &finRnd, tall: false, tint: tint,
                                      cell: finRnd.unit() < 0.75 ? .green : .dry, height: 0.1...0.22, width: 0.2...0.35,
                                      lean: out * 0.06, soilRoots: true)
                            fins += 1
                        }
                        sf += edgeSpacing * Double(finRnd.range(0.5, 1.5)) * (1 + corridor.art.villageWeight(sf))
                    }
                    // About 4 m of ribbon per metre of road and side on
                    // balanced, 6 on high.
                    let perSide = Int((cell * 1.32 / spacing / 0.8).rounded())
                    for side in [-1.0, 1.0] {
                        for _ in 0..<perSide {
                            let sc = s0 + Double(finRnd.unit()) * cell
                            let st = corridor.station(at: sc)
                            let r = reach(st, side)
                            // (Short mown ribbons near the road read as bright
                            // lines from the chase camera; the ground and the
                            // tufts carry the mown strip.)
                            let lo = max(0.7, corridor.art.pavedWidth(sc, side: side) + 0.15)
                            let o = Double(finRnd.range(Float(lo), Float(max(r.oMax, lo))))
                            let ang = Double(finRnd.range(-1.0, 1.0)), half = Double(finRnd.range(0.25, 0.55))
                            let oa = max(lo, o - half * cos(ang)), ob = min(r.oMax, o + half * cos(ang))
                            guard r.oMax > lo + 0.1, ob > oa + 0.1, !corridor.art.isLawn(sc, side: side) else { continue }
                            if swardRibbon(&mesh, corridor, side: side, from: (sc - half * sin(ang), oa), to: (sc + half * sin(ang), ob),
                                           village: Float(r.village), sideRoads: sideRoads, rnd: &finRnd, ground: ground,
                                           sunk: Float(r.sunk)) {
                                fins += 1
                            }
                        }
                    }
                }
                // The sky at each blade (none is taller than a nettle bed,
                // so no opening towards the top).
                if let sky {
                    for i in 0..<mesh.vertexCount {
                        mesh.uv3[2 * i] *= sky.visibility(east: Double(mesh.positions[3 * i]), north: Double(-mesh.positions[3 * i + 2]))
                    }
                }
                if !mesh.isEmpty { out.grassCells.append((s0 + cell / 2, mesh)) }
                s0 += cell
            }
            out.counts["grass tufts"] = tufts
            out.counts["sward fins"] = fins
            out.counts["bank flora"] = flora
        }
        return out
    }

    /// `CourseArt.extraTrees` as scenery trees.
    static func extraTrees(_ corridor: RoadCorridor) -> [SceneryFile.Tree] {
        corridor.art.extraTrees.map { t in
            let st = corridor.station(at: t.s)
            let p = st.point(lateral: t.side * (st.halfWidth + t.offset))
            return SceneryFile.Tree(e: p.east, n: p.north, heightM: t.height, crownRadiusM: t.radius, kind: nil)
        }
    }

    /// A tree's crown form from what the data say about it: LiDAR height
    /// and crown radius (flown leaf-off, so narrow), landuse, the holle weg,
    /// running water nearby and how crowded it stands.
    static func pickForm(kind: String?, h: Float, r: Float, landuse lu: String?, sunk: Double, nearStream: Bool,
                         crowded: Bool, rnd: inout WorldRandom) -> TreeArchetype.Form {
        let ratio = h / max(r, 0.5)
        if kind == "conifer" || (lu == "residential" && rnd.unit() < 0.14 && ratio > 2.4 && h < 18) { return .conifer }
        if lu == "orchard" { return .orchard }
        // Knotwilgen along the brooks.
        if nearStream, h < 12, ratio < 2.6 { return .willow }
        if h <= 7.5, ratio <= 2.6, lu != "forest" { return .orchard }
        // A crown much narrower than this is usually a broadleaf's cut short
        // by its neighbours.
        if h >= 13, ratio >= 5.5, r <= 2.2 { return .lombardy }
        if h >= 18, ratio >= 3.5, lu != "forest", !crowded { return .hybridPoplar }
        let u = rnd.unit()
        // The Koppenbergbos and the like: beech and oak drawn up with clean
        // boles, some ash.
        if lu == "forest" || crowded { return u < 0.55 ? .beechForest : u < 0.85 ? .oakForest : .ash }
        if sunk > 0.2 { return u < 0.4 ? .ash : u < 0.7 ? .sycamore : .oak }
        if lu == "residential", u < 0.08 { return .copperBeech }
        return u < 0.45 ? .oak : u < 0.7 ? .ash : u < 0.85 ? .sycamore : .beech
    }

    // MARK: - Hedges

    /// How a kind of clipped hedge looks: its leaves (a `TreeArchetype`
    /// atlas quadrant), the size of the cards clad on it, and its colour, a
    /// multiplier on the atlas (`TreeArchetype.packColour`).
    struct HedgeLook {
        var uv: SIMD4<Float>
        var cardSize: ClosedRange<Float>
        var colour: SIMD3<Float>
    }

    static func hedgeLook(_ kind: CourseArt.HedgeKind) -> HedgeLook {
        /// `shadeDecode`'s yellowing, as a multiplier.
        func yellowed(_ t: Float) -> SIMD3<Float> { SIMD3(repeating: 1) + (SIMD3(1.16, 1.06, 0.72) - 1) * t }
        switch kind {
        case .green: return HedgeLook(uv: TreeArchetype.broadUV, cardSize: 0.65...0.85, colour: yellowed(0.05))
        case .copperBeech:
            return HedgeLook(uv: TreeArchetype.broadUV, cardSize: 0.65...0.85, colour: TreeArchetype.Form.copperBeech.leafColour)
        // Cherry laurel: big leaves, darker and bluer than beech.
        case .laurel: return HedgeLook(uv: TreeArchetype.broadUV, cardSize: 0.9...1.15, colour: SIMD3(0.74, 0.84, 0.95))
        case .ivy: return HedgeLook(uv: TreeArchetype.ivyUV, cardSize: 0.65...0.85, colour: yellowed(-0.25))
        }
    }

    /// Thickness of a clipped hedge, metres.
    static let hedgeThickness = 0.9

    /// A clipped hedge's core across the hedge at route distance `s`, in
    /// world space: `ring` runs up the road face, over the rounded top and
    /// down the back (foot of the face, top of the face, the top's two
    /// edges, top of the back, foot of the back); each corner's normal is
    /// the mean of its sides'.
    struct HedgeSection {
        var ring: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var along: SIMD3<Float>
        var foot: Float
        var top: Float
        /// The sky the hedge stands in (`SkyRaster.plantSky`).
        var sky: Float
    }

    /// The hedge's section at `s`, or nil where a side road crosses it.
    /// Its top is cut level with the lie of the ground under it, smoothed
    /// over two metres, and its faces wander a few centimetres, as clipped
    /// hedges do; they lean in by 5 cm as they rise, so the top is a little
    /// narrower than the foot.
    static func hedgeSection(_ corridor: RoadCorridor, side: Double, height h: Double, offset: Double, s: Double,
                             wave: SIMD3<Double>, sideRoads: RoadBuilder.SideRoadMask, sky: SkyRaster?) -> HedgeSection? {
        let thick = hedgeThickness
        let st = corridor.station(at: s)
        let face = RoadBuilder.vergePoint(corridor, st, side: side, offset: offset)
        let mid = st.point(lateral: side * (st.halfWidth + offset + thick / 2))
        if sideRoads.covers(east: face.east, north: face.north, margin: 0.4)
            || sideRoads.covers(east: mid.east, north: mid.north, margin: 0.4) { return nil }
        func ground(_ o: Double, _ at: Double) -> Double {
            RoadBuilder.vergePoint(corridor, corridor.station(at: at), side: side, offset: o).y
        }
        let yF = face.y, yB = ground(offset + thick, s)
        var level = 0.0
        for ds in [-1.0, 0, 1] { level += (ground(offset, s + ds) + ground(offset + thick, s + ds)) / 6 }
        let top = max(level + h * (1 + 0.012 * sin(s * 0.7 + wave.z)), max(yF, yB) + 0.6 * h)
        let oF = offset + 0.025 * sin(s * 0.9 + wave.x) + 0.012 * sin(s * 2.3 + wave.y)
        let oB = offset + thick + 0.025 * sin(s * 0.8 + wave.y)
        let batter = 0.05, edge = 0.06, sink = 0.12
        let pts: [(o: Double, y: Double)] = [(oF, yF - sink), (oF + batter, top - edge), (oF + batter + edge, top),
                                             (oB - batter - edge, top), (oB - batter, top - edge), (oB, yB - sink)]
        let ring = pts.map { p -> SIMD3<Float> in
            let q = st.point(lateral: side * (st.halfWidth + p.o))
            return SIMD3(Float(q.east), Float(p.y), Float(-q.north))
        }
        // Away from the road, horizontally; a side (do, dy) across the hedge
        // faces (-dy, do).
        let away = SIMD3<Float>(Float(side * st.rightE), 0, Float(-side * st.rightN))
        let sideN = (0..<5).map { j in
            simd_normalize(away * Float(pts[j].y - pts[j + 1].y) + SIMD3(0, Float(pts[j + 1].o - pts[j].o), 0))
        }
        let normals = (0..<6).map { j in simd_normalize(sideN[max(j - 1, 0)] + sideN[min(j, 4)]) }
        let shade = sky.map { $0.plantSky(east: mid.east, north: mid.north, radius: max(thick / 2, h / 2)) } ?? 1
        return HedgeSection(ring: ring, normals: normals, along: SIMD3(Float(st.dirE), 0, Float(-st.dirN)),
                            foot: Float(min(yF, yB) - sink), top: Float(top), sky: shade)
    }

    /// Clipped hedges, about 0.9 m thick, broken where a side road crosses:
    /// each a closed core, flat-faced and flat-topped with rounded top
    /// edges, in the colour of one leaf of the atlas made darker
    /// (`TreeArchetype.core`), clad in leaf cards laid almost flat on its
    /// faces, its top and its ends. Between the cards the core shows as
    /// the shaded leaves inside, so a hedge reads as a dense, clipped wall.
    /// (Cards alone, as first built, let the light through in vertical
    /// streaks, and the ones on top stood over it edge-on like slats.)
    static func buildHedges(corridor: RoadCorridor, sideRoads: RoadBuilder.SideRoadMask, sky: SkyRaster? = nil,
                            into out: inout MeshBuffer) {
        let step = 0.6
        for run in corridor.art.hedges {
            var rnd = WorldRandom(seed: UInt64(run.span.lowerBound * 17 + 11))
            let look = hedgeLook(run.kind)
            let wave = SIMD3<Double>(Double(rnd.range(0, 6.28)), Double(rnd.range(0, 6.28)), Double(rnd.range(0, 6.28)))
            var stretch: [HedgeSection] = []
            var s = run.span.lowerBound
            while true {
                if let sec = hedgeSection(corridor, side: run.side, height: run.height, offset: run.offset, s: s,
                                          wave: wave, sideRoads: sideRoads, sky: sky) {
                    stretch.append(sec)
                } else {
                    hedgeStretch(stretch, look: look, rnd: &rnd, into: &out)
                    stretch.removeAll()
                }
                if s >= run.span.upperBound { break }
                s = min(s + step, run.span.upperBound)
            }
            hedgeStretch(stretch, look: look, rnd: &rnd, into: &out)
        }
    }

    /// One unbroken stretch of hedge (`buildHedges`): its core, capped at
    /// both ends, and its cards (part 1).
    static func hedgeStretch(_ secs: [HedgeSection], look: HedgeLook, rnd: inout WorldRandom, into m: inout MeshBuffer) {
        guard secs.count >= 2 else { return }
        let core = TreeArchetype.core(for: look.uv)
        // The core's corners, the shaded leaves inside the hedge: darkest
        // at the foot, lightest on the top (seen at a grazing angle from the
        // road, the top is mostly core between thin slivers of card), the
        // back the more shaded (gardens, walls).
        let ringAO: [Float] = [0.4, 0.8, 0.95, 0.95, 0.72, 0.36]
        let ringColour = [0.45, 0.6, 0.85, 0.85, 0.55, 0.4].map { TreeArchetype.packColour(look.colour * $0) }
        // An end is a side face top to bottom.
        let capColour = [0.45, 0.6, 0.6, 0.6, 0.55, 0.4].map { TreeArchetype.packColour(look.colour * $0) }
        func point(_ i: UInt32) -> SIMD3<Float> {
            SIMD3(m.positions[3 * Int(i)], m.positions[3 * Int(i) + 1], m.positions[3 * Int(i) + 2])
        }
        /// A triangle wound anticlockwise seen from the side `n` faces.
        func tri(_ a: UInt32, _ b: UInt32, _ c: UInt32, facing n: SIMD3<Float>) {
            let pa = point(a)
            if simd_dot(simd_cross(point(b) - pa, point(c) - pa), n) >= 0 { m.tri(a, b, c, part: 1) } else { m.tri(a, c, b, part: 1) }
        }
        func ring(_ sec: HedgeSection, normal: (Int) -> SIMD3<Float>, ao: Float, colour: [Float]) -> UInt32 {
            let first = m.vertexCount
            for j in 0..<6 {
                let p = sec.ring[j], n = normal(j)
                m.vertex(p.x, p.y, p.z, n.x, n.y, n.z, core.x, core.y)
                m.texcoord2(0, 0)
                m.texcoord3(ringAO[j] * ao, colour[j])
                m.texcoord4(0, 0)
            }
            skyShade(&m, from: first, sky: sec.sky, baseY: sec.foot, height: sec.top - sec.foot)
            return UInt32(first)
        }
        // The core: rings joined along the hedge, a fan over each end.
        var rings: [UInt32] = []
        for sec in secs { rings.append(ring(sec, normal: { sec.normals[$0] }, ao: 1, colour: ringColour)) }
        for k in 1..<secs.count {
            let a = rings[k - 1], b = rings[k]
            for j in 0..<UInt32(5) {
                let n = secs[k].normals[Int(j)] + secs[k].normals[Int(j) + 1]
                tri(a + j, a + j + 1, b + j + 1, facing: n)
                tri(a + j, b + j + 1, b + j, facing: n)
            }
        }
        for (sec, sign) in [(secs[0], Float(-1)), (secs[secs.count - 1], Float(1))] {
            let n = sec.along * sign
            let cap = ring(sec, normal: { simd_normalize(n * 2 + sec.normals[$0]) }, ao: 0.9, colour: capColour)
            for j in 1..<UInt32(5) { tri(cap, cap + j, cap + j + 1, facing: n) }
        }

        // The cards. On the road face, a layer of big, dark ones (the leaves
        // behind) close on the core and one of lit ones about one per
        // (0.62 x mean size)^2, up to 10 cm proud and turned from the core
        // by up to 0.3 rad, less for big ones, with a row more along its
        // top, where the others thin out; the back, mostly hidden, has far
        // fewer. On the top, ones that keep inside it, so none stands out
        // over the edge. (Cards on the rounded edges stood up over the top
        // like fins.)
        let hull = TreeArchetype.hull(for: look.uv)
        let mean = (look.cardSize.lowerBound + look.cardSize.upperBound) / 2
        let perM2 = 1 / (mean * mean * 0.38)
        var length: [Float] = [0]
        for k in 1..<secs.count {
            let d = secs[k].ring[0] - secs[k - 1].ring[0]
            length.append(length[k - 1] + simd_length(SIMD2(d.x, d.z)))
        }
        let total = length[length.count - 1]
        /// Side `j`'s own normal (the corners' are smoothed over the edges).
        func flat(_ sec: HedgeSection, _ j: Int) -> SIMD3<Float> {
            let n = simd_normalize(simd_cross(sec.ring[j + 1] - sec.ring[j], sec.along))
            return simd_dot(n, sec.normals[j] + sec.normals[j + 1]) >= 0 ? n : -n
        }
        /// A card at `p` on a side facing `n0`, `lift` proud of it and
        /// turned from it by up to `tilt` (less for big cards, so none stands
        /// off the core like a slat); lighter than the core at the same
        /// height, a `shade` darker, and `dim` on the back.
        func leaf(_ p: SIMD3<Float>, facing n0: SIMD3<Float>, sec: HedgeSection, size: Float, lift: ClosedRange<Float>,
                  tilt: Float, shade: Float, dim: Float) {
            let tl = min(tilt, 0.11 / (size / 2))
            let normal = simd_normalize(n0 + simd_normalize(simd_cross(n0, SIMD3(0, 1, 0)) + sec.along * 1e-3) * rnd.range(-tl, tl)
                                        + SIMD3(0, rnd.range(-0.4 * tl, tl), 0))
            let card = m.vertexCount
            TreeArchetype.card(&m, centre: p + n0 * rnd.range(lift.lowerBound, lift.upperBound), size: size,
                               normal: normal, roll: rnd.range(0, 6.28), uv: look.uv, crownCentre: p - n0,
                               crownRadii: SIMD3(repeating: 1), height: 40, ao: 1, bend: 0, baseY: sec.foot,
                               billboard: false, mirror: rnd.unit() < 0.5, hull: hull)
            let colour = TreeArchetype.packColour(look.colour * shade * (1 + rnd.range(-0.06, 0.06)))
            for q in card..<m.vertexCount {
                let up = min(max((m.positions[3 * q + 1] - sec.foot) / max(sec.top - sec.foot, 0.5), 0), 1)
                m.uv3[2 * q] = min(0.5 + 0.48 * up, 1) * dim * shade
                m.uv3[2 * q + 1] = colour
            }
        }
        for k in 1..<secs.count {
            let a = secs[k - 1], b = secs[k]
            let segment = length[k] - length[k - 1]
            let first = m.vertexCount
            /// `perMetre` cards on side `j` of this segment, their middles
            /// across the side within `across` (0...1 for a card of that
            /// size and a side that long) and nearly half their size inside
            /// the stretch's ends, which are cut square.
            func clad(_ j: Int, perMetre: Float, sizes: ClosedRange<Float>, lift: ClosedRange<Float>, tilt: Float,
                      shade: Float = 1, across: (Float, Float) -> ClosedRange<Float>) {
                let n = Int(segment * perMetre + rnd.unit())
                let side = (simd_distance(a.ring[j], a.ring[j + 1]) + simd_distance(b.ring[j], b.ring[j + 1])) / 2
                for i in 0..<n {
                    let size = rnd.range(sizes.lowerBound, sizes.upperBound)
                    let at = min(max(length[k - 1] + rnd.unit() * segment, 0.45 * size), max(total - 0.45 * size, 0.45 * size))
                    let t = min(max((at - length[k - 1]) / max(segment, 1e-3), 0), 1)
                    // Spread evenly across the side, at random along it.
                    let r = across(size, side)
                    let v = r.lowerBound + (r.upperBound - r.lowerBound) * (Float(i) + rnd.unit()) / Float(n)
                    let p = simd_mix(simd_mix(a.ring[j], a.ring[j + 1], SIMD3(repeating: v)),
                                     simd_mix(b.ring[j], b.ring[j + 1], SIMD3(repeating: v)), SIMD3(repeating: t))
                    let n0 = simd_normalize(simd_mix(flat(a, j), flat(b, j), SIMD3(repeating: t)))
                    leaf(p, facing: n0, sec: a, size: size, lift: lift, tilt: tilt, shade: shade, dim: j >= 3 ? 0.85 : 1)
                }
            }
            let faceLen = simd_distance(a.ring[0], a.ring[1])
            let topWidth = simd_distance(a.ring[2], a.ring[3])
            // Face cards reach no more than 6 cm over the top (the face ends
            // 6 cm below it).
            let face: (Float, Float) -> ClosedRange<Float> = { size, side in
                0.03...max(0.04, 1 - max(0, 0.5 * size - 0.12) / side)
            }
            let back: (Float, Float) -> ClosedRange<Float> = { size, side in
                let r = face(size, side)
                return (1 - r.upperBound)...(1 - r.lowerBound)
            }
            let big = look.cardSize.lowerBound * 1.4...look.cardSize.upperBound * 1.4
            clad(0, perMetre: faceLen * perM2 * 0.4, sizes: big, lift: 0.012...0.025, tilt: 0.05, shade: 0.6, across: face)
            clad(4, perMetre: faceLen * perM2 * 0.15, sizes: big, lift: 0.012...0.025, tilt: 0.05, shade: 0.6, across: back)
            clad(0, perMetre: faceLen * perM2, sizes: look.cardSize, lift: 0.04...0.1, tilt: 0.3, across: face)
            clad(4, perMetre: faceLen * perM2 * 0.2, sizes: look.cardSize, lift: 0.04...0.1, tilt: 0.3, across: back)
            let small = look.cardSize.lowerBound * 0.8...look.cardSize.upperBound * 0.8
            clad(0, perMetre: 1 / (0.5 * mean), sizes: small, lift: 0.04...0.1, tilt: 0.25) { size, side in
                let r = face(size, side)
                return max(r.upperBound - 0.06, 0)...r.upperBound
            }
            let topSize = min(look.cardSize.lowerBound, 0.6)...min(look.cardSize.upperBound, 0.66)
            let topMean = (topSize.lowerBound + topSize.upperBound) / 2
            clad(2, perMetre: topWidth / (topMean * topMean * 0.26), sizes: topSize, lift: 0.02...0.05, tilt: 0.12) { size, side in
                let spare = max(0, (side / 2 + 0.1 - 0.45 * size) / side)
                return (0.5 - spare)...(0.5 + spare)
            }
            skyShade(&m, from: first, sky: (a.sky + b.sky) / 2, baseY: a.foot, height: a.top - a.foot)
        }
        // The ends, cut square: a dark layer and a lit one on each, and a
        // row along the top, none more than 8 cm past a corner (further, a
        // card would stand off the face).
        for (sec, sign) in [(secs[0], Float(-1)), (secs[secs.count - 1], Float(1))] {
            let n0 = sec.along * sign
            let width = simd_distance(sec.ring[0], sec.ring[5]), height = sec.top - sec.foot
            let first = m.vertexCount
            for (sizes, density, lift, shade, row) in [(Float(0.55)...0.65, Float(0.4), Float(0.012)...0.025, Float(0.6), false),
                                                       (0.4...0.55, 1, 0.04...0.09, 1, false), (0.35...0.45, 1, 0.04...0.09, 1, true)] {
                let mid = (sizes.lowerBound + sizes.upperBound) / 2
                let n = Int((row ? width / (0.5 * mid) : width * height / (mid * mid * 0.38) * density) + rnd.unit())
                for i in 0..<n {
                    let size = rnd.range(sizes.lowerBound, sizes.upperBound)
                    let margin = min(max(0.5 * size - 0.08, 0) / width, 0.5)
                    let high = max(0.04, 1 - max(0, 0.5 * size - 0.06) / height)
                    let low = row ? high - 0.06 : 0.03
                    let v = low + (high - low) * (row ? rnd.unit() : (Float(i) + rnd.unit()) / Float(n))
                    let spread = row ? (Float(i) + rnd.unit()) / Float(n) : rnd.unit()
                    let across = margin + (1 - 2 * margin) * spread
                    let edge = simd_mix(sec.ring[0], sec.ring[5], SIMD3(repeating: across))
                    let p = SIMD3(edge.x, sec.foot + v * height, edge.z)
                    leaf(p, facing: n0, sec: sec, size: size, lift: lift, tilt: 0.2, shade: shade, dim: 0.9)
                }
            }
            skyShade(&m, from: first, sky: sec.sky, baseY: sec.foot, height: height)
        }
    }

    // MARK: - Pieces

    /// Appends a scaled, turned plant and stamps its per-plant phase and
    /// tint, and its shading by the sky it stands in (`skyShade`).
    static func appendPlant(_ m: inout MeshBuffer, _ src: MeshBuffer, sx: Float, sy: Float, yaw: Float,
                            x: Float, y: Float, z: Float, phase: Float, tint: Float,
                            lean: SIMD2<Float> = .zero, height: Float = 1, sky: Float = 1) {
        let first = m.vertexCount
        m.append(src, sx: sx, sy: sy, sz: sx, yaw: yaw, tx: x, ty: y, tz: z)
        if lean != .zero {
            // Bend the whole plant: offset grows with the square of height.
            for i in first..<m.vertexCount {
                let t = max(m.positions[3 * i + 1] - y, 0) / max(height, 1)
                m.positions[3 * i] += lean.x * t * t
                m.positions[3 * i + 2] += lean.y * t * t
            }
        }
        // Sway grows with the plant's own height; billboard cards scale
        // with the plant.
        let cardScale = (sx + sy) / 2
        let hasCards = m.uv4.count == m.vertexCount * 2
        for i in first..<m.vertexCount {
            m.uv2[2 * i] *= sy
            if hasCards {
                m.uv4[2 * i] *= cardScale
                m.uv4[2 * i + 1] *= cardScale
            }
        }
        patchPhase(&m, from: first, phase: phase, tint: tint)
        skyShade(&m, from: first, sky: sky, baseY: y, height: height)
    }

    /// Multiplies the shading (texture channel 2's x: the leaves' ambient
    /// occlusion, the bark's too; billboards at their centres) of a plant's
    /// vertices from `first` on by `sky`, the sky it stands in
    /// (`SkyRaster.plantSky`), opening to the full sky at its top, `height`
    /// above `baseY`: the crown of a tree in a holle weg or a wood sees
    /// more sky than its trunk and the ground.
    static func skyShade(_ m: inout MeshBuffer, from first: Int, sky: Float, baseY: Float, height: Float) {
        guard sky < 1, m.uv3.count == m.vertexCount * 2 else { return }
        for i in first..<m.vertexCount {
            let up = min(max((m.positions[3 * i + 1] - baseY - 0.5) / max(height - 0.5, 0.5), 0), 1)
            m.uv3[2 * i] *= sky + (1 - sky) * up * up
        }
    }

    static func patchPhase(_ m: inout MeshBuffer, from first: Int, phase: Float, tint: Float) {
        guard m.uv2.count == m.vertexCount * 2, m.uv3.count == m.vertexCount * 2 else { return }
        for i in first..<m.vertexCount {
            m.uv2[2 * i + 1] = phase
            m.uv3[2 * i + 1] = tint
        }
    }

    /// How far towards the full sky an impostor's top opens (`impostor`).
    /// Its shading runs linearly up the quad, where `skyShade`'s opens with
    /// the square of the height; over a crown from 35 % of the height up
    /// (mean t² against mean t, 2 (1 + a + a²) / (3 (1 + a)) at a = 0.35),
    /// this share gives both the same mean, so a tree keeps its brightness
    /// across the switch to its impostor.
    static let impostorSkyTop: Float = 0.73

    /// A camera-facing (about the vertical) quad showing a cell of the
    /// 4 x 2 impostor atlas (`TreeArchetype.Form.impostorCell`), trunk base
    /// at (x, y, z). The corners sit on the base and carry their offsets in
    /// texture channel 3 for the impostor shader; `sky` (see `skyShade`)
    /// shades its foot, opening towards the full sky at its top
    /// (`impostorSkyTop`).
    static func impostor(_ m: inout MeshBuffer, cell: Int, width: Float, height: Float,
                         x: Float, y: Float, z: Float, yaw: Float, phase: Float, tint: Float, sky: Float = 1) {
        let u0 = Float(cell % 4) * 0.25 + 0.002, u1 = u0 + 0.246
        let v0 = Float(cell / 4) * 0.5 + 0.004, v1 = v0 + 0.492
        let first = UInt32(m.vertexCount)
        let pts: [(Float, Float, Float, Float)] = [(-width / 2, 0, u0, v1), (width / 2, 0, u1, v1),
                                                    (width / 2, height, u1, v0), (-width / 2, height, u0, v0)]
        let top = sky + (1 - sky) * impostorSkyTop
        for (ox, oy, u, v) in pts {
            m.vertex(x, y, z, 0, 1, 0, u, v)
            m.texcoord2(oy / max(height, 1) * 0.3, phase)
            m.texcoord3(0.92 * (oy > 0 ? top : sky), tint)
            m.texcoord4(ox, oy)
        }
        m.tri(first, first + 1, first + 2, part: 1)
        m.tri(first, first + 2, first + 3, part: 1)
    }

    /// Verge surface normal by finite differences.
    static func surfaceNormal(_ corridor: RoadCorridor, _ st: RoadCorridor.Station, side: Double, offset o: Double) -> SIMD3<Float> {
        let a = RoadBuilder.vergePoint(corridor, st, side: side, offset: max(o - 0.25, 0))
        let b = RoadBuilder.vergePoint(corridor, st, side: side, offset: o + 0.25)
        let st2 = corridor.station(at: st.s + 0.5)
        let c = RoadBuilder.vergePoint(corridor, st2, side: side, offset: o)
        let p0 = SIMD3<Float>(Float(a.east), Float(a.y), Float(-a.north))
        let p1 = SIMD3<Float>(Float(b.east), Float(b.y), Float(-b.north))
        let p2 = SIMD3<Float>(Float(c.east), Float(c.y), Float(-c.north))
        var n = simd_cross(p1 - p0, p2 - p0)
        if n.y < 0 { n = -n }
        let l = simd_length(n)
        return l > 1e-6 ? n / l : SIMD3(0, 1, 0)
    }

    /// The top of a sunken-lane bank on one side: the first offset from the
    /// road edge where the verge, having risen at least 0.7 m, flattens out.
    static func bankTop(_ corridor: RoadCorridor, _ st: RoadCorridor.Station, side: Double,
                        maxOffset: Double) -> (offset: Double, rise: Double)? {
        guard maxOffset > 1 else { return nil }
        var o = 0.4
        let start = RoadBuilder.vergePoint(corridor, st, side: side, offset: 0.2)
        var prevRise = start.y - start.edgeY
        while o <= maxOffset {
            let p = RoadBuilder.vergePoint(corridor, st, side: side, offset: o)
            let rise = p.y - p.edgeY
            if prevRise > 0.7, (rise - prevRise) / 0.4 < 0.35 { return (o - 0.2, prevRise) }
            prevRise = rise
            o += 0.4
        }
        return prevRise > 0.7 ? (maxOffset, prevRise) : nil
    }

    /// Mean linear colour of the cj_grass.png blades.
    static let grassCardColor = SIMD3<Float>(0.07, 0.13, 0.025)

    /// Vertex colour that pulls a tuft towards the ground it grows from
    /// (a dry, pale verge or a lush one), part of the way and within limits.
    /// Inside the sunken lane, shade-grown and darker.
    /// A kept lawn's tufts: greener than the card.
    static let lawnTint = SIMD3<Float>(0.76, 1.0, 0.68)

    static func grassTint(_ ground: SIMD3<Float>?, sunk: Float) -> SIMD3<Float> {
        guard let g = ground else { return SIMD3(1, 1, 1) }
        let ratio = simd_clamp(g / grassCardColor, SIMD3(repeating: 0.55), SIMD3(1.7, 1.7, 1.3))
        let t = SIMD3<Float>(1, 1, 1) + (ratio - SIMD3(1, 1, 1)) * 0.7
        return t * (1 - 0.25 * sunk)
    }

    /// A sward ribbon's colour from the ground's tint: darker, with half
    /// the ground's shift in hue and no redder than the blades' green, so
    /// over a yellow field or bare earth the rough strip (straw enough of
    /// its own) doesn't turn golden.
    static func swardTint(_ t: SIMD3<Float>) -> SIMD3<Float> {
        let lum = simd_dot(t, SIMD3(0.2126, 0.7152, 0.0722))
        var c = SIMD3(repeating: lum) + (t - SIMD3(repeating: lum)) * 0.5
        c.x = min(c.x, 1.08 * c.y)
        return c * 0.85
    }

    /// Cards of cj_grass.png (bake_materials.py `bake_grass`): four tufts
    /// of 256 x 512 px along the top, four flowering plants and a fern of
    /// 256 x 384 below; two sward strips along the bottom (`swardRibbon`).
    enum GrassCell: Int {
        case green, seeded, dry, nettle, carrot, knapweed, tansy, fern
    }

    /// A card's cell in the atlas (u0, v0, u1, v1), v0 at the top.
    static func grassUV(_ c: GrassCell) -> SIMD4<Float> {
        let i = c.rawValue
        let u0 = Float(i % 4) * 0.25 + 0.002, u1 = u0 + 0.246
        return i < 4 ? SIMD4(u0, 0.004, u1, 0.495) : SIMD4(u0, 516.0 / 1024, u1, 891.0 / 1024)
    }

    /// A grass tuft (or a flowering plant, a nettle clump): two crossed
    /// cards from cj_grass.png, either way round.
    static func grassTuft(_ m: inout MeshBuffer, x: Float, y: Float, z: Float, rnd: inout WorldRandom, tall: Bool,
                          tint colour: SIMD3<Float> = SIMD3(1, 1, 1), cell: GrassCell = .green,
                          height: ClosedRange<Float>? = nil, width: ClosedRange<Float>? = nil,
                          lean bias: SIMD2<Float> = .zero, soilRoots: Bool = false) {
        var w: Float
        let h: Float
        switch cell {
        case .green, .seeded, .dry:
            w = rnd.range(0.32, 0.6)
            h = height.map { rnd.range($0.lowerBound, $0.upperBound) } ?? (tall ? rnd.range(0.3, 0.62) : rnd.range(0.18, 0.36))
        case .nettle:
            w = rnd.range(0.4, 0.65)
            h = height.map { rnd.range($0.lowerBound, $0.upperBound) } ?? rnd.range(0.5, 0.9)
        case .carrot, .knapweed, .tansy, .fern:
            w = rnd.range(0.4, 0.6)
            h = height.map { rnd.range($0.lowerBound, $0.upperBound) } ?? rnd.range(0.45, 0.85)
        }
        if let width { w = w / 0.6 * width.upperBound }
        var uv = grassUV(cell)
        if rnd.unit() < 0.5 { uv = SIMD4(uv.z, uv.y, uv.x, uv.w) }
        // Roots towards the soil's colour where the tuft overhangs bare
        // edges (fully soil-coloured, they read as dark triangles close up).
        let root = soilRoots ? colour * SIMD3(0.94, 0.88, 0.8) : colour
        let yaw = rnd.range(0, 3.14)
        let phase = rnd.range(0, 6.28)
        let tint = max(0, rnd.range(-0.2, 0.5))
        for k in 0..<2 {
            let a = yaw + Float(k) * 1.5708
            let dx = cos(a) * w / 2, dz = sin(a) * w / 2
            let first = UInt32(m.vertexCount)
            let lean = SIMD2<Float>(rnd.range(-0.08, 0.08), rnd.range(-0.08, 0.08)) * min(h / 0.3, 1) + bias
            let pts: [(Float, Float, Float, Float, Float, Float)] = [
                (x - dx, y, z - dz, uv.x, uv.w, 0), (x + dx, y, z + dz, uv.z, uv.w, 0),
                (x + dx + lean.x, y + h, z + dz + lean.y, uv.z, uv.y, 1), (x - dx + lean.x, y + h, z - dz + lean.y, uv.x, uv.y, 1),
            ]
            for (px, py, pz, u, v, top) in pts {
                m.vertex(px, py, pz, -sin(a) * 0.25, 0.97, cos(a) * 0.25, u, v)
                m.texcoord2(top * h * 1.2, phase)
                m.texcoord3(0.75 + 0.25 * top, tint)
                m.texcoord4(0, 0)
                let c = top > 0 ? colour : root
                m.color(c.x, c.y, c.z, 1)
            }
            m.tri(first, first + 1, first + 2)
            m.tri(first, first + 2, first + 3)
        }
    }

    /// A sward ribbon: a short strip of grass (one of `bake_grass`'s sward
    /// strips, 0.8 m of strip per u) standing on the verge from `a` to `b`
    /// (route distance, offset from the road's edge; a negative offset is
    /// over the edge stones), its top leaning a little as grass lies. The
    /// mown strip, 10 to 15 cm, runs to a metre from the road; the rough
    /// one rises to about 30 cm beyond (Flemish bermbeheer: a safety strip
    /// mown often, the rest in June and September); in a village it is
    /// lawn. Over the stones it is short, leans outward and its roots take
    /// the soil's colour. False when a side road crosses it.
    @discardableResult
    static func swardRibbon(_ m: inout MeshBuffer, _ corridor: RoadCorridor, side: Double, from a: (s: Double, o: Double),
                            to b: (s: Double, o: Double), village: Float, sideRoads: RoadBuilder.SideRoadMask,
                            rnd: inout WorldRandom, ground: GroundColor?, sunk: Float) -> Bool {
        let phase = rnd.range(0, 6.28)
        let tint = max(0, rnd.range(-0.2, 0.5))
        let rough = village < 0.5 && (a.o + b.o) / 2 > 1.0
        let v0: Float = (rough ? 968.0 : 912.0) / 1024 + 0.002
        let v1: Float = v0 + 53.0 / 1024
        // (Lying flatter, a ribbon read as a smear of straw.)
        let lie = rnd.range(0, 6.283), lieK = rnd.range(0.1, 0.3)
        let length = Float(hypot(b.s - a.s, b.o - a.o))
        var u = rnd.range(0, 4)
        var verts: [(UInt32, UInt32)] = []
        let ends = [a, b].map { end -> (st: RoadCorridor.Station, lat: Double, o: Double) in
            let st = corridor.station(at: end.s)
            return (st, side * (st.halfWidth + end.o), end.o)
        }
        for e in ends {
            let pt = e.st.point(lateral: e.lat)
            if sideRoads.covers(east: pt.east, north: pt.north) { return false }
        }
        for (st, lat, o) in ends {
            let end = (s: st.s, o: o)
            let pt = st.point(lateral: lat)
            let y = end.o < 0 ? Float(corridor.roadHeight(st, lateral: lat)) + 0.01
                              : Float(RoadBuilder.vergePoint(corridor, st, side: side, offset: end.o).y) - 0.015
            let colour = swardTint(grassTint(ground?.color(east: pt.east, north: pt.north), sunk: sunk))
            var hh = (village > 0.5 ? rnd.range(0.06, 0.09) : 0.10 + 0.22 * smoothstepF(0.7, 1.4, Float(end.o)))
                * rnd.range(0.75, 1.25)
            var top = SIMD2<Float>(cos(lie), sin(lie)) * (hh * lieK)
            var root = colour
            if end.o < 0.1 {
                hh = min(hh, rnd.range(0.06, 0.1))
                top = SIMD2(Float(st.rightE * side), Float(-st.rightN * side)) * 0.05
                root = colour * SIMD3(0.8, 0.66, 0.5)
            }
            let nx = Float(-st.rightE * side) * 0.25, nz = Float(st.rightN * side) * 0.25
            let x = Float(pt.east), z = Float(-pt.north)
            let bI = m.vertex(x, y, z, nx, 0.97, nz, u, v1)
            m.texcoord2(0, phase)
            m.texcoord3(0.72, tint)
            m.texcoord4(0, 0)
            m.color(root.x, root.y, root.z, 1)
            let tI = m.vertex(x + top.x, y + hh, z + top.y, nx, 0.97, nz, u, v0)
            m.texcoord2(hh * 1.2, phase)
            m.texcoord3(1, tint)
            m.texcoord4(0, 0)
            m.color(colour.x, colour.y, colour.z, 1)
            verts.append((bI, tI))
            u += length / 0.8
        }
        m.tri(verts[0].0, verts[1].0, verts[1].1)
        m.tri(verts[0].0, verts[1].1, verts[0].1)
        return true
    }

    /// A fern (hart's-tongue and male fern) growing out of a bank face: one
    /// fixed card from the grass atlas, standing out along the face's
    /// normal and 30 degrees up, across the slope. Each is mirrored or not,
    /// narrower or wider, and sheared to lean to one side with its foot on
    /// the bank, so a bank of them shows no stamped copy.
    static func fern(_ m: inout MeshBuffer, base: SIMD3<Float>, normal pn: SIMD3<Float>, along: SIMD3<Float>, size: Float,
                     rnd: inout WorldRandom) {
        let out = simd_normalize(pn * 0.87 + SIMD3(0, 0.5, 0))
        let twist = rnd.range(-0.4, 0.4)
        let side = simd_normalize(along * cos(twist) + simd_cross(out, along) * sin(twist))
        let lean = rnd.range(-0.3, 0.3)
        let dir = out * cos(lean) + side * sin(lean)
        let w = size * rnd.range(0.55, 0.8)
        var uv = grassUV(.fern)
        if rnd.unit() < 0.5 { uv = SIMD4(uv.z, uv.y, uv.x, uv.w) }
        let n = simd_normalize(pn + SIMD3(0, 1, 0))
        let foot = base + pn * 0.02
        let phase = rnd.range(0, 6.28), tint = rnd.range(0, 0.2)
        let first = UInt32(m.vertexCount)
        let pts: [(SIMD3<Float>, Float, Float, Float)] = [
            (foot - side * (w / 2), uv.x, uv.w, 0), (foot + side * (w / 2), uv.z, uv.w, 0),
            (foot + side * (w / 2) + dir * size, uv.z, uv.y, 1), (foot - side * (w / 2) + dir * size, uv.x, uv.y, 1),
        ]
        for (p, u, v, top) in pts {
            m.vertex(p.x, p.y, p.z, n.x, n.y, n.z, u, v)
            m.texcoord2(top * size * 0.8, phase)
            m.texcoord3(0.7 + 0.25 * top, tint)
            m.texcoord4(0, 0)
            m.color(0.85, 0.95, 0.85, 1)
        }
        m.tri(first, first + 1, first + 2)
        m.tri(first, first + 2, first + 3)
    }
}
