import SceneKit

/// Road-aligned meshes along the corridor: the carriageway (asphalt and
/// cobbles), the verge either side and the stone edge strips.
///
/// The verge is terrain, sampled from the same LiDAR as the grid but laid
/// out in (distance, lateral) so its first column is exactly the road edge.
/// That keeps the sunken lane's banks crisp right where they leave the
/// stones, with no z-fighting against the road. Its last column dips below
/// the grid terrain, which takes over from there.
enum RoadBuilder {
    struct Output {
        var asphalt = MeshBuffer()
        var cobbles = MeshBuffer()
        var verge = MeshBuffer()
        var kerb = MeshBuffer()
        /// Side roads near the route, draped on the 1 m terrain: part 0
        /// asphalt, part 1 cobbles.
        var sideRoads = MeshBuffer(parts: 2)
    }

    /// Lateral columns of the carriageway, as fractions of the half width.
    private static let roadColumns: [Double] = [-1, -0.94, -0.62, -0.28, 0, 0.28, 0.62, 0.94, 1]
    /// Verge columns outward from the road edge for a 13 m verge.
    private static let vergeColumns: [Double] = [0, 0.14, 0.38, 0.72, 1.15, 1.7, 2.4, 3.3, 4.4, 5.8, 7.5, 9.5, 11.5, 13.0]
    private static let coarseVergeColumns: [Double] = [0, 0.14, 0.5, 1.1, 2.0, 3.3, 5.0, 7.5, 10.5, 13.0]

    /// Every second station where the road runs straight (battery tier).
    private static func thinned(_ s: [RoadCorridor.Station]) -> [RoadCorridor.Station] {
        var out: [RoadCorridor.Station] = []
        out.reserveCapacity(s.count / 2 + 2)
        for (i, st) in s.enumerated() {
            if i == 0 || i == s.count - 1 || i % 2 == 0 || abs(st.curvature) > 0.03 || st.surface != s[i - 1].surface {
                out.append(st)
            }
        }
        return out
    }

    static func build(corridor: RoadCorridor, coarse: Bool = false) -> Output {
        var out = Output()
        let st = coarse ? thinned(corridor.stations) : corridor.stations
        let vergeColumns = coarse ? Self.coarseVergeColumns : Self.vergeColumns
        let cobble = corridor.cobbleIndex
        let nRoad = roadColumns.count
        let nVerge = vergeColumns.count
        out.asphalt.reserve(vertices: st.count * nRoad, indices: st.count * (nRoad - 1) * 6)
        out.cobbles.reserve(vertices: st.count * nRoad, indices: st.count * (nRoad - 1) * 6)
        out.verge.reserve(vertices: st.count * nVerge * 2, indices: st.count * (nVerge - 1) * 12)

        // Carriageway: one row of vertices per station, written into the
        // mesh for the surface of the strip that starts at that station.
        // Each mesh gets its own copy of the rows it uses.
        func roadRow(_ k: Int, into mesh: inout MeshBuffer) -> UInt32 {
            let s = st[k]
            let first = UInt32(mesh.vertexCount)
            let mud = corridor.art.sunkenWeight(s.s)
            for f in roadColumns {
                let lat = f * s.halfWidth
                let p = s.point(lateral: lat)
                let y = corridor.roadHeight(s, lateral: lat)
                mesh.vertex(Float(p.east), Float(y), Float(-p.north), 0, 1, 0, Float(lat), Float(s.s))
                // (0 centre .. 1 edge, mud along the sunken lane).
                mesh.texcoord2(Float(abs(f)), Float(mud))
            }
            return first
        }
        var lastRow: [Int: (mesh: Int, row: UInt32)] = [:]
        for k in 0..<(st.count - 1) {
            let isCobble = st[k].surface == cobble && cobble != nil
            let target = isCobble ? 1 : 0
            func rows(_ mesh: inout MeshBuffer) -> (UInt32, UInt32) {
                let a: UInt32
                if let prev = lastRow[k], prev.mesh == target { a = prev.row } else { a = roadRow(k, into: &mesh) }
                let b = roadRow(k + 1, into: &mesh)
                return (a, b)
            }
            let (a, b): (UInt32, UInt32)
            if isCobble { (a, b) = rows(&out.cobbles) } else { (a, b) = rows(&out.asphalt) }
            lastRow[k + 1] = (target, b)
            for c in 0..<(nRoad - 1) {
                let a0 = a + UInt32(c), a1 = a0 + 1, b0 = b + UInt32(c), b1 = b0 + 1
                if isCobble { out.cobbles.quad(a0, a1, b1, b0) } else { out.asphalt.quad(a0, a1, b1, b0) }
            }
        }
        out.asphalt.computeNormals()
        out.cobbles.computeNormals()

        // Verge, both sides.
        let terrain = corridor.terrain
        for side in [-1.0, 1.0] {
            if Task.isCancelled { return out }
            var prev: UInt32?
            for k in 0..<st.count {
                let s = st[k]
                let verge = side > 0 ? s.vergeRight : s.vergeLeft
                let scale = verge / vergeColumns.last!
                let edgeLat = side * s.halfWidth
                let edgeY = corridor.roadHeight(s, lateral: edgeLat)
                let skirt = 0.35 * smoothstepD(2, 6, verge)
                let sunk = corridor.art.sunkenWeight(s.s)
                let first = UInt32(out.verge.vertexCount)
                for (c, o0) in vergeColumns.enumerated() {
                    let o = o0 * scale
                    let p = s.point(lateral: edgeLat + side * o)
                    var y: Double
                    let dtm = Double(terrain.height(east: p.east, north: p.north))
                    if c == 0 {
                        y = edgeY
                    } else if c == 1 {
                        y = edgeY - 0.015
                    } else if c == nVerge - 1 {
                        y = dtm - skirt
                    } else {
                        y = blendedVerge(edgeY: edgeY, dtm: dtm, offset: o)
                    }
                    out.verge.vertex(Float(p.east), Float(y), Float(-p.north), 0, 1, 0, Float(p.east), Float(-p.north))
                    let rise = y - edgeY
                    let bank = Float(sunk * smoothstepD(0.15, 0.9, rise))
                    let grass = Float((1 - sunk) * smoothstepD(0.1, 0.35, o) * (1 - smoothstepD(2.0, 4.0, o)))
                    let mud = Float(sunk * (1 - smoothstepD(0.3, 1.2, o)))
                    out.verge.texcoord2(bank, grass)
                    out.verge.texcoord3(mud, 0)
                }
                if let a = prev {
                    for c in 0..<(nVerge - 1) {
                        let a0 = a + UInt32(c), a1 = a0 + 1, b0 = first + UInt32(c), b1 = b0 + 1
                        // Keep the winding counter-clockwise from above on both sides.
                        if side > 0 { out.verge.quad(a0, a1, b1, b0) } else { out.verge.quad(a0, b0, b1, a1) }
                    }
                }
                prev = first
            }
        }
        out.verge.computeNormals()

        buildKerbs(corridor: corridor, into: &out.kerb)
        return out
    }

    /// Side roads draped over the terrain where it is meshed at 1 m, a few
    /// centimetres proud (their material also pulls them towards the camera
    /// so they never fight the ground). Gravel and dirt tracks are left to
    /// the ground textures.
    static func buildSideRoads(corridor: RoadCorridor, scenery: SceneryFile?, reach: Double) -> MeshBuffer {
        var m = MeshBuffer(parts: 2)
        let terrain = corridor.terrain
        // Height of what is drawn there: the main road's verge where it
        // reaches (it sits above a falling DTM near the carriageway, and
        // would otherwise cover the junction), the DTM beyond it.
        func ground(_ e: Double, _ n: Double) -> Double {
            let dtm = Double(terrain.height(east: e, north: n))
            let q = corridor.coarse.query(east: e, north: n)
            guard q.dist < 20 else { return dtm }
            let st = corridor.station(at: q.s)
            let lat = (e - st.east) * st.rightE + (n - st.north) * st.rightN
            let side: Double = lat >= 0 ? 1 : -1
            let o = abs(lat) - st.halfWidth
            guard o < (side > 0 ? st.vergeRight : st.vergeLeft) else { return dtm }
            if o <= 0 { return corridor.roadHeight(st, lateral: lat) }
            let edgeY = corridor.roadHeight(st, lateral: side * st.halfWidth)
            return blendedVerge(edgeY: edgeY, dtm: dtm, offset: o) + 0.02
        }
        for road in sideRoadSamples(scenery: scenery) {
            if Task.isCancelled { break }
            let part = road.part, hw = road.halfWidth, pts = road.points
            var prev: (UInt32, UInt32)?
            var along = 0.0
            for i in pts.indices {
                let p = pts[i]
                if i > 0 { along += simd_distance(pts[i - 1], p) }
                let q = corridor.coarse.query(east: p.x, north: p.y)
                // Only near the route (1 m terrain), and off the main road
                // (its extensions past the ends too): up to its edge, so the
                // junction meets the carriageway.
                let onMain = corridor.mainRoadDistance(east: p.x, north: p.y).map { $0.dist < $0.halfWidth + 0.1 } ?? false
                guard q.dist < reach, !onMain else { prev = nil; continue }
                let a = pts[max(i - 1, 0)], b = pts[min(i + 1, pts.count - 1)]
                var d = b - a
                let l = simd_length(d)
                guard l > 1e-6 else { continue }
                d /= l
                let side = SIMD2(d.y, -d.x)
                let pl = p - side * hw, pr = p + side * hw
                let yl = ground(pl.x, pl.y) + 0.04
                let yr = ground(pr.x, pr.y) + 0.04
                let il = m.vertex(Float(pl.x), Float(yl), Float(-pl.y), 0, 1, 0, Float(-hw), Float(along))
                m.texcoord2(1, 0)
                let ir = m.vertex(Float(pr.x), Float(yr), Float(-pr.y), 0, 1, 0, Float(hw), Float(along))
                m.texcoord2(1, 0)
                if let (a0, b0) = prev {
                    m.quad(a0, b0, ir, il, part: part)
                }
                prev = (il, ir)
            }
        }
        m.computeNormals()
        return m
    }

    /// A paved side road from the scenery, resampled at 1 m.
    struct SideRoad {
        var points: [SIMD2<Double>]
        var halfWidth: Double
        /// 0 asphalt, 1 cobbles.
        var part: Int
    }

    /// The scenery's paved roads, as `buildSideRoads` drapes them. Gravel
    /// and dirt tracks are left out (the ground textures carry them).
    static func sideRoadSamples(scenery: SceneryFile?) -> [SideRoad] {
        var out: [SideRoad] = []
        for road in scenery?.roads ?? [] {
            let surf = road.surface ?? "asphalt"
            guard surf == "asphalt" || surf == "cobbles" else { continue }
            let raw = road.points.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }
            guard raw.count >= 2 else { continue }
            var pts: [SIMD2<Double>] = []
            for i in 0..<(raw.count - 1) {
                let a = raw[i], b = raw[i + 1]
                let n = max(Int(simd_distance(a, b).rounded(.up)), 1)
                for k in 0..<n { pts.append(a + (b - a) * (Double(k) / Double(n))) }
            }
            pts.append(raw[raw.count - 1])
            out.append(SideRoad(points: pts, halfWidth: max((road.widthM ?? 3.5) / 2, 1.2), part: surf == "cobbles" ? 1 : 0))
        }
        return out
    }

    /// Where the side roads are, for keeping plants off them: their 1 m
    /// samples hashed into 2 m cells.
    struct SideRoadMask: Sendable {
        private static let cell = 2.0
        private var cells: [Int64: [SIMD3<Double>]] = [:]
        private var maxHalfWidth = 0.0

        init(scenery: SceneryFile?) {
            for road in RoadBuilder.sideRoadSamples(scenery: scenery) {
                maxHalfWidth = max(maxHalfWidth, road.halfWidth)
                for p in road.points {
                    cells[Self.key(p.x, p.y), default: []].append(SIMD3(p.x, p.y, road.halfWidth))
                }
            }
        }

        private static func key(_ e: Double, _ n: Double) -> Int64 {
            Int64(floor(e / cell)) &* 1_000_003 &+ Int64(floor(n / cell))
        }

        /// True when (east, north) is on a side road, or within `margin` of
        /// its edge.
        func covers(east e: Double, north n: Double, margin: Double = 0.3) -> Bool {
            guard !cells.isEmpty else { return false }
            let reach = maxHalfWidth + margin + 1
            let r = Int(ceil(reach / Self.cell))
            let ci = Int64(floor(e / Self.cell)), cj = Int64(floor(n / Self.cell))
            for di in -r...r {
                for dj in -r...r {
                    guard let pts = cells[(ci + Int64(di)) &* 1_000_003 &+ (cj + Int64(dj))] else { continue }
                    for p in pts {
                        let need = p.z + margin + 0.5  // half the 1 m sample spacing
                        let dx = p.x - e, dy = p.y - n
                        if dx * dx + dy * dy < need * need { return true }
                    }
                }
            }
            return false
        }
    }

    /// Verge height `offset` metres out from the road edge: the LiDAR
    /// ground, eased in from the edge quickly where it rises (banks) and
    /// gently where it falls away (the culvert, embankments).
    @inline(__always)
    static func blendedVerge(edgeY: Double, dtm: Double, offset o: Double) -> Double {
        let diff = dtm - edgeY
        let w = diff > 0 ? smoothstepD(0.08, 0.75, o) : smoothstepD(0.15, 2.6, o)
        return edgeY + diff * w
    }

    /// A point on the verge surface, matching the verge mesh between its
    /// columns closely enough to stand plants on.
    static func vergePoint(_ corridor: RoadCorridor, _ st: RoadCorridor.Station, side: Double,
                           offset o: Double) -> (east: Double, north: Double, y: Double, edgeY: Double) {
        let edgeLat = side * st.halfWidth
        let edgeY = corridor.roadHeight(st, lateral: edgeLat)
        let p = st.point(lateral: edgeLat + side * o)
        let dtm = Double(corridor.terrain.height(east: p.east, north: p.north))
        return (p.east, p.north, blendedVerge(edgeY: edgeY, dtm: dtm, offset: o), edgeY)
    }

    /// Long granite edge stones flush with the cobbles, 2 cm proud.
    private static func buildKerbs(corridor: RoadCorridor, into mesh: inout MeshBuffer) {
        let width = 0.24, proud = 0.02
        for span in corridor.art.kerbs {
            var prev: UInt32?
            for s in corridor.stations where span.contains(s.s) && s.beyond == 0 {
                let outer = -s.halfWidth, inner = -s.halfWidth + width
                let yO = corridor.roadHeight(s, lateral: outer) + proud
                let yI = corridor.roadHeight(s, lateral: inner) + proud
                let yBase = corridor.roadHeight(s, lateral: inner) - 0.01
                let po = s.point(lateral: outer + 0.005), pi = s.point(lateral: inner)
                let first = UInt32(mesh.vertexCount)
                mesh.vertex(Float(po.east), Float(yO), Float(-po.north), 0, 1, 0, 0, Float(s.s))
                mesh.vertex(Float(pi.east), Float(yI), Float(-pi.north), 0, 1, 0, Float(width), Float(s.s))
                mesh.vertex(Float(pi.east), Float(yBase), Float(-pi.north), Float(s.rightE), 0, Float(-s.rightN), Float(width + 0.03), Float(s.s))
                let mud = Float(corridor.art.sunkenWeight(s.s))
                for _ in 0..<3 { mesh.texcoord2(1, mud) }
                if let p = prev {
                    mesh.quad(p, p + 1, first + 1, first)
                    mesh.quad(p + 1, p + 2, first + 2, first + 1)
                }
                prev = first
            }
        }
        mesh.computeNormals()
    }
}
