import Foundation
import simd

/// The sea, for a course on a coast (`CourseFile.sea`): a flat surface at
/// sea level from the shore out to past the horizon. The terrain rasters
/// hold the sea a metre under its level, and `TerrainBuilder` drops those
/// cells, so the sea shows wherever the land is lower than it and the
/// coastline is where the terrain's slope crosses it.
///
/// It is built from the finest raster that covers each place: the far grid
/// (10 m), then the horizon ring (`terrain.horizon`), then a frame of 2 km
/// cells out to `reachM`, kept where the ring's edge beyond it is sea. Open
/// water is drawn in blocks; near the coast every sea cell, and the land
/// cells within two of it, get a quad of their own, so the sea runs a
/// little under the shore and never stops short of it. Blocks overlap
/// their neighbours by a metre: the surface is one plane with one shader,
/// so the overlap can't show, and there are no T-junction cracks.
///
/// Vertices: world position (the node stays at the origin, which the
/// shader's earth curve relies on), normal up, texcoord 0 the world (x, z),
/// texcoord 1 x the distance to the nearest land, metres (the shallows'
/// turquoise and the wash at the rocks; `WorldShaders+Sea`).
enum SeaBuilder {
    /// Out to here from the course: from 160 m up the horizon is 49 km away
    /// (refraction included), so the sea ends behind the earth's curve.
    static let reachM: Double = 62_000
    /// Shore distance given to open water beyond the rasters.
    static let openSeaM: Float = 5000

    /// The course's sea level (`CourseFile.sea`), or nil inland.
    static func level(bundle: CourseBundle) -> Double? {
        #if DEBUG
        // -courseSeaLevel 25: floods any course to that level, to judge the
        // sea on a familiar road (the Paterberg's Scheldt valley).
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-courseSeaLevel"), i + 1 < args.count, let v = Double(args[i + 1]) { return v }
        #endif
        return bundle.course.sea?.levelM
    }

    static func build(corridor: RoadCorridor, levelM: Double, horizon: HeightRaster?) -> MeshBuffer {
        var mesh = MeshBuffer()
        let level = Float(levelM)
        let near = corridor.terrain.near
        let inner = corridor.terrain.far ?? near
        addRaster(inner, level: level, skipInside: nil, finer: corridor.terrain.far == nil ? nil : near, into: &mesh)
        var outerEdge = inner
        var outerSea = seaMask(inner, level: level, coarse: false)
        if let horizon {
            let mask = seaMask(horizon, level: level, coarse: true)
            addRaster(horizon, level: level, skipInside: inner, finer: nil, mask: mask, into: &mesh)
            outerEdge = horizon
            outerSea = mask
        }
        if Task.isCancelled { return mesh }
        addFrame(around: outerEdge, sea: outerSea, level: level, centre: corridor, into: &mesh)
        return mesh
    }

    // MARK: - A raster's sea

    /// A raster cell is sea when it lies half a metre or more under the
    /// sea's level (the pipeline writes level - 1 m there) or holds no data.
    @inline(__always)
    static func isSea(_ v: Float, level: Float) -> Bool { v.isNaN || v <= level - 0.5 }

    /// Which cells of `r` are sea. On the near and far grids, the cells
    /// `isSea` says. The horizon raster (`coarse`) is block-averaged from a
    /// national model whose sea is not coded the same way all over (the
    /// Poggio's holds the level itself from 10 km out) and whose gaps in
    /// the survey, across the French border, are written as sea too. There
    /// a cell at or under the level is sea when it belongs to the open sea,
    /// the largest body of such cells, or to a body of under 64 cells apart
    /// from it (a harbour basin behind its mole); a larger body apart from
    /// the open sea is land the survey missed, 20 km into the mountains.
    static func seaMask(_ r: HeightRaster, level: Float, coarse: Bool) -> [Bool] {
        let n = r.cols * r.rows
        guard coarse else { return r.values.map { isSea($0, level: level) } }
        let wet = r.values.map { $0.isNaN || $0 <= level + 0.05 }
        // Bodies of wet cells, four-connected.
        var body = [Int32](repeating: -1, count: n)
        var sizes: [Int] = []
        var stack: [Int] = []
        for k0 in 0..<n where wet[k0] && body[k0] < 0 {
            let id = Int32(sizes.count)
            var size = 0
            body[k0] = id
            stack.append(k0)
            while let k = stack.popLast() {
                size += 1
                let i = k % r.cols, j = k / r.cols
                for (di, dj) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let a = i + di, b = j + dj
                    guard a >= 0, a < r.cols, b >= 0, b < r.rows else { continue }
                    let kk = b * r.cols + a
                    if wet[kk], body[kk] < 0 { body[kk] = id; stack.append(kk) }
                }
            }
            sizes.append(size)
        }
        guard let open = sizes.indices.max(by: { sizes[$0] < sizes[$1] }) else { return wet }
        return (0..<n).map { k in body[k] >= 0 && (Int(body[k]) == open || sizes[Int(body[k])] < 64) }
    }

    /// The sea cells of `r` (and the land within two cells of them), less
    /// the cells wholly inside `skipInside`'s footprint. A cell that holds
    /// any of `finer`'s sea is sea too, so where the near grid's shore lies
    /// seaward of the coarse grid's the water still reaches it. `mask`, when
    /// given, is `seaMask(r)` already worked out.
    static func addRaster(_ r: HeightRaster, level: Float, skipInside: HeightRaster?, finer: HeightRaster?,
                          mask: [Bool]? = nil, into mesh: inout MeshBuffer) {
        let cols = r.cols, rows = r.rows
        var sea = mask ?? seaMask(r, level: level, coarse: false)
        if let f = finer {
            for fj in 0..<f.rows {
                let n = f.originNorth - (Double(fj) + 0.5) * f.cellM
                let j = Int(((r.originNorth - n) / r.cellM).rounded(.down))
                guard j >= 0, j < rows else { continue }
                for fi in 0..<f.cols where isSea(f.values[fj * f.cols + fi], level: level) {
                    let e = f.originEast + (Double(fi) + 0.5) * f.cellM
                    let i = Int(((e - r.originEast) / r.cellM).rounded(.down))
                    if i >= 0, i < cols { sea[j * cols + i] = true }
                }
            }
        }
        guard sea.contains(true) else { return }
        // Cells to draw: the sea and two cells of shore round it.
        var draw = sea
        for _ in 0..<2 {
            var next = draw
            for j in 0..<rows {
                for i in 0..<cols where !draw[j * cols + i] {
                    if (i > 0 && draw[j * cols + i - 1]) || (i < cols - 1 && draw[j * cols + i + 1])
                        || (j > 0 && draw[(j - 1) * cols + i]) || (j < rows - 1 && draw[(j + 1) * cols + i]) {
                        next[j * cols + i] = true
                    }
                }
            }
            draw = next
        }
        let shore = shoreDistance(sea: sea, cols: cols, rows: rows, cellM: Float(r.cellM))
        let cell = Float(r.cellM)
        let x0 = Float(r.originEast), z0 = Float(-r.originNorth)
        func inside(_ i: Int, _ j: Int) -> Bool {
            guard let s = skipInside else { return false }
            let e0 = r.originEast + Double(i) * r.cellM, n1 = r.originNorth - Double(j) * r.cellM
            return e0 >= s.minEast && e0 + r.cellM <= s.maxEast && n1 <= s.maxNorth && n1 - r.cellM >= s.minNorth
        }
        // Corner (i, j) of the cell lattice: its shore distance.
        func corner(_ i: Int, _ j: Int) -> Float { shore[j * (cols + 1) + i] }
        let B = 8
        for bj in stride(from: 0, to: rows, by: B) {
            for bi in stride(from: 0, to: cols, by: B) {
                if Task.isCancelled { return }
                let i1 = min(bi + B, cols), j1 = min(bj + B, rows)
                var all = true, any = false
                for j in bj..<j1 {
                    for i in bi..<i1 {
                        let k = j * cols + i
                        if !draw[k] || inside(i, j) { all = false } else { any = true }
                        // A block of open water: no land in it or beside it.
                        if !sea[k] { all = false }
                    }
                }
                guard any else { continue }
                if all {
                    let pad: Float = 1
                    quad(&mesh, x0 + Float(bi) * cell - pad, z0 + Float(bj) * cell - pad,
                         x0 + Float(i1) * cell + pad, z0 + Float(j1) * cell + pad, y: level,
                         shore: (corner(bi, bj), corner(i1, bj), corner(i1, j1), corner(bi, j1)))
                    continue
                }
                for j in bj..<j1 {
                    for i in bi..<i1 where draw[j * cols + i] && !inside(i, j) {
                        quad(&mesh, x0 + Float(i) * cell, z0 + Float(j) * cell,
                             x0 + Float(i + 1) * cell, z0 + Float(j + 1) * cell, y: level,
                             shore: (corner(i, j), corner(i + 1, j), corner(i + 1, j + 1), corner(i, j + 1)))
                    }
                }
            }
        }
    }

    /// Metres from each corner of the cell lattice ((cols + 1) x (rows + 1))
    /// to the nearest land: 0 on a corner any land cell touches, and a
    /// chamfer distance (3-4 weights, within 8 % of the straight line)
    /// beyond. A raster with no land at all is open sea throughout.
    static func shoreDistance(sea: [Bool], cols: Int, rows: Int, cellM: Float) -> [Float] {
        let w = cols + 1, h = rows + 1
        let far = Float.greatestFiniteMagnitude / 4
        var d = [Float](repeating: far, count: w * h)
        var anyLand = false
        for j in 0..<rows {
            for i in 0..<cols where !sea[j * cols + i] {
                anyLand = true
                d[j * w + i] = 0; d[j * w + i + 1] = 0
                d[(j + 1) * w + i] = 0; d[(j + 1) * w + i + 1] = 0
            }
        }
        guard anyLand else { return [Float](repeating: openSeaM, count: w * h) }
        let a = cellM, b = cellM * 4 / 3
        for j in 0..<h {
            for i in 0..<w {
                var v = d[j * w + i]
                if i > 0 { v = min(v, d[j * w + i - 1] + a) }
                if j > 0 {
                    v = min(v, d[(j - 1) * w + i] + a)
                    if i > 0 { v = min(v, d[(j - 1) * w + i - 1] + b) }
                    if i < w - 1 { v = min(v, d[(j - 1) * w + i + 1] + b) }
                }
                d[j * w + i] = v
            }
        }
        for j in stride(from: h - 1, through: 0, by: -1) {
            for i in stride(from: w - 1, through: 0, by: -1) {
                var v = d[j * w + i]
                if i < w - 1 { v = min(v, d[j * w + i + 1] + a) }
                if j < h - 1 {
                    v = min(v, d[(j + 1) * w + i] + a)
                    if i < w - 1 { v = min(v, d[(j + 1) * w + i + 1] + b) }
                    if i > 0 { v = min(v, d[(j + 1) * w + i - 1] + b) }
                }
                d[j * w + i] = min(v, openSeaM)
            }
        }
        return d
    }

    // MARK: - Beyond the rasters

    /// 2 km cells from `r`'s edge out to `reachM` round the course, kept
    /// where the edge of `r` straight towards the course is mostly sea
    /// (`sea`, its `seaMask`): the open sea to the south and the coast
    /// running on east and west.
    static func addFrame(around r: HeightRaster, sea: [Bool], level: Float, centre corridor: RoadCorridor,
                         into mesh: inout MeshBuffer) {
        let mid = corridor.stations[corridor.stations.count / 2]
        let step = 2000.0
        func breaks(_ lo: Double, _ hi: Double, _ c: Double) -> [Double] {
            var out: [Double] = []
            var x = lo
            while x > c - reachM { out.insert(x, at: 0); x -= step }
            out.insert(x, at: 0)
            let inner = max(1, Int(((hi - lo) / step).rounded(.up)))
            for k in 1..<inner { out.append(lo + (hi - lo) * Double(k) / Double(inner)) }
            x = hi
            while x < c + reachM { out.append(x); x += step }
            out.append(x)
            return out
        }
        let xs = breaks(r.minEast, r.maxEast, mid.east)
        let ns = breaks(r.minNorth, r.maxNorth, mid.north)
        let cx = (r.minEast + r.maxEast) / 2, cn = (r.minNorth + r.maxNorth) / 2
        for a in 0..<(xs.count - 1) {
            for b in 0..<(ns.count - 1) {
                let e0 = xs[a], e1 = xs[a + 1], n0 = ns[b], n1 = ns[b + 1]
                let me = (e0 + e1) / 2, mn = (n0 + n1) / 2
                if me > r.minEast, me < r.maxEast, mn > r.minNorth, mn < r.maxNorth { continue }
                if hypot(me - mid.east, mn - mid.north) > reachM + step { continue }
                guard edgeIsSea(r, level: level, east: me, north: mn, cx: cx, cn: cn, sea: sea) else { continue }
                quad(&mesh, Float(e0), Float(-n1), Float(e1), Float(-n0), y: level,
                     shore: (openSeaM, openSeaM, openSeaM, openSeaM))
            }
        }
    }

    /// Whether `r`'s border, where the line from (east, north) to the
    /// raster's centre crosses it, is mostly sea over a kilometre of it
    /// (`sea`: `r`'s `seaMask`, or nil for `isSea` cell by cell).
    static func edgeIsSea(_ r: HeightRaster, level: Float, east: Double, north: Double, cx: Double, cn: Double,
                          sea: [Bool]? = nil) -> Bool {
        // Step from the point towards the centre until inside the raster.
        let dx = cx - east, dn = cn - north
        var t = 0.0
        let tx = dx > 0 ? (r.minEast - east) / dx : dx < 0 ? (r.maxEast - east) / dx : 0
        let tn = dn > 0 ? (r.minNorth - north) / dn : dn < 0 ? (r.maxNorth - north) / dn : 0
        t = min(max(max(tx, tn), 0), 1)
        let e = east + dx * t, n = north + dn * t
        let ci = Int(((e - r.originEast) / r.cellM).rounded(.down)), cj = Int(((r.originNorth - n) / r.cellM).rounded(.down))
        let reach = max(1, Int(500 / r.cellM)), by = max(1, reach / 10)
        var seaN = 0, all = 0
        for j in stride(from: max(cj - reach, 0), through: min(cj + reach, r.rows - 1), by: by) {
            for i in stride(from: max(ci - reach, 0), through: min(ci + reach, r.cols - 1), by: by) {
                all += 1
                let k = j * r.cols + i
                if sea.map({ $0[k] }) ?? isSea(r.values[k], level: level) { seaN += 1 }
            }
        }
        return all > 0 && seaN * 2 > all
    }

    // MARK: - Mesh

    /// A level quad from (xa, za) to (xb, zb), facing up, with the shore
    /// distance at its corners in the order (xa, za), (xb, za), (xb, zb), (xa, zb).
    static func quad(_ mesh: inout MeshBuffer, _ xa: Float, _ za: Float, _ xb: Float, _ zb: Float, y: Float,
                     shore: (Float, Float, Float, Float)) {
        let a = mesh.vertex(xa, y, za, 0, 1, 0, xa, za); mesh.texcoord2(shore.0, 0)
        let b = mesh.vertex(xb, y, za, 0, 1, 0, xb, za); mesh.texcoord2(shore.1, 0)
        let c = mesh.vertex(xb, y, zb, 0, 1, 0, xb, zb); mesh.texcoord2(shore.2, 0)
        let d = mesh.vertex(xa, y, zb, 0, 1, 0, xa, zb); mesh.texcoord2(shore.3, 0)
        // Counter-clockwise seen from above (+y): z grows south.
        mesh.tri(a, d, c)
        mesh.tri(a, c, b)
    }
}
