import Foundation
import simd

/// Everything solid around the route that the camera must stay out of and
/// see past, as a height field: the road surface, the LiDAR terrain (the
/// sunken-lane banks), hedges, buildings and tree trunks.
///
/// It models what the world draws rather than the raw DTM: under the
/// carriageway the ground is the road surface, so the culvert dip on the
/// Rotelenberg (s ≈ 256) doesn't let the camera sink below the cobbles.
/// Built once from the course data and never mutated afterwards, so the
/// render thread can query it freely.
final class CameraClearance: @unchecked Sendable {
    /// Where a ground point sits relative to the road.
    struct RoadPoint {
        /// Distance along the route of the nearest centreline point. Below
        /// the start or past the finish when the point lies beyond the route.
        var s: Double
        /// Signed distance from the centreline, positive to the right.
        var lateral: Double
        /// Road-surface elevation at `s` (extrapolated beyond the ends).
        var elevation: Float
        var halfWidth: Float
    }

    /// What it takes to see the rider from a camera position.
    struct SightFix {
        /// Metres to lift the camera (applied at the camera, pivoting on the rider).
        var raise: Float
        /// Fraction of the rider-to-camera distance to keep (1 = no pull-in).
        var pull: Float
        var blocked: Bool
    }

    let route: CourseRoute
    private let near: HeightRaster
    private let far: HeightRaster?
    private let shrubs: DiscGrid
    private let trunks: DiscGrid
    private let crowns: CrownGrid
    private let buildings: BlockGrid

    /// Past the ends of the route the road is assumed to carry straight on
    /// for this far (the Meldenstraat continues behind the start, the
    /// plateau road beyond the finish).
    private static let endRunOutM = 25.0

    init(bundle: CourseBundle) {
        route = bundle.route
        near = bundle.terrainNear
        far = bundle.terrainFar
        let terrainNear = bundle.terrainNear, terrainFar = bundle.terrainFar
        func ground(_ e: Double, _ n: Double) -> Float {
            if terrainNear.contains(east: e, north: n) {
                let v = terrainNear.sample(east: e, north: n)
                if !v.isNaN { return v }
            }
            if let terrainFar, terrainFar.contains(east: e, north: n) {
                return terrainFar.sample(east: e, north: n)
            }
            return .nan
        }

        let scenery = bundle.scenery
        // Hedges and bank vegetation: solid to (most of) their height.
        var shrubDiscs: [DiscGrid.Disc] = []
        for s in scenery?.shrubs ?? [] where s.heightM > 0.3 {
            let g = ground(s.e, s.n)
            guard !g.isNaN else { continue }
            shrubDiscs.append(.init(e: s.e, n: s.n, radius: s.radiusM * 0.85, top: g + Float(s.heightM * 0.9)))
        }
        shrubs = DiscGrid(discs: shrubDiscs, cell: 4)

        // Tree trunks up to roughly where the crown starts; the crowns
        // themselves (the tunnel over the steepest part) are fine to be under.
        var trunkDiscs: [DiscGrid.Disc] = []
        for t in scenery?.trees ?? [] {
            let g = ground(t.e, t.n)
            guard !g.isNaN else { continue }
            let radius = 0.2 + 0.012 * t.heightM + 0.3
            trunkDiscs.append(.init(e: t.e, n: t.n, radius: radius, top: g + Float(max(2.5, t.heightM * 0.4))))
        }
        trunks = DiscGrid(discs: trunkDiscs, cell: 4)

        // Crowns, roughly as the world draws them: an ellipsoid round 58 % of
        // the tree's height, leaning out over a sunken lane as the world's
        // trees do. Fine to look through (the tunnel of trees), but a camera
        // parked inside one sees nothing but leaves.
        let art = CourseArt.make(bundle: bundle)
        let route = bundle.route
        var crownList: [CrownGrid.Crown] = []
        for t in scenery?.trees ?? [] where t.heightM > 1.5 {
            let g = ground(t.e, t.n)
            guard !g.isNaN else { continue }
            var e = t.e, n = t.n
            // Nearest route point: every 8th, then the neighbours of the best.
            var best = Double.infinity, bi = 0
            func consider(_ i: Int) {
                let d = (route.east[i] - e) * (route.east[i] - e) + (route.north[i] - n) * (route.north[i] - n)
                if d < best { best = d; bi = i }
            }
            for i in stride(from: 0, to: route.count, by: 8) { consider(i) }
            for i in max(0, bi - 8)...min(route.count - 1, bi + 8) { consider(i) }
            let dist = best.squareRoot()
            let sunk = art.sunkenWeight(route.s[bi])
            if sunk > 0.2, dist < 16, dist > 0.01 {
                let amount = sunk * min(0.55 * t.crownRadiusM, 5) * (1 - dist / 20)
                // Towards the road, by about the share of the lean at mid-crown.
                e += (route.east[bi] - e) / dist * amount * 0.4
                n += (route.north[bi] - n) / dist * amount * 0.4
            }
            crownList.append(.init(e: e, n: n, radius: max(t.crownRadiusM, 0.8),
                                   centreY: g + Float(0.58 * t.heightM), halfHeight: Float(0.42 * t.heightM)))
        }
        crowns = CrownGrid(crowns: crownList, cell: 6)

        var blocks: [BlockGrid.Block] = []
        for b in scenery?.buildings ?? [] where b.ring.count >= 3 {
            let ring = b.ring.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }
            guard ring.count >= 3 else { continue }
            let centroid = ring.reduce(SIMD2<Double>.zero, +) / Double(ring.count)
            let sampled = ground(centroid.x, centroid.y)
            let base = max(Float(b.groundElevM ?? -.infinity), sampled.isNaN ? -.infinity : sampled)
            guard base.isFinite else { continue }
            blocks.append(BlockGrid.Block(ring: ring, top: base + Float(b.heightM)))
        }
        buildings = BlockGrid(blocks: blocks, margin: 0.35, cell: 8)
    }

    // MARK: Route

    /// Pose on the road, continuing in a straight line past either end so a
    /// camera behind the start or ahead of the finish still has somewhere to be.
    func pose(at distance: Double, lateral: Double = 0) -> RoutePose {
        let start = route.s[0], end = route.length
        if distance < start {
            var p = route.pose(at: start, lateral: lateral)
            p.position += p.forward * Float(distance - start)
            return p
        }
        if distance > end {
            var p = route.pose(at: end, lateral: lateral)
            p.position += p.forward * Float(distance - end)
            return p
        }
        return route.pose(at: distance, lateral: lateral)
    }

    /// Nearest point on the centreline, searched within `window` metres of
    /// `hintS` so a route that later loops back near itself can't confuse it.
    func road(east e: Double, north n: Double, near hintS: Double, window: Double = 24) -> RoadPoint {
        let r = route
        let last = r.count - 2
        let lo = r.locate(hintS - window).i
        let hi = min(r.locate(hintS + window).i, last)
        var best = Double.infinity, bi = lo, bt = 0.0
        for i in lo...hi {
            let ax = r.east[i], ay = r.north[i]
            let dx = r.east[i + 1] - ax, dy = r.north[i + 1] - ay
            let len2 = dx * dx + dy * dy
            guard len2 > 1e-9 else { continue }
            var t = ((e - ax) * dx + (n - ay) * dy) / len2
            // The first segment runs on behind the start, the last past the finish.
            if i > 0 { t = max(t, 0) }
            if i < last { t = min(t, 1) }
            let px = ax + dx * t - e, py = ay + dy * t - n
            let d2 = px * px + py * py
            if d2 < best { best = d2; bi = i; bt = t }
        }
        let dx = r.east[bi + 1] - r.east[bi], dy = r.north[bi + 1] - r.north[bi]
        let len = max(sqrt(dx * dx + dy * dy), 1e-9)
        let lateral = ((e - r.east[bi]) * dy - (n - r.north[bi]) * dx) / len
        let s = r.s[bi] + (r.s[bi + 1] - r.s[bi]) * bt
        let elev = r.elev[bi] + (r.elev[bi + 1] - r.elev[bi]) * bt
        let tw = min(max(bt, 0), 1)
        let width = r.widthM[bi] + (r.widthM[bi + 1] - r.widthM[bi]) * tw
        return RoadPoint(s: s, lateral: lateral, elevation: Float(elev), halfWidth: Float(width / 2))
    }

    // MARK: Height field

    /// Bare terrain from the near raster, else the far one; `nan` off both.
    func terrain(east e: Double, north n: Double) -> Float {
        if near.contains(east: e, north: n) {
            let v = near.sample(east: e, north: n)
            if !v.isNaN { return v }
        }
        if let far, far.contains(east: e, north: n) {
            return far.sample(east: e, north: n)
        }
        return .nan
    }

    /// Top of the ground at a point: road surface on the carriageway,
    /// terrain (never below the road within 1.5 m of its edge), hedges.
    func groundTop(east e: Double, north n: Double, near hintS: Double) -> Float {
        let rp = road(east: e, north: n, near: hintS)
        let onRoadLine = rp.s > route.s[0] - Self.endRunOutM && rp.s < route.length + Self.endRunOutM
        let edge = abs(rp.lateral) - Double(rp.halfWidth)
        var top: Float
        if onRoadLine && edge <= 0.3 {
            top = rp.elevation
        } else {
            let t = terrain(east: e, north: n)
            top = t.isNaN ? rp.elevation : t
            if onRoadLine && edge < 1.5 { top = max(top, rp.elevation) }
        }
        return max(top, shrubs.top(east: e, north: n))
    }

    /// Top of anything built or grown on the ground: buildings, tree trunks.
    /// `-infinity` where there is nothing.
    func blockTop(east e: Double, north n: Double) -> Float {
        max(buildings.top(east: e, north: n), trunks.top(east: e, north: n))
    }

    func solidTop(east e: Double, north n: Double, near hintS: Double) -> Float {
        max(groundTop(east: e, north: n, near: hintS), blockTop(east: e, north: n))
    }

    @inline(__always)
    func solidTop(_ p: SIMD3<Float>, near hintS: Double) -> Float {
        let l = CourseSpace.local(p)
        return solidTop(east: l.east, north: l.north, near: hintS)
    }

    /// Highest ground under a small disc around `p` (centre plus four points
    /// on the rim), so the near plane can't clip into a bank face.
    func groundTop(disc p: SIMD3<Float>, radius: Float, near hintS: Double) -> Float {
        let l = CourseSpace.local(p)
        let r = Double(radius)
        var top = groundTop(east: l.east, north: l.north, near: hintS)
        for (de, dn) in [(r, 0.0), (-r, 0.0), (0.0, r), (0.0, -r)] {
            top = max(top, groundTop(east: l.east + de, north: l.north + dn, near: hintS))
        }
        return top
    }

    func solidTop(disc p: SIMD3<Float>, radius: Float, near hintS: Double) -> Float {
        let l = CourseSpace.local(p)
        let r = Double(radius)
        var top = groundTop(disc: p, radius: radius, near: hintS)
        for (de, dn) in [(0.0, 0.0), (r, 0.0), (-r, 0.0), (0.0, r), (0.0, -r)] {
            top = max(top, blockTop(east: l.east + de, north: l.north + dn))
        }
        return top
    }

    /// True when `p` is inside a building or trunk (with a small margin).
    func isInsideBlock(_ p: SIMD3<Float>) -> Bool {
        let l = CourseSpace.local(p)
        return blockTop(east: l.east, north: l.north) > p.y - 0.2
    }

    /// True when `p` is inside (or within `margin` of) a tree's crown.
    func isInFoliage(_ p: SIMD3<Float>, margin: Double = 0.4) -> Bool {
        let l = CourseSpace.local(p)
        return crowns.contains(east: l.east, north: l.north, y: p.y, margin: margin)
    }

    /// How far from the centreline (towards `side`: −1 left, +1 right) the
    /// ground stays roughly level with the road at distance `s`: the room a
    /// camera has beside the road before it meets a bank, wall or hedge.
    func freeLateral(at s: Double, side: Double, maxOffset: Double) -> Double {
        let centre = route.planar(at: min(max(s, route.s[0]), route.length))
        let dir = route.direction(at: s)
        let right = SIMD2(dir.y, -dir.x)
        let roadElev = Float(route.elevation(at: s))
        var free = 0.0
        var offset = 0.25
        while offset <= maxOffset {
            let p = centre + right * (side * offset)
            if solidTop(east: p.x, north: p.y, near: s) > roadElev + 0.5 { break }
            free = offset
            offset += 0.25
        }
        return free
    }

    // MARK: Line of sight

    /// How much to raise and/or pull in the camera at `eye` so that the line
    /// to `focus` (the rider) clears the ground, and the camera itself sits
    /// at least `eyeClearance` above it. Raising is preferred up to
    /// `maxRaise`; beyond that the camera moves in along the line until it is
    /// in front of the obstacle.
    func fixSightLine(
        focus: SIMD3<Float>, eye: SIMD3<Float>,
        focusS: Double, eyeS: Double,
        maxRaise: Float, eyeClearance: Float = 0.45, lineMargin: Float = 0.15
    ) -> SightFix {
        let d = eye - focus
        let len = simd_length(d)
        guard len > 0.5 else { return SightFix(raise: 0, pull: 1, blocked: false) }
        let n = min(max(Int(len / 0.4), 6), 32)
        var tops = [Float](repeating: 0, count: n + 1)
        var need: Float = 0
        var nearBlocked = false
        for k in 1...n {
            let u = Float(k) / Float(n)
            let p = focus + d * u
            let hint = focusS + (eyeS - focusS) * Double(u)
            let top = k == n ? solidTop(disc: p, radius: 0.3, near: hint) : solidTop(p, near: hint)
            tops[k] = top
            let deficit = top + (k == n ? eyeClearance : lineMargin) - p.y
            guard deficit > 0 else { continue }
            if u * len < 1.0 { nearBlocked = true } else { need = max(need, deficit / u) }
        }
        if !nearBlocked && need <= maxRaise {
            return SightFix(raise: need, pull: 1, blocked: need > 0)
        }
        // Too much to climb over: lift part of the way, then come in until
        // the camera is on the rider's side of the obstacle.
        let raise = nearBlocked ? 0 : maxRaise * 0.6
        var uBlock: Float = 1
        for k in 1...n {
            let u = Float(k) / Float(n)
            if tops[k] + lineMargin > focus.y + (d.y + raise) * u {
                uBlock = u
                break
            }
        }
        let minPull = min(1, 0.9 / len)
        let pull = max(minPull, min(1, uBlock - 1.5 / Float(n)))
        return SightFix(raise: raise, pull: pull, blocked: true)
    }
}

// MARK: - Spatial grids

/// Circles with a solid top height, bucketed on a uniform grid.
private struct DiscGrid {
    struct Disc {
        let e: Double
        let n: Double
        let radius: Double
        let top: Float
    }

    private let discs: [Disc]
    private let grid: CellIndex

    init(discs: [Disc], cell: Double) {
        self.discs = discs
        grid = CellIndex(boxes: discs.map { ($0.e - $0.radius, $0.n - $0.radius, $0.e + $0.radius, $0.n + $0.radius) }, cell: cell)
    }

    func top(east e: Double, north n: Double) -> Float {
        var top = -Float.infinity
        grid.forEach(east: e, north: n) { i in
            let d = discs[i]
            let de = e - d.e, dn = n - d.n
            if de * de + dn * dn <= d.radius * d.radius { top = max(top, d.top) }
        }
        return top
    }
}

/// Tree crowns as upright ellipsoids, bucketed on a uniform grid.
private struct CrownGrid {
    struct Crown {
        let e: Double
        let n: Double
        let radius: Double
        let centreY: Float
        let halfHeight: Float
    }

    private let crowns: [Crown]
    private let grid: CellIndex
    /// Largest margin a query may ask for (the grid boxes include it).
    private static let maxMargin = 1.0

    init(crowns: [Crown], cell: Double) {
        self.crowns = crowns
        let m = Self.maxMargin
        grid = CellIndex(boxes: crowns.map { ($0.e - $0.radius - m, $0.n - $0.radius - m, $0.e + $0.radius + m, $0.n + $0.radius + m) },
                         cell: cell)
    }

    func contains(east e: Double, north n: Double, y: Float, margin: Double) -> Bool {
        let m = min(max(margin, 0), Self.maxMargin)
        var inside = false
        grid.forEach(east: e, north: n) { i in
            guard !inside else { return }
            let c = crowns[i]
            let r = c.radius + m, h = Double(c.halfHeight) + m
            let de = (e - c.e) / r, dn = (n - c.n) / r, dy = Double(y - c.centreY) / h
            if de * de + dn * dn + dy * dy <= 1 { inside = true }
        }
        return inside
    }
}

/// Building footprints as solid prisms up to their ridge height.
private struct BlockGrid {
    struct Block {
        let ring: [SIMD2<Double>]
        let top: Float
        let minE: Double, maxE: Double, minN: Double, maxN: Double

        init(ring: [SIMD2<Double>], top: Float) {
            self.ring = ring
            self.top = top
            minE = ring.map(\.x).min() ?? 0
            maxE = ring.map(\.x).max() ?? 0
            minN = ring.map(\.y).min() ?? 0
            maxN = ring.map(\.y).max() ?? 0
        }
    }

    private let blocks: [Block]
    private let margin: Double
    private let grid: CellIndex

    init(blocks: [Block], margin: Double, cell: Double) {
        self.blocks = blocks
        self.margin = margin
        grid = CellIndex(boxes: blocks.map { ($0.minE - margin, $0.minN - margin, $0.maxE + margin, $0.maxN + margin) }, cell: cell)
    }

    func top(east e: Double, north n: Double) -> Float {
        var top = -Float.infinity
        let p = SIMD2(e, n)
        grid.forEach(east: e, north: n) { i in
            let b = blocks[i]
            guard b.top > top,
                  e >= b.minE - margin, e <= b.maxE + margin,
                  n >= b.minN - margin, n <= b.maxN + margin else { return }
            if Self.contains(b.ring, p) || Self.distanceToEdges(b.ring, p) < margin { top = b.top }
        }
        return top
    }

    private static func contains(_ ring: [SIMD2<Double>], _ p: SIMD2<Double>) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    private static func distanceToEdges(_ ring: [SIMD2<Double>], _ p: SIMD2<Double>) -> Double {
        var best = Double.infinity
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[j], b = ring[i]
            let ab = b - a
            let len2 = simd_length_squared(ab)
            let t = len2 > 0 ? min(max(simd_dot(p - a, ab) / len2, 0), 1) : 0
            best = min(best, simd_distance(p, a + ab * t))
            j = i
        }
        return best
    }
}

/// Compressed uniform grid: for each cell, the indices of the boxes that
/// overlap it.
private struct CellIndex {
    private let minE: Double
    private let minN: Double
    private let cell: Double
    private let cols: Int
    private let rows: Int
    private let starts: [Int32]
    private let items: [Int32]

    init(boxes: [(minE: Double, minN: Double, maxE: Double, maxN: Double)], cell: Double) {
        self.cell = cell
        guard !boxes.isEmpty else {
            minE = 0; minN = 0; cols = 0; rows = 0; starts = [0]; items = []
            return
        }
        let e0 = boxes.map(\.minE).min()!, n0 = boxes.map(\.minN).min()!
        let e1 = boxes.map(\.maxE).max()!, n1 = boxes.map(\.maxN).max()!
        minE = e0
        minN = n0
        let c = max(1, Int(((e1 - e0) / cell).rounded(.up)))
        let r = max(1, Int(((n1 - n0) / cell).rounded(.up)))
        cols = c
        rows = r
        func range(_ box: (minE: Double, minN: Double, maxE: Double, maxN: Double)) -> (ClosedRange<Int>, ClosedRange<Int>) {
            let c0 = min(max(Int((box.minE - e0) / cell), 0), c - 1)
            let c1 = min(max(Int((box.maxE - e0) / cell), 0), c - 1)
            let r0 = min(max(Int((box.minN - n0) / cell), 0), r - 1)
            let r1 = min(max(Int((box.maxN - n0) / cell), 0), r - 1)
            return (c0...c1, r0...r1)
        }
        var counts = [Int32](repeating: 0, count: c * r + 1)
        for box in boxes {
            let (cs, rs) = range(box)
            for rr in rs { for cc in cs { counts[rr * c + cc + 1] += 1 } }
        }
        for i in 1..<counts.count { counts[i] += counts[i - 1] }
        var fill = counts
        var out = [Int32](repeating: 0, count: Int(counts[c * r]))
        for (index, box) in boxes.enumerated() {
            let (cs, rs) = range(box)
            for rr in rs {
                for cc in cs {
                    let slot = rr * c + cc
                    out[Int(fill[slot])] = Int32(index)
                    fill[slot] += 1
                }
            }
        }
        starts = counts
        items = out
    }

    @inline(__always)
    func forEach(east e: Double, north n: Double, _ body: (Int) -> Void) {
        guard cols > 0 else { return }
        let c = Int(floor((e - minE) / cell)), r = Int(floor((n - minN) / cell))
        guard c >= 0, c < cols, r >= 0, r < rows else { return }
        let slot = r * cols + c
        for k in Int(starts[slot])..<Int(starts[slot + 1]) { body(Int(items[k])) }
    }
}
