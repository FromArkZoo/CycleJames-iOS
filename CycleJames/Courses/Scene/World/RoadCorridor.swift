import Foundation
import simd

/// Ground heights from the near (1 m) and far (10 m) LiDAR grids, with the
/// near grid faded into the far one over its outer band so the two meshes
/// meet without a step.
struct TerrainSampler: Sendable {
    let near: HeightRaster
    let far: HeightRaster?
    /// Width of the near grid's outer band that blends into the far grid.
    let blendBand: Double = 40

    /// Far-grid height, or the clamped near grid when there is no far grid.
    func farHeight(east: Double, north: Double) -> Float {
        if let far {
            let v = far.sample(east: east, north: north)
            if !v.isNaN { return v }
        }
        let v = near.sample(east: east, north: north)
        return v.isNaN ? 0 : v
    }

    /// Distance from a point to the near grid's edge, negative outside.
    @inline(__always)
    func nearEdgeDistance(east: Double, north: Double) -> Double {
        min(east - near.minEast, near.maxEast - east, north - near.minNorth, near.maxNorth - north)
    }

    /// Blended ground height anywhere in the world.
    func height(east: Double, north: Double) -> Float {
        let edge = nearEdgeDistance(east: east, north: north)
        if edge <= 0 { return farHeight(east: east, north: north) }
        var h = near.sample(east: east, north: north)
        if h.isNaN { return farHeight(east: east, north: north) }
        if edge < blendBand {
            let w = smoothstepF(0, Float(blendBand), Float(edge))
            let f = farHeight(east: east, north: north)
            h = f + (h - f) * w
        }
        return h
    }

    /// Height at the centre of near cell (col, row): the raw LiDAR value
    /// with the border blend applied.
    @inline(__always)
    func lattice(col: Int, row: Int) -> Float {
        let c = min(max(col, 0), near.cols - 1), r = min(max(row, 0), near.rows - 1)
        var h = near.values[r * near.cols + c]
        let edge = Double(min(c, near.cols - 1 - c, r, near.rows - 1 - r)) * near.cellM + near.cellM / 2
        if h.isNaN || edge < blendBand {
            let e = near.originEast + (Double(c) + 0.5) * near.cellM
            let n = near.originNorth - (Double(r) + 0.5) * near.cellM
            let f = farHeight(east: e, north: n)
            if h.isNaN { return f }
            let w = smoothstepF(0, Float(blendBand), Float(edge))
            h = f + (h - f) * w
        }
        return h
    }
}

/// The road through the world: a smoothed centreline extended a little past
/// both ends of the route, the carriageway and verge widths at each station,
/// and two distance fields used to fit the terrain round it.
///
/// The extensions follow the scenery road the route joins at each end (the
/// Meldenstraat behind the Koppenberg's start bends away towards the N8;
/// carried straight on it would run into a house), and only fall back to the
/// end tangent where there is none.
///
/// Building it stops early (leaving the fields incomplete) when the calling
/// task is cancelled; the caller checks for cancellation straight after.
final class RoadCorridor: @unchecked Sendable {
    struct Station {
        var s: Double
        var east: Double
        var north: Double
        /// Road-surface elevation at the centreline.
        var elev: Double
        /// Unit horizontal direction of travel (east, north).
        var dirE: Double
        var dirN: Double
        var halfWidth: Double
        var surface: Int
        /// Width of the road-aligned verge mesh beyond each carriageway edge.
        var vergeLeft: Double
        var vergeRight: Double
        /// How far the carriageway's cross-section is drawn each side of the
        /// centreline: the half width, less only on the Riviera where the
        /// road turns tighter than that or comes back past itself
        /// (`RoadCorridor.clearances`).
        var reachLeft: Double
        var reachRight: Double
        /// Signed curvature, 1/m, positive turning right.
        var curvature: Double
        /// 0 on the route, rising to 1 at the far end of an extension.
        var beyond: Double

        var rightE: Double { dirN }
        var rightN: Double { -dirE }

        func point(lateral: Double) -> (east: Double, north: Double) {
            (east + rightE * lateral, north + rightN * lateral)
        }

        /// `reachLeft` or `reachRight` (side −1 or +1).
        @inline(__always)
        func reach(_ side: Double) -> Double { side < 0 ? reachLeft : reachRight }
    }

    let route: CourseRoute
    /// The timed climb's start and summit on the route.
    let climb: CourseFile.ClimbRange
    /// The course's art direction (sunken lane, hand-placed roadside details).
    let art: CourseArt
    let stations: [Station]
    let cobbleIndex: Int?
    let concreteIndex: Int?
    let terrain: TerrainSampler
    let near: NearField
    let coarse: CoarseField
    /// Where paved side roads meet the carriageway (Riviera only; the
    /// edge lines break there): route distance, side and the side road's
    /// width at the mouth.
    let junctions: [(s: Double, side: Double, width: Double)]
    /// The scenery, for the Riviera road's paving out to the walls at the
    /// edge (`RoadBuilder.build`, `edgeAprons`); nil elsewhere.
    let edgeScenery: SceneryFile?

    /// Road crown (cross-fall per metre from the centreline) by surface.
    static func crown(surface: Int, cobbleIndex: Int?) -> Double {
        surface == cobbleIndex ? 0.008 : 0.018
    }

    init(bundle: CourseBundle, vergeWidth: Double, extensionM: Double = 70) {
        route = bundle.route
        climb = bundle.course.climb
        art = CourseArt.make(bundle: bundle)
        // The Poggio's summit car park cut to the junction's level (the
        // same raster elsewhere): RoadsideBuilder+PoggioSummit.swift.
        let nearRaster = BuildingBuilder.levelledNear(bundle.terrainNear, courseID: bundle.course.id)
        terrain = TerrainSampler(near: nearRaster, far: bundle.terrainFar)
        cobbleIndex = bundle.course.surfaces.firstIndex(of: "cobbles")
        concreteIndex = bundle.course.surfaces.firstIndex(of: "concrete")
        var st = Self.makeStations(route: route, terrain: terrain, vergeWidth: vergeWidth, extensionM: extensionM,
                                   roads: bundle.scenery?.roads ?? [])
        // The Flemish climbs never double back; the Poggio's hairpins and
        // summit loop do.
        let riviera = art.look.isRiviera
        if riviera { Self.clearances(&st, vergeWidth: vergeWidth) }
        stations = st
        near = NearField(stations: stations, raster: nearRaster, reach: vergeWidth + 4)
        let coarseField = CoarseField(stations: st, raster: nearRaster, cell: 4, neighbours: riviera)
        coarse = coarseField
        junctions = riviera ? Self.sideJunctions(stations: st, coarse: coarseField, scenery: bundle.scenery) : []
        edgeScenery = riviera ? bundle.scenery : nil
    }

    /// Distance from a point to the carriageway's centreline (extensions
    /// included) and the half width there; nil out of the near field's reach
    /// (a verge width and a few metres beyond the carriageway).
    func mainRoadDistance(east: Double, north: Double) -> (dist: Double, halfWidth: Double)? {
        let r = terrain.near
        let col = Int(floor((east - r.originEast) / r.cellM)), row = Int(floor((r.originNorth - north) / r.cellM))
        guard let f = near.lookup(col: col, row: row) else { return nil }
        func onSegment(_ i: Int) -> (dist: Double, halfWidth: Double) {
            let a = stations[i], b = stations[min(i + 1, stations.count - 1)]
            let vx = b.east - a.east, vy = b.north - a.north
            let t = min(max(((east - a.east) * vx + (north - a.north) * vy) / max(vx * vx + vy * vy, 1e-9), 0), 1)
            let dx = east - a.east - vx * t, dy = north - a.north - vy * t
            return ((dx * dx + dy * dy).squareRoot(), a.halfWidth + (b.halfWidth - a.halfWidth) * t)
        }
        var best = onSegment(f.segment)
        if coarse.neighbours {
            // The cell's nearest segment is its centre's: near the line
            // between two legs of a hairpin a point can be nearer the other
            // leg, which one of the neighbouring cells holds.
            for dr in -1...1 {
                for dc in -1...1 where dr != 0 || dc != 0 {
                    guard let g = near.lookup(col: col + dc, row: row + dr), g.segment != f.segment else { continue }
                    let d = onSegment(g.segment)
                    if d.dist < best.dist { best = d }
                }
            }
        }
        return best
    }

    /// Road-surface height at a lateral offset from a station's centreline.
    @inline(__always)
    func roadHeight(_ st: Station, lateral: Double) -> Double {
        let hw = st.halfWidth
        let d = min(abs(lateral), hw)
        return st.elev - Self.crown(surface: st.surface, cobbleIndex: cobbleIndex) * d
    }

    /// Interpolated station at route distance `s` (extensions included).
    func station(at s: Double) -> Station {
        var lo = 0, hi = stations.count - 1
        if s <= stations[lo].s { return stations[lo] }
        if s >= stations[hi].s { return stations[hi] }
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if stations[mid].s <= s { lo = mid } else { hi = mid }
        }
        let span = stations[hi].s - stations[lo].s
        return station(lo, span > 0 ? (s - stations[lo].s) / span : 0)
    }

    /// Interpolated station between `i` and `i + 1`.
    func station(_ i: Int, _ t: Double) -> Station {
        let a = stations[i], b = stations[min(i + 1, stations.count - 1)]
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        var st = a
        st.s = mix(a.s, b.s); st.east = mix(a.east, b.east); st.north = mix(a.north, b.north)
        st.elev = mix(a.elev, b.elev); st.halfWidth = mix(a.halfWidth, b.halfWidth)
        st.vergeLeft = mix(a.vergeLeft, b.vergeLeft); st.vergeRight = mix(a.vergeRight, b.vergeRight)
        st.reachLeft = mix(a.reachLeft, b.reachLeft); st.reachRight = mix(a.reachRight, b.reachRight)
        st.beyond = mix(a.beyond, b.beyond)
        let de = mix(a.dirE, b.dirE), dn = mix(a.dirN, b.dirN)
        let l = max(sqrt(de * de + dn * dn), 1e-9)
        st.dirE = de / l; st.dirN = dn / l
        return st
    }

    // MARK: - Centreline

    /// Points every 2 m (the first 2 m from `start`) for `length` metres
    /// along the scenery road that leaves `start` heading roughly `away`,
    /// eased in from the straight line along `away` over the first 12 m, and
    /// straight on past the road's end. All straight when no road fits.
    static func runOut(from start: SIMD2<Double>, away: SIMD2<Double>, roads: [SceneryFile.Road],
                       length: Double) -> [SIMD2<Double>] {
        // The best-aligned road with a point within 2 m of the start, as a
        // 1 m path leading away from it.
        var best: (score: Double, path: [SIMD2<Double>])?
        for road in roads {
            let raw = road.points.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }
            guard raw.count >= 2 else { continue }
            var pts: [SIMD2<Double>] = []
            for i in 0..<(raw.count - 1) {
                let a = raw[i], b = raw[i + 1]
                let n = max(Int(simd_distance(a, b).rounded(.up)), 1)
                for k in 0..<n { pts.append(a + (b - a) * (Double(k) / Double(n))) }
            }
            pts.append(raw[raw.count - 1])
            guard let i = pts.indices.min(by: { simd_distance(pts[$0], start) < simd_distance(pts[$1], start) }),
                  simd_distance(pts[i], start) < 2 else { continue }
            for path in [Array(pts[i...]), Array(pts[...i].reversed())] where path.count > 4 {
                let probe = path[min(8, path.count - 1)] - start
                let l = simd_length(probe)
                guard l > 1 else { continue }
                let score = simd_dot(probe / l, away)
                if score > 0.6, score > (best?.score ?? -1) { best = (score, path) }
            }
        }
        // Rounded corners: a moving average over about 9 m (the ends held).
        var path = best?.path ?? []
        if path.count > 8 {
            var smooth = path
            for k in 1..<(path.count - 1) {
                let lo = max(0, k - 4), hi = min(path.count - 1, k + 4)
                smooth[k] = path[lo...hi].reduce(SIMD2<Double>.zero, +) / Double(hi - lo + 1)
            }
            path = smooth
        }
        // Arc lengths along it.
        var arc = [Double](repeating: 0, count: path.count)
        for k in path.indices.dropFirst() { arc[k] = arc[k - 1] + simd_distance(path[k - 1], path[k]) }
        func roadPoint(_ a: Double) -> SIMD2<Double>? {
            guard path.count >= 2 else { return nil }
            if a >= arc[arc.count - 1] {
                let d = simd_normalize(path[path.count - 1] - path[path.count - 2])
                return path[path.count - 1] + d * (a - arc[arc.count - 1])
            }
            var k = 1
            while arc[k] < a { k += 1 }
            let t = (a - arc[k - 1]) / max(arc[k] - arc[k - 1], 1e-9)
            return path[k - 1] + (path[k] - path[k - 1]) * t
        }
        var out: [SIMD2<Double>] = []
        for k in 1...Int(length / 2) {
            let a = Double(k) * 2
            let straight = start + away * a
            guard let r = roadPoint(a) else { out.append(straight); continue }
            out.append(straight + (r - straight) * smoothstepD(0, 12, a))
        }
        return out
    }

    private static func makeStations(route: CourseRoute, terrain: TerrainSampler, vergeWidth: Double, extensionM: Double,
                                     roads: [SceneryFile.Road]) -> [Station] {
        let n = route.count
        // Catmull-Rom through the 1 m route stations for a smooth road edge.
        func cr(_ arr: [Double], _ i: Int, _ t: Double) -> Double {
            let p0 = arr[max(i - 1, 0)], p1 = arr[i], p2 = arr[min(i + 1, n - 1)], p3 = arr[min(i + 2, n - 1)]
            let t2 = t * t, t3 = t2 * t
            return 0.5 * (2 * p1 + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
        }
        func crd(_ arr: [Double], _ i: Int, _ t: Double) -> Double {
            let p0 = arr[max(i - 1, 0)], p1 = arr[i], p2 = arr[min(i + 1, n - 1)], p3 = arr[min(i + 2, n - 1)]
            let t2 = t * t
            return 0.5 * ((-p0 + p2) + 2 * (2 * p0 - 5 * p1 + 4 * p2 - p3) * t + 3 * (-p0 + 3 * p1 - 3 * p2 + p3) * t2)
        }
        // Heading change per metre, to choose the station spacing.
        var turn = [Double](repeating: 0, count: n)
        for i in 1..<(n - 1) {
            let h0 = atan2(route.east[i] - route.east[i - 1], route.north[i] - route.north[i - 1])
            let h1 = atan2(route.east[i + 1] - route.east[i], route.north[i + 1] - route.north[i])
            var d = h1 - h0
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            turn[i] = d / max(route.s[i + 1] - route.s[i], 0.01)
        }

        var out: [Station] = []
        out.reserveCapacity(n * 2)
        func add(s: Double, e: Double, nn: Double, elev: Double, de: Double, dn: Double, hw: Double, surf: Int, ext: Double) {
            let l = max(sqrt(de * de + dn * dn), 1e-9)
            out.append(Station(s: s, east: e, north: nn, elev: elev, dirE: de / l, dirN: dn / l,
                               halfWidth: hw, surface: surf, vergeLeft: vergeWidth, vergeRight: vergeWidth,
                               reachLeft: hw, reachRight: hw, curvature: 0, beyond: ext))
        }

        /// Unit direction from point k to point k + 1 of a run-out (from its
        /// start for k = -1), for the station headings.
        func heading(_ pts: [SIMD2<Double>], _ start: SIMD2<Double>, _ k: Int) -> SIMD2<Double> {
            let a = k <= 0 ? start : pts[k - 1], b = pts[min(k + 1, pts.count - 1)]
            let d = b - a
            let l = simd_length(d)
            return l > 1e-6 ? d / l : SIMD2(1, 0)
        }

        // Extension before the start, back along the road the route joins.
        let d0 = route.direction(at: 0)
        let ext0Count = Int(extensionM / 2)
        let start = SIMD2(route.east[0], route.north[0])
        let back0 = runOut(from: start, away: -d0, roads: roads, length: extensionM)
        for k in stride(from: ext0Count, to: 0, by: -1) {
            let back = Double(k) * 2
            let p = back0[k - 1]
            // Travel runs towards the start, against the run-out.
            let h = -heading(back0, start, k - 1)
            add(s: -back, e: p.x, nn: p.y, elev: 0, de: h.x, dn: h.y, hw: route.widthM[0] / 2,
                surf: route.surface[0], ext: back / extensionM)
        }
        for i in 0..<(n - 1) {
            let sharp = max(abs(turn[i]), abs(turn[i + 1]))
            let sub = sharp > 0.12 ? 4 : (sharp > 0.04 ? 2 : 1)
            for k in 0..<sub {
                let t = Double(k) / Double(sub)
                let s = route.s[i] + (route.s[i + 1] - route.s[i]) * t
                add(s: s, e: cr(route.east, i, t), nn: cr(route.north, i, t), elev: route.elevation(at: s),
                    de: crd(route.east, i, t), dn: crd(route.north, i, t),
                    hw: route.width(at: s) / 2, surf: route.surfaceIndex(at: s), ext: 0)
            }
        }
        let dl = route.direction(at: route.length)
        add(s: route.length, e: route.east[n - 1], nn: route.north[n - 1], elev: route.elev[n - 1],
            de: dl.x, dn: dl.y, hw: route.widthM[n - 1] / 2, surf: route.surface[n - 1], ext: 0)
        // And past the finish, on along the road it joins.
        let end = SIMD2(route.east[n - 1], route.north[n - 1])
        let on = runOut(from: end, away: dl, roads: roads, length: extensionM)
        for k in 1...Int(extensionM / 2) {
            let fwd = Double(k) * 2
            let p = on[k - 1], h = heading(on, end, k - 1)
            add(s: route.length + fwd, e: p.x, nn: p.y,
                elev: 0, de: h.x, dn: h.y, hw: route.widthM[n - 1] / 2, surf: route.surface[n - 1], ext: fwd / extensionM)
        }

        // Extension elevations: the LiDAR road surface, smoothed, eased in
        // from the route's own end elevation.
        let first = ext0Count
        let last = out.count - Int(extensionM / 2)
        var raw = out.map { Double(terrain.height(east: $0.east, north: $0.north)) }
        var smooth = raw
        for i in out.indices {
            var acc = 0.0, w = 0.0
            for j in max(0, i - 5)...min(out.count - 1, i + 5) { acc += raw[j]; w += 1 }
            smooth[i] = acc / w
        }
        raw = smooth
        for i in 0..<first {
            let a = out[i].beyond
            let blend = smoothstepD(0, 0.6, a)
            out[i].elev = route.elev[0] + (raw[i] - raw[first]) * blend
        }
        for i in last..<out.count {
            let a = out[i].beyond
            let blend = smoothstepD(0, 0.6, a)
            out[i].elev = route.elev[n - 1] + (raw[i] - raw[last - 1]) * blend
        }

        // Curvature from the smoothed directions.
        for i in out.indices {
            let a = out[max(i - 1, 0)], b = out[min(i + 1, out.count - 1)]
            let h0 = atan2(a.dirE, a.dirN), h1 = atan2(b.dirE, b.dirN)
            var d = h1 - h0
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            out[i].curvature = d / max(b.s - a.s, 0.05)
        }
        // On the inside of a bend the verge can't reach further than the
        // bend's radius or its cross-sections would fold over each other.
        var limL = [Double](repeating: vergeWidth, count: out.count)
        var limR = limL
        for i in out.indices {
            let k = out[i].curvature
            guard abs(k) > 1e-4 else { continue }
            let room = max(0.6, 0.8 / abs(k) - out[i].halfWidth)
            // Spread the limit over the stations whose sections can reach it.
            let reach = vergeWidth + 2
            var j = i
            while j >= 0, out[i].s - out[j].s <= reach { j -= 1 }
            let lo = max(j, 0)
            j = i
            while j < out.count, out[j].s - out[i].s <= reach { j += 1 }
            let hi = min(j, out.count - 1)
            for m in lo...hi {
                let dist = abs(out[m].s - out[i].s)
                let allowed = room + dist * 0.9
                if k > 0 { limR[m] = min(limR[m], allowed) } else { limL[m] = min(limL[m], allowed) }
            }
        }
        for i in out.indices {
            out[i].vergeLeft = min(vergeWidth, limL[i])
            out[i].vergeRight = min(vergeWidth, limR[i])
        }
        return out
    }

    // MARK: - Fields

    /// Exact nearest-centreline lookup at every near-grid cell centre within
    /// `reach` of the carriageway edge.
    struct NearField: Sendable {
        let col0: Int, row0: Int, cols: Int, rows: Int
        /// Unsigned distance to the centreline (infinity outside the reach).
        let dist: [Float]
        /// Signed lateral offset, positive to the right of travel.
        let lateral: [Float]
        /// Segment start index into `stations` and fraction along it.
        let segment: [Int32]
        let fraction: [Float]

        init(stations: [Station], raster: HeightRaster, reach: Double) {
            var minE = Double.infinity, maxE = -Double.infinity, minN = Double.infinity, maxN = -Double.infinity
            var maxHW = 0.0
            for st in stations {
                minE = min(minE, st.east); maxE = max(maxE, st.east)
                minN = min(minN, st.north); maxN = max(maxN, st.north)
                maxHW = max(maxHW, st.halfWidth)
            }
            let r = reach + maxHW + 1
            let c0 = max(0, Int(floor((minE - r - raster.originEast) / raster.cellM)))
            let c1 = min(raster.cols - 1, Int(ceil((maxE + r - raster.originEast) / raster.cellM)))
            let r0 = max(0, Int(floor((raster.originNorth - maxN - r) / raster.cellM)))
            let r1 = min(raster.rows - 1, Int(ceil((raster.originNorth - minN + r) / raster.cellM)))
            col0 = c0; row0 = r0; cols = max(c1 - c0 + 1, 1); rows = max(r1 - r0 + 1, 1)
            let count = cols * rows
            var dist = [Float](repeating: .infinity, count: count)
            var lat = [Float](repeating: 0, count: count)
            var seg = [Int32](repeating: -1, count: count)
            var frac = [Float](repeating: 0, count: count)
            let cell = raster.cellM, oE = raster.originEast, oN = raster.originNorth
            let colsL = cols, rowsL = rows, c0L = c0, r0L = r0
            dist.withUnsafeMutableBufferPointer { dP in
            lat.withUnsafeMutableBufferPointer { lP in
            seg.withUnsafeMutableBufferPointer { sP in
            frac.withUnsafeMutableBufferPointer { fP in
                for i in 0..<(stations.count - 1) {
                    if i % 64 == 0, Task.isCancelled { break }
                    let a = stations[i], b = stations[i + 1]
                    let ax = a.east, ay = a.north
                    let vx = b.east - ax, vy = b.north - ay
                    let len2 = max(vx * vx + vy * vy, 1e-9)
                    let isFirst = i == 0, isLast = i == stations.count - 2
                    let lo = min(ax, b.east) - r, hi = max(ax, b.east) + r
                    let loN = min(ay, b.north) - r, hiN = max(ay, b.north) + r
                    let ci0 = max(0, Int(floor((lo - oE) / cell - 0.5)) - c0L)
                    let ci1 = min(colsL - 1, Int(ceil((hi - oE) / cell - 0.5)) - c0L)
                    let ri0 = max(0, Int(floor((oN - hiN) / cell - 0.5)) - r0L)
                    let ri1 = min(rowsL - 1, Int(ceil((oN - loN) / cell - 0.5)) - r0L)
                    if ci0 > ci1 || ri0 > ri1 { continue }
                    let rr = Float(r * r)
                    for rr0 in ri0...ri1 {
                        let pn = oN - (Double(rr0 + r0L) + 0.5) * cell
                        for cc in ci0...ci1 {
                            let pe = oE + (Double(cc + c0L) + 0.5) * cell
                            let wx = pe - ax, wy = pn - ay
                            var t = (wx * vx + wy * vy) / len2
                            if (isFirst && t < 0) || (isLast && t > 1) { continue }
                            t = min(max(t, 0), 1)
                            let dx = wx - vx * t, dy = wy - vy * t
                            let d2 = Float(dx * dx + dy * dy)
                            if d2 > rr { continue }
                            let k = rr0 * colsL + cc
                            if d2 < dP[k] * dP[k] {
                                dP[k] = sqrtf(d2)
                                // Right of travel is (dirN, -dirE).
                                let cross = vx * wy - vy * wx
                                lP[k] = cross > 0 ? -sqrtf(d2) : sqrtf(d2)
                                sP[k] = Int32(i)
                                fP[k] = Float(t)
                            }
                        }
                    }
                }
            }}}}
            self.dist = dist; self.lateral = lat; self.segment = seg; self.fraction = frac
        }

        /// Lookup at near-grid cell (col, row), or nil when out of reach.
        @inline(__always)
        func lookup(col: Int, row: Int) -> (dist: Float, lateral: Float, segment: Int, fraction: Float)? {
            let c = col - col0, r = row - row0
            guard c >= 0, r >= 0, c < cols, r < rows else { return nil }
            let k = r * cols + c
            let s = segment[k]
            guard s >= 0 else { return nil }
            return (dist[k], lateral[k], Int(s), fraction[k])
        }
    }

    /// Approximate distance to the route (not its extensions) on a coarse
    /// grid over the near raster, with the nearest station per cell.
    struct CoarseField: Sendable {
        let originEast: Double, originNorth: Double, cell: Double
        let cols: Int, rows: Int
        let nearest: [Int32]
        let stationE: [Double], stationN: [Double], stationS: [Double]
        /// Queries also weigh the stations the eight neighbouring cells
        /// hold: where two legs of the road run 10-14 m apart (the
        /// Poggio's hairpins and summit loop) a 4 m cell's nearest station
        /// can be on the other leg from a point near its edge.
        let neighbours: Bool

        init(stations: [Station], raster: HeightRaster, cell: Double, neighbours: Bool = false) {
            self.cell = cell
            self.neighbours = neighbours
            originEast = raster.originEast - 200
            originNorth = raster.originNorth + 200
            cols = Int(ceil((raster.widthM + 400) / cell))
            rows = Int(ceil((raster.heightM + 400) / cell))
            let onRoute = stations.filter { $0.beyond == 0 }
            stationE = onRoute.map(\.east); stationN = onRoute.map(\.north); stationS = onRoute.map(\.s)
            var nearest = [Int32](repeating: -1, count: cols * rows)
            var best = [Double](repeating: .infinity, count: cols * rows)
            let oE = originEast, oN = originNorth, c = cell, nc = cols, nr = rows
            let sE = stationE, sN = stationN
            nearest.withUnsafeMutableBufferPointer { np in
            best.withUnsafeMutableBufferPointer { bp in
                for k in 0..<sE.count {
                    let ci = Int((sE[k] - oE) / c), ri = Int((oN - sN[k]) / c)
                    guard ci >= 0, ri >= 0, ci < nc, ri < nr else { continue }
                    let ce = oE + (Double(ci) + 0.5) * c, cn = oN - (Double(ri) + 0.5) * c
                    let d = (ce - sE[k]) * (ce - sE[k]) + (cn - sN[k]) * (cn - sN[k])
                    if d < bp[ri * nc + ci] { bp[ri * nc + ci] = d; np[ri * nc + ci] = Int32(k) }
                }
                @inline(__always) func relax(_ ri: Int, _ ci: Int, _ rj: Int, _ cj: Int) {
                    guard rj >= 0, cj >= 0, rj < nr, cj < nc else { return }
                    let s = np[rj * nc + cj]
                    guard s >= 0 else { return }
                    let ce = oE + (Double(ci) + 0.5) * c, cn = oN - (Double(ri) + 0.5) * c
                    let d = (ce - sE[Int(s)]) * (ce - sE[Int(s)]) + (cn - sN[Int(s)]) * (cn - sN[Int(s)])
                    if d < bp[ri * nc + ci] { bp[ri * nc + ci] = d; np[ri * nc + ci] = s }
                }
                for _ in 0..<2 {
                    if Task.isCancelled { break }
                    for ri in 0..<nr {
                        for ci in 0..<nc {
                            relax(ri, ci, ri, ci - 1); relax(ri, ci, ri - 1, ci - 1)
                            relax(ri, ci, ri - 1, ci); relax(ri, ci, ri - 1, ci + 1)
                        }
                        for ci in stride(from: nc - 1, through: 0, by: -1) { relax(ri, ci, ri, ci + 1) }
                    }
                    for ri in stride(from: nr - 1, through: 0, by: -1) {
                        for ci in stride(from: nc - 1, through: 0, by: -1) {
                            relax(ri, ci, ri, ci + 1); relax(ri, ci, ri + 1, ci + 1)
                            relax(ri, ci, ri + 1, ci); relax(ri, ci, ri + 1, ci - 1)
                        }
                        for ci in 0..<nc { relax(ri, ci, ri, ci - 1) }
                    }
                }
            }}
            self.nearest = nearest
        }

        /// Distance from a point to the route and the route distance `s` of
        /// the nearest station (refined over a few neighbours).
        func query(east: Double, north: Double) -> (dist: Double, s: Double) {
            let ci = min(max(Int((east - originEast) / cell), 0), cols - 1)
            let ri = min(max(Int((originNorth - north) / cell), 0), rows - 1)
            let k = Int(nearest[ri * cols + ci])
            guard k >= 0 else { return (.infinity, 0) }
            var bestD = Double.infinity, bestK = k
            for j in max(0, k - 6)...min(stationE.count - 1, k + 6) {
                let d = (east - stationE[j]) * (east - stationE[j]) + (north - stationN[j]) * (north - stationN[j])
                if d < bestD { bestD = d; bestK = j }
            }
            if neighbours {
                for dr in -1...1 {
                    for dc in -1...1 where dr != 0 || dc != 0 {
                        let r = ri + dr, c = ci + dc
                        guard r >= 0, c >= 0, r < rows, c < cols else { continue }
                        let k2 = Int(nearest[r * cols + c])
                        // Stations the first search already weighed.
                        guard k2 >= 0, abs(k2 - k) > 6 else { continue }
                        for j in max(0, k2 - 6)...min(stationE.count - 1, k2 + 6) {
                            let d = (east - stationE[j]) * (east - stationE[j]) + (north - stationN[j]) * (north - stationN[j])
                            if d < bestD { bestD = d; bestK = j }
                        }
                    }
                }
            }
            return (sqrt(bestD), stationS[bestK])
        }

        /// Smallest distance to the route over an axis-aligned rectangle
        /// (east0...east1, north0...north1), from the cells it covers.
        func minDistance(east0: Double, east1: Double, north0: Double, north1: Double) -> Double {
            let c0 = min(max(Int((east0 - originEast) / cell), 0), cols - 1)
            let c1 = min(max(Int((east1 - originEast) / cell), 0), cols - 1)
            let r0 = min(max(Int((originNorth - north1) / cell), 0), rows - 1)
            let r1 = min(max(Int((originNorth - north0) / cell), 0), rows - 1)
            var best = Double.infinity
            for r in stride(from: r0, through: r1, by: 1) {
                for c in stride(from: c0, through: c1, by: 1) {
                    let k = Int(nearest[r * cols + c])
                    guard k >= 0 else { continue }
                    // Distance from the station to the rectangle.
                    let dx = max(east0 - stationE[k], 0, stationE[k] - east1)
                    let dy = max(north0 - stationN[k], 0, stationN[k] - north1)
                    best = min(best, sqrt(dx * dx + dy * dy))
                }
            }
            return best
        }
    }
}

@inline(__always) func smoothstepD(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}
