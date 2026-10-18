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
enum VegetationBuilder {
    struct Cluster {
        var full = MeshBuffer(parts: 2)
        var light = MeshBuffer(parts: 2)
        var impostor = MeshBuffer(parts: 2)
    }

    struct Output {
        var clusters: [Cluster] = []
        var grassCells: [(s: Double, mesh: MeshBuffer)] = []
        var counts: [String: Int] = [:]
    }

    static let clusterSize = 48.0
    /// Length of a streamed verge-grass section, metres of route.
    static let grassCellM = 4.0

    static func build(corridor: RoadCorridor, scenery: SceneryFile?, config: WorldConfig,
                      ground: GroundColor? = nil) -> Output {
        var out = Output()
        let archetypes = TreeArchetype.makeAll()
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
        var nFull = 0, nLight = 0
        for t in scenery?.trees ?? [] {
            if Task.isCancelled { return finish() }
            var e = t.e, n = t.n
            let q = corridor.coarse.query(east: e, north: n)
            // (Any distance from the route: the road's extensions past its
            // ends are in the near field too.)
            if let push = roadClearance(e, n, margin: 1.1) {
                e += push.dE; n += push.dN
            }
            let y = Float(terrain.height(east: e, north: n))
            guard y.isFinite else { continue }
            var rnd = WorldRandom(e, n, salt: 17)
            let h = Float(t.heightM), r = Float(t.crownRadiusM)
            let ratio = h / max(r, 0.5)
            let lu = landuse.kind(east: e, north: n)
            let arch: TreeArchetype
            if t.kind == "conifer" || (lu == "residential" && rnd.unit() < 0.14 && ratio > 2.4 && h < 18) {
                arch = archetypes[5]
            } else if lu == "orchard" || (h <= 7.5 && ratio <= 2.6 && lu != "forest") {
                arch = archetypes[rnd.unit() < 0.5 ? 6 : 7]
            } else if h >= 13 && ratio >= 4.2 {
                arch = archetypes[rnd.unit() < 0.5 ? 3 : 4]
            } else {
                arch = archetypes[Int(rnd.unit() * 3) % 3]
            }
            let sy = h / arch.refHeight
            let sxz = min(max(r / arch.refRadius, sy * 0.45), sy * 1.9)
            let yaw = rnd.range(0, 6.283)
            let phase = rnd.range(0, 6.283)
            let tint = max(0, rnd.range(-0.25, 0.55))
            let ck = key(e, n)
            var c = take(ck)
            let x = Float(e), z = Float(-n)
            // On the holle weg's banks the trees reach out over the lane
            // for light, closing the tunnel above the steepest part.
            var lean = SIMD2<Float>.zero
            let sunk = corridor.art.sunkenWeight(q.s)
            if sunk > 0.2, q.dist < 16 {
                let st = corridor.station(at: q.s)
                let side: Double = ((e - st.east) * st.rightE + (n - st.north) * st.rightN) >= 0 ? 1 : -1
                let amount = Float(sunk) * min(0.55 * r, 5) * (1 - Float(q.dist) / 20)
                lean = SIMD2(Float(-st.rightE * side), Float(st.rightN * side)) * amount
            }
            if q.dist < config.treeDetailRouteRadius {
                appendPlant(&c.full, arch.full, sx: sxz, sy: sy, yaw: yaw, x: x, y: y, z: z, phase: phase, tint: tint,
                            lean: lean, height: h)
                nFull += 1
            }
            appendPlant(&c.light, arch.light, sx: sxz, sy: sy, yaw: yaw, x: x, y: y, z: z, phase: phase, tint: tint,
                        lean: lean, height: h)
            nLight += 1
            impostor(&c.impostor, cell: arch.impostorCell, width: max(2.1 * r, h * 0.25), height: h * 1.02,
                     x: x, y: y - 0.2, z: z, yaw: yaw, phase: phase, tint: tint)
            clusters[ck] = c
        }
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
                    TreeArchetype.card(&c.full, centre: centre + o, size: cardSize * rnd.range(0.85, 1.15), normal: d,
                                       roll: rnd.range(-0.5, 0.5), uv: sunken && rnd.unit() < 0.5 ? TreeArchetype.ivyUV : uv,
                                       crownCentre: centre - SIMD3(0, h * 0.3, 0), crownRadii: radii, height: max(h, 2) * 3,
                                       ao: 0.88, bend: 0.6, baseY: y)
                }
                patchPhase(&c.full, from: first, phase: phase, tint: tint)
                nShrubD += 1
            }
            let firstL = c.light.vertexCount
            for k in 0..<2 {
                let az = rnd.range(0, 3.14) + Float(k) * 1.57
                TreeArchetype.card(&c.light, centre: centre, size: max(2 * r, h) * 1.1, normal: SIMD3(cos(az), 0.2, sin(az)),
                                   roll: 0, uv: uv, crownCentre: centre - SIMD3(0, h * 0.3, 0), crownRadii: radii,
                                   height: max(h, 2) * 3, ao: 0.85, bend: 0.6, baseY: y)
            }
            patchPhase(&c.light, from: firstL, phase: phase, tint: tint)
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
        var nBank = 0
        if config.bankPlantDensity > 0 {
            var rnd = WorldRandom(seed: 4242)
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
                                               height: 3, ao: rnd.range(0.82, 0.95), bend: 0.35, baseY: pos.y - 1, billboard: false)
                            patchPhase(&cl.full, from: first, phase: rnd.range(0, 6.28), tint: rnd.range(0, 0.12))
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
                                TreeArchetype.card(&cl.full, centre: c, size: size * rnd.range(0.8, 1.05), normal: TreeArchetype.randomDir(&rnd, minY: -0.2),
                                                   roll: rnd.range(-0.5, 0.5), uv: rnd.unit() < 0.65 ? TreeArchetype.ivyUV : TreeArchetype.broadUV,
                                                   crownCentre: base, crownRadii: SIMD3(size, size * 0.7, size), height: 3,
                                                   ao: rnd.range(0.8, 0.95), bend: 0.6, baseY: base.y)
                            }
                            patchPhase(&cl.full, from: first, phase: rnd.range(0, 6.28), tint: rnd.range(0.05, 0.25))
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
                            clusters[ck] = cl
                            nBank += 1
                        }
                    }
                    s += step
                }
            }
        }
        out.counts["bank plants"] = nBank
        out.clusters = Array(clusters.values).filter { !$0.light.isEmpty || !$0.full.isEmpty }

        // Verge grass, in short route sections; none on side-road tarmac.
        if config.grassDensity > 0 {
            var rnd = WorldRandom(seed: 777)
            let cell = grassCellM
            var s0 = 0.0
            var tufts = 0
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
                        let density = config.grassDensity * (1 - 0.65 * village) * (1 - 0.6 * sunk)
                        let count = Int(density * (oMax - 0.1) * 0.5 + Double(rnd.unit()))
                        for _ in 0..<count {
                            let o = Double(rnd.range(0.1, Float(oMax)))
                            let ss = s + Double(rnd.unit()) * 0.5
                            let st2 = corridor.station(at: ss)
                            let p = RoadBuilder.vergePoint(corridor, st2, side: side, offset: o)
                            if (p.y - p.edgeY) / max(o, 0.1) > 1.3 { continue }
                            if sideRoads.covers(east: p.east, north: p.north) { continue }
                            let tint = grassTint(ground?.color(east: p.east, north: p.north), sunk: Float(sunk))
                            let tall = Double(rnd.unit()) >= village && sunk < 0.3
                            grassTuft(&mesh, x: Float(p.east), y: Float(p.y) - 0.02, z: Float(-p.north), rnd: &rnd,
                                      tall: tall, tint: tint)
                            tufts += 1
                        }
                    }
                    s += 0.5
                }
                if !mesh.isEmpty { out.grassCells.append((s0 + cell / 2, mesh)) }
                s0 += cell
            }
            out.counts["grass tufts"] = tufts
        }
        return out
    }

    // MARK: - Pieces

    /// Appends a scaled, turned plant and stamps its per-plant phase and tint.
    static func appendPlant(_ m: inout MeshBuffer, _ src: MeshBuffer, sx: Float, sy: Float, yaw: Float,
                            x: Float, y: Float, z: Float, phase: Float, tint: Float,
                            lean: SIMD2<Float> = .zero, height: Float = 1) {
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
    }

    static func patchPhase(_ m: inout MeshBuffer, from first: Int, phase: Float, tint: Float) {
        guard m.uv2.count == m.vertexCount * 2, m.uv3.count == m.vertexCount * 2 else { return }
        for i in first..<m.vertexCount {
            m.uv2[2 * i + 1] = phase
            m.uv3[2 * i + 1] = tint
        }
    }

    /// A camera-facing (about the vertical) quad showing an impostor-atlas
    /// cell, trunk base at (x, y, z). The corners sit on the base and carry
    /// their offsets in texture channel 3 for the impostor shader.
    static func impostor(_ m: inout MeshBuffer, cell: Int, width: Float, height: Float,
                         x: Float, y: Float, z: Float, yaw: Float, phase: Float, tint: Float) {
        let u0 = Float(cell % 2) * 0.5 + 0.004, u1 = u0 + 0.492
        let v0 = Float(cell / 2) * 0.5 + 0.004, v1 = v0 + 0.492
        let first = UInt32(m.vertexCount)
        let pts: [(Float, Float, Float, Float)] = [(-width / 2, 0, u0, v1), (width / 2, 0, u1, v1),
                                                    (width / 2, height, u1, v0), (-width / 2, height, u0, v0)]
        for (ox, oy, u, v) in pts {
            m.vertex(x, y, z, 0, 1, 0, u, v)
            m.texcoord2(oy / max(height, 1) * 0.3, phase)
            m.texcoord3(0.92, tint)
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
    static func grassTint(_ ground: SIMD3<Float>?, sunk: Float) -> SIMD3<Float> {
        guard let g = ground else { return SIMD3(1, 1, 1) }
        let ratio = simd_clamp(g / grassCardColor, SIMD3(repeating: 0.55), SIMD3(1.7, 1.7, 1.3))
        let t = SIMD3<Float>(1, 1, 1) + (ratio - SIMD3(1, 1, 1)) * 0.7
        return t * (1 - 0.25 * sunk)
    }

    /// A grass tuft: two crossed cards from cj_grass.png.
    static func grassTuft(_ m: inout MeshBuffer, x: Float, y: Float, z: Float, rnd: inout WorldRandom, tall: Bool,
                          tint colour: SIMD3<Float> = SIMD3(1, 1, 1)) {
        let variant: Float = tall && rnd.unit() < 0.45 ? 1 : 0
        let w = rnd.range(0.32, 0.6)
        let h = tall ? rnd.range(0.3, 0.62) : rnd.range(0.18, 0.36)
        let u0 = variant * 0.5 + 0.004, u1 = u0 + 0.492
        let yaw = rnd.range(0, 3.14)
        let phase = rnd.range(0, 6.28)
        let tint = max(0, rnd.range(-0.2, 0.5))
        for k in 0..<2 {
            let a = yaw + Float(k) * 1.5708
            let dx = cos(a) * w / 2, dz = sin(a) * w / 2
            let first = UInt32(m.vertexCount)
            let lean = SIMD2<Float>(rnd.range(-0.08, 0.08), rnd.range(-0.08, 0.08))
            let pts: [(Float, Float, Float, Float, Float, Float)] = [
                (x - dx, y, z - dz, u0, 0.995, 0), (x + dx, y, z + dz, u1, 0.995, 0),
                (x + dx + lean.x, y + h, z + dz + lean.y, u1, 0.01, 1), (x - dx + lean.x, y + h, z - dz + lean.y, u0, 0.01, 1),
            ]
            for (px, py, pz, u, v, top) in pts {
                m.vertex(px, py, pz, -sin(a) * 0.25, 0.97, cos(a) * 0.25, u, v)
                m.texcoord2(top * h * 1.2, phase)
                m.texcoord3(0.75 + 0.25 * top, tint)
                m.texcoord4(0, 0)
                m.color(colour.x, colour.y, colour.z, 1)
            }
            m.tri(first, first + 1, first + 2)
            m.tri(first, first + 2, first + 3)
        }
    }
}
