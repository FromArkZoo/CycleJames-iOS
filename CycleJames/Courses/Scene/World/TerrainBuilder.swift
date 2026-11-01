import SceneKit
import simd

/// Height-field meshes for the near (1 m LiDAR) and far (10 m) grids.
///
/// Both grids are cut into square blocks on their own lattice; each block
/// picks a vertex spacing from its distance to the route (or, for the far
/// grid, to the near grid). Where a fine block meets a coarser one, the fine
/// block's edge vertices are put on the coarse edge, so there are no cracks.
/// Blocks are merged into chunks for culling, and near chunks carry a
/// lighter level of detail for when the camera is far away.
///
/// Under the road the near grid is pushed well below the surface: the road
/// and its verge are their own road-aligned meshes (`RoadBuilder`), and the
/// grid only reappears where the verge mesh ends, crossing it at an angle.
///
/// On a coast (`seaLevel`) the rasters hold the sea a metre under its
/// level; cells wholly under it are left out, so the sea (`SeaBuilder`)
/// shows there and the shore is where the land's slope meets it. Beyond
/// the far grid a coarse horizon ring (`buildHorizon`) carries the land out
/// to the skyline.
///
/// A cancelled task gets back what was built so far, at the next chunk.
enum TerrainBuilder {
    struct Chunk {
        let mesh: MeshBuffer
        let lod: MeshBuffer?
        let centre: SIMD3<Float>
        let nearRoute: Bool
    }

    // MARK: - Generic lattice

    /// A rectangular lattice of height samples with a world mapping.
    struct Lattice {
        let nx: Int, nz: Int
        /// World x of column i and z of row j.
        let x0: Float, z0: Float, step: Float
        let blockSize: Int
        var blocksX: Int { (nx - 2) / blockSize + 1 }
        var blocksZ: Int { (nz - 2) / blockSize + 1 }
        func x(_ i: Int) -> Float { x0 + Float(i) * step }
        func z(_ j: Int) -> Float { z0 + Float(j) * step }
    }

    /// Vertex indices of a block along one axis, `sp` apart, always ending
    /// on the block's last lattice line.
    @inline(__always)
    static func axisPoints(start: Int, end: Int, sp: Int) -> [Int] {
        var out: [Int] = []
        out.reserveCapacity((end - start) / sp + 2)
        var i = start
        while i < end { out.append(i); i += sp }
        out.append(end)
        return out
    }

    /// Meshes one block into `mesh`.
    ///
    /// - heights: final vertex heights (pushed under the road) and whether
    ///   the vertex lies wholly under the road meshes.
    /// - base: unpushed heights for normals.
    static func meshBlock(
        into mesh: inout MeshBuffer,
        lattice L: Lattice, bx: Int, bz: Int,
        spacing: (Int, Int) -> Int,
        heightAt: (Int, Int) -> (h: Float, hidden: Bool),
        baseAt: (Int, Int) -> Float,
        dropHidden: Bool,
        skirt: (west: Bool, east: Bool, north: Bool, south: Bool),
        skirtDepth: Float,
        minSpacing: Int = 1
    ) {
        let B = L.blockSize
        let sp = max(spacing(bx, bz), minSpacing)
        let i0 = bx * B, i1 = min((bx + 1) * B, L.nx - 1)
        let j0 = bz * B, j1 = min((bz + 1) * B, L.nz - 1)
        guard i1 > i0, j1 > j0 else { return }
        let xs = axisPoints(start: i0, end: i1, sp: sp)
        let zs = axisPoints(start: j0, end: j1, sp: sp)
        let spW = bx > 0 ? max(spacing(bx - 1, bz), minSpacing) : sp
        let spE = bx < L.blocksX - 1 ? max(spacing(bx + 1, bz), minSpacing) : sp
        let spN = bz > 0 ? max(spacing(bx, bz - 1), minSpacing) : sp
        let spS = bz < L.blocksZ - 1 ? max(spacing(bx, bz + 1), minSpacing) : sp
        let w = xs.count, h = zs.count

        var hs = [Float](repeating: 0, count: w * h)
        var hidden = [Bool](repeating: false, count: w * h)
        for (b, j) in zs.enumerated() {
            for (a, i) in xs.enumerated() {
                let v = heightAt(i, j)
                hs[b * w + a] = v.h
                hidden[b * w + a] = v.hidden
            }
        }
        // Conform edges to coarser neighbours by interpolating along the
        // neighbour's own vertex positions.
        func conform(_ neighbourSp: Int, alongX: Bool, fixed: Int, row: Int) {
            guard neighbourSp > sp else { return }
            let start = alongX ? i0 : j0, end = alongX ? i1 : j1
            let pts = axisPoints(start: start, end: end, sp: neighbourSp)
            let own = alongX ? xs : zs
            var k = 0
            for (idx, p) in own.enumerated() {
                while k + 1 < pts.count, pts[k + 1] <= p { k += 1 }
                if pts[k] == p { continue }
                let a = pts[k], b = pts[min(k + 1, pts.count - 1)]
                let ha = alongX ? heightAt(a, fixed).h : heightAt(fixed, a).h
                let hb = alongX ? heightAt(b, fixed).h : heightAt(fixed, b).h
                let t = Float(p - a) / Float(max(b - a, 1))
                let vi = alongX ? (row * w + idx) : (idx * w + row)
                hs[vi] = ha + (hb - ha) * t
            }
        }
        conform(spN, alongX: true, fixed: j0, row: 0)
        conform(spS, alongX: true, fixed: j1, row: h - 1)
        conform(spW, alongX: false, fixed: i0, row: 0)
        conform(spE, alongX: false, fixed: i1, row: w - 1)

        // Normals from unpushed heights; the difference step is the coarsest
        // spacing touching the vertex so shared edge vertices agree.
        let base = UInt32(mesh.vertexCount)
        mesh.reserve(vertices: w * h, indices: (w - 1) * (h - 1) * 6)
        for (b, j) in zs.enumerated() {
            for (a, i) in xs.enumerated() {
                var k = sp
                if a == 0 { k = max(k, spW) }
                if a == w - 1 { k = max(k, spE) }
                if b == 0 { k = max(k, spN) }
                if b == h - 1 { k = max(k, spS) }
                let hl = baseAt(max(i - k, 0), j), hr = baseAt(min(i + k, L.nx - 1), j)
                let hu = baseAt(i, max(j - k, 0)), hd = baseAt(i, min(j + k, L.nz - 1))
                let dx = (hr - hl) / (Float(min(i + k, L.nx - 1) - max(i - k, 0)) * L.step)
                let dz = (hd - hu) / (Float(min(j + k, L.nz - 1) - max(j - k, 0)) * L.step)
                var nx = -dx, ny: Float = 1, nz = -dz
                let l = sqrtf(nx * nx + ny * ny + nz * nz)
                nx /= l; ny /= l; nz /= l
                let x = L.x(i), z = L.z(j)
                mesh.vertex(x, hs[b * w + a], z, nx, ny, nz, x, z)
            }
        }
        for b in 0..<(h - 1) {
            for a in 0..<(w - 1) {
                let k00 = b * w + a, k10 = k00 + 1, k01 = k00 + w, k11 = k01 + 1
                if dropHidden, hidden[k00], hidden[k10], hidden[k01], hidden[k11] { continue }
                let v00 = base + UInt32(k00), v10 = base + UInt32(k10)
                let v01 = base + UInt32(k01), v11 = base + UInt32(k11)
                // Split along the diagonal with the smaller height change.
                if abs(hs[k00] - hs[k11]) <= abs(hs[k10] - hs[k01]) {
                    mesh.tri(v00, v01, v11); mesh.tri(v00, v11, v10)
                } else {
                    mesh.tri(v00, v01, v10); mesh.tri(v10, v01, v11)
                }
            }
        }

        // Skirts hang straight down from chosen block edges.
        func skirtEdge(_ idx: [Int]) {
            guard idx.count > 1 else { return }
            let first = UInt32(mesh.vertexCount)
            for k in idx {
                let p = Int(base) + k
                let px = mesh.positions[3 * p], py = mesh.positions[3 * p + 1], pz = mesh.positions[3 * p + 2]
                let nx = mesh.normals[3 * p], ny = mesh.normals[3 * p + 1], nz = mesh.normals[3 * p + 2]
                mesh.vertex(px, py - skirtDepth, pz, nx, ny, nz, px, pz)
            }
            for k in 0..<(idx.count - 1) {
                let top0 = base + UInt32(idx[k]), top1 = base + UInt32(idx[k + 1])
                let bot0 = first + UInt32(k), bot1 = first + UInt32(k + 1)
                // Double-sided so the skirt hides gaps from either side.
                mesh.tri(top0, bot0, top1); mesh.tri(top1, bot0, bot1)
                mesh.tri(top0, top1, bot0); mesh.tri(top1, bot1, bot0)
            }
        }
        if skirt.north { skirtEdge(Array(0..<w)) }
        if skirt.south { skirtEdge(Array(((h - 1) * w)..<(h * w))) }
        if skirt.west { skirtEdge((0..<h).map { $0 * w }) }
        if skirt.east { skirtEdge((0..<h).map { $0 * w + w - 1 }) }
    }

    // MARK: - Near grid

    static func buildNear(corridor: RoadCorridor, config: WorldConfig, seaLevel: Double? = nil) -> [Chunk] {
        let seaFloor = seaLevel.map { Float($0) - 0.5 } ?? -.infinity
        let r = corridor.terrain.near
        let sampler = corridor.terrain
        // The Riviera's blocks are 16 m (chunks still 128 m), so the 1 m and
        // 2 m lattices keep closer to their radii: on the Poggio's 4.3 km
        // of zig-zags that is 7 % fewer triangles, all of them more than
        // 64 m from the road (`WorldBudget`).
        let riviera = corridor.art.look.isRiviera
        // Lattice on the cell centres, so 1 m vertices carry the raw LiDAR.
        let L = Lattice(nx: r.cols, nz: r.rows,
                        x0: Float(r.originEast + r.cellM / 2), z0: Float(-(r.originNorth - r.cellM / 2)),
                        step: Float(r.cellM), blockSize: riviera ? 16 : 32)
        let bxN = L.blocksX, bzN = L.blocksZ

        // Block spacing from the distance to the route.
        var spacing = [Int](repeating: 8, count: bxN * bzN)
        var blockDist = [Double](repeating: 0, count: bxN * bzN)
        for bz in 0..<bzN {
            for bx in 0..<bxN {
                let e0 = r.originEast + Double(bx * L.blockSize) * r.cellM
                let e1 = r.originEast + Double(min((bx + 1) * L.blockSize, L.nx - 1)) * r.cellM
                let n1 = r.originNorth - Double(bz * L.blockSize) * r.cellM
                let n0 = r.originNorth - Double(min((bz + 1) * L.blockSize, L.nz - 1)) * r.cellM
                let d = corridor.coarse.minDistance(east0: e0, east1: e1, north0: n0, north1: n1)
                // The coarse field ignores the road's extensions; the near
                // field covers them.
                var dd = d
                if dd > config.terrain1mRadius {
                    let ci0 = bx * L.blockSize, cj0 = bz * L.blockSize
                    outer: for cj in stride(from: cj0, to: min(cj0 + L.blockSize, L.nz), by: 4) {
                        for ci in stride(from: ci0, to: min(ci0 + L.blockSize, L.nx), by: 4) {
                            if let f = corridor.near.lookup(col: ci, row: cj), f.dist < 30 { dd = 0; break outer }
                        }
                    }
                }
                blockDist[bz * bxN + bx] = dd
                spacing[bz * bxN + bx] = dd < config.terrain1mRadius ? 1
                    : dd < config.terrain2mRadius ? 2
                    : dd < config.terrain4mRadius ? 4 : 8
            }
        }

        // Vertex heights, cached per lattice point on demand.
        let cols = r.cols
        var cacheH = [Float](repeating: .nan, count: r.cols * r.rows)
        var cacheHidden = [Bool](repeating: false, count: r.cols * r.rows)
        func baseAt(_ i: Int, _ j: Int) -> Float { sampler.lattice(col: i, row: j) }
        func heightAt(_ i: Int, _ j: Int) -> (h: Float, hidden: Bool) {
            let k = j * cols + i
            let c = cacheH[k]
            if !c.isNaN { return (c, cacheHidden[k]) }
            var h = sampler.lattice(col: i, row: j)
            var hid = false
            if let f = corridor.near.lookup(col: i, row: j) {
                let st = corridor.station(f.segment, Double(f.fraction))
                let verge = f.lateral >= 0 ? st.vergeRight : st.vergeLeft
                let outer = st.halfWidth + verge
                let core = max(st.halfWidth + 0.25, outer - 4)
                let rampEnd = max(core + 0.4, outer - 0.6)
                let d = Double(f.dist)
                let taper = Float(1 - smoothstepD(0.8, 1.0, st.beyond))
                if d < rampEnd, taper > 0 {
                    if d <= core {
                        let road = Float(corridor.roadHeight(st, lateral: Double(f.lateral)))
                        h = min(h, road) - 1.2 * taper
                        hid = d < core - 0.5 && taper > 0.99
                    } else {
                        let w = Float(1 - smoothstepD(core, rampEnd, d))
                        h -= 1.2 * w * taper
                    }
                }
            }
            if h <= seaFloor { hid = true }
            cacheH[k] = h; cacheHidden[k] = hid
            return (h, hid)
        }

        // Chunks of 4 x 4 blocks (8 x 8 on the Riviera).
        let chunkBlocks = riviera ? 8 : 4
        var chunks: [Chunk] = []
        for cz in stride(from: 0, to: bzN, by: chunkBlocks) {
            for cx in stride(from: 0, to: bxN, by: chunkBlocks) {
                if Task.isCancelled { return chunks }
                var mesh = MeshBuffer()
                var minSp = 8
                var nearRoute = false
                for bz in cz..<min(cz + chunkBlocks, bzN) {
                    for bx in cx..<min(cx + chunkBlocks, bxN) {
                        minSp = min(minSp, spacing[bz * bxN + bx])
                        if blockDist[bz * bxN + bx] < config.terrain2mRadius { nearRoute = true }
                        meshBlock(into: &mesh, lattice: L, bx: bx, bz: bz,
                                  spacing: { spacing[$1 * bxN + $0] },
                                  heightAt: heightAt, baseAt: baseAt, dropHidden: true,
                                  skirt: (bx == 0, bx == bxN - 1, bz == 0, bz == bzN - 1),
                                  skirtDepth: 4)
                    }
                }
                // A lighter version for distant views: nothing finer than
                // 2 m, everything under the road dropped, skirts all round.
                var lod: MeshBuffer?
                if minSp < 2 {
                    var m = MeshBuffer()
                    let cx1 = min(cx + chunkBlocks, bxN) - 1, cz1 = min(cz + chunkBlocks, bzN) - 1
                    for bz in cz...cz1 {
                        for bx in cx...cx1 {
                            meshBlock(into: &m, lattice: L, bx: bx, bz: bz,
                                      spacing: { spacing[$1 * bxN + $0] },
                                      heightAt: heightAt, baseAt: baseAt, dropHidden: true,
                                      skirt: (bx == cx, bx == cx1, bz == cz, bz == cz1),
                                      skirtDepth: 3, minSpacing: 2)
                        }
                    }
                    lod = m
                }
                guard !mesh.isEmpty else { continue }
                let midI = min((cx * L.blockSize + (cx + chunkBlocks) * L.blockSize) / 2, L.nx - 1)
                let midJ = min((cz * L.blockSize + (cz + chunkBlocks) * L.blockSize) / 2, L.nz - 1)
                let centre = SIMD3(L.x(midI), baseAt(midI, midJ), L.z(midJ))
                chunks.append(Chunk(mesh: mesh, lod: lod, centre: centre, nearRoute: nearRoute))
            }
        }
        return chunks
    }

    // MARK: - Far grid

    static func buildFar(corridor: RoadCorridor, config: WorldConfig, seaLevel: Double? = nil) -> [Chunk] {
        guard let far = corridor.terrain.far else { return [] }
        // On a coast a cell without data is open sea, on the sea floor.
        let seaFloor = seaLevel.map { Float($0) - 0.5 } ?? -.infinity
        let noData: Float = seaLevel.map { Float($0) - 1 } ?? 0
        let sampler = corridor.terrain
        let L = Lattice(nx: far.cols, nz: far.rows,
                        x0: Float(far.originEast + far.cellM / 2), z0: Float(-(far.originNorth - far.cellM / 2)),
                        step: Float(far.cellM), blockSize: 32)
        let bxN = L.blocksX, bzN = L.blocksZ
        let near = corridor.terrain.near
        func rectDistance(_ e0: Double, _ e1: Double, _ n0: Double, _ n1: Double) -> Double {
            let dx = max(near.minEast - e1, 0, e0 - near.maxEast)
            let dy = max(near.minNorth - n1, 0, n0 - near.maxNorth)
            return sqrt(dx * dx + dy * dy)
        }
        var spacing = [Int](repeating: 4, count: bxN * bzN)
        var skip = [Bool](repeating: false, count: bxN * bzN)
        for bz in 0..<bzN {
            for bx in 0..<bxN {
                let e0 = Double(L.x(bx * L.blockSize)), e1 = Double(L.x(min((bx + 1) * L.blockSize, L.nx - 1)))
                let n1 = -Double(L.z(bz * L.blockSize)), n0 = -Double(L.z(min((bz + 1) * L.blockSize, L.nz - 1)))
                let d = rectDistance(e0, e1, n0, n1)
                spacing[bz * bxN + bx] = d < config.far10mRadius ? 1 : d < config.far20mRadius ? 2 : 4
                // Blocks wholly inside the near grid (with margin) are hidden.
                let m = 40.0
                skip[bz * bxN + bx] = e0 > near.minEast + m && e1 < near.maxEast - m
                    && n0 > near.minNorth + m && n1 < near.maxNorth - m
            }
        }
        let cols = far.cols
        func baseAt(_ i: Int, _ j: Int) -> Float {
            let v = far.values[min(max(j, 0), far.rows - 1) * cols + min(max(i, 0), far.cols - 1)]
            return v.isNaN ? noData : v
        }
        func heightAt(_ i: Int, _ j: Int) -> (h: Float, hidden: Bool) {
            let h = baseAt(i, j)
            let e = Double(L.x(i)), n = -Double(L.z(j))
            let edge = sampler.nearEdgeDistance(east: e, north: n)
            // Sink under the near grid; the near grid's skirt covers the step.
            if edge > 0 { return (h - 2.5, edge > 25 || h <= seaFloor) }
            return (h, h <= seaFloor)
        }
        var chunks: [Chunk] = []
        let chunkBlocks = 2
        for cz in stride(from: 0, to: bzN, by: chunkBlocks) {
            for cx in stride(from: 0, to: bxN, by: chunkBlocks) {
                if Task.isCancelled { return chunks }
                var mesh = MeshBuffer()
                for bz in cz..<min(cz + chunkBlocks, bzN) {
                    for bx in cx..<min(cx + chunkBlocks, bxN) where !skip[bz * bxN + bx] {
                        meshBlock(into: &mesh, lattice: L, bx: bx, bz: bz,
                                  spacing: { spacing[$1 * bxN + $0] },
                                  heightAt: heightAt, baseAt: baseAt, dropHidden: true,
                                  skirt: (bx == 0, bx == bxN - 1, bz == 0, bz == bzN - 1),
                                  skirtDepth: 60)
                    }
                }
                guard !mesh.isEmpty else { continue }
                let midI = min((cx + 1) * L.blockSize, L.nx - 1), midJ = min((cz + 1) * L.blockSize, L.nz - 1)
                chunks.append(Chunk(mesh: mesh, lod: nil,
                                    centre: SIMD3(L.x(midI), baseAt(midI, midJ), L.z(midJ)), nearRoute: false))
            }
        }
        return chunks
    }

    // MARK: - Horizon ring

    /// The course's horizon raster (`terrain.horizon`, `u16le_dm`): coarse
    /// land out to the skyline beyond the far grid, decoded for this build
    /// only. Nil when the course has none (every Flemish one).
    static func horizonRaster(bundle: CourseBundle) -> HeightRaster? {
        guard let header = bundle.course.terrain.horizon else { return nil }
        return try? HeightRaster.load(from: bundle.directory.appendingPathComponent(header.file), header: header)
    }

    /// The horizon ring: the horizon raster's land beyond the far grid (the
    /// Alpi Liguri behind the Poggio, the coast to Capo Berta and
    /// Bordighera), its sea left to `SeaBuilder`. Vertex spacing grows with
    /// the distance from the far grid, from one cell to eight, so the ridges
    /// a few kilometres off keep their shape and the far ones cost little;
    /// the battery tier takes half as many. Inside the far grid it is sunk
    /// out of sight (the far grid's 60 m skirts cover the step at its edge)
    /// and blocks wholly inside are left out.
    static func buildHorizon(corridor: RoadCorridor, raster r: HeightRaster, config: WorldConfig,
                             seaLevel: Double?) -> [Chunk] {
        let inner = corridor.terrain.far ?? corridor.terrain.near
        // The sea's cells (`SeaBuilder.seaMask`: this raster codes its sea
        // less tidily than the near and far grids).
        let sea = seaLevel.map { SeaBuilder.seaMask(r, level: Float($0), coarse: true) }
        let noData: Float = seaLevel.map { Float($0) - 1 } ?? 0
        let L = Lattice(nx: r.cols, nz: r.rows,
                        x0: Float(r.originEast + r.cellM / 2), z0: Float(-(r.originNorth - r.cellM / 2)),
                        step: Float(r.cellM), blockSize: 16)
        let bxN = L.blocksX, bzN = L.blocksZ
        func rectDistance(_ e0: Double, _ e1: Double, _ n0: Double, _ n1: Double) -> Double {
            let dx = max(inner.minEast - e1, 0, e0 - inner.maxEast)
            let dy = max(inner.minNorth - n1, 0, n0 - inner.maxNorth)
            return sqrt(dx * dx + dy * dy)
        }
        // Wanted spacing: 40 m plus 1.2 % of the distance from the far grid
        // (75 m at 3 km, 160 m at 10 km, 280 m at 20 km), in whole cells.
        let coarse = config.quality == .battery ? 2.0 : 1.0
        var spacing = [Int](repeating: 1, count: bxN * bzN)
        var skip = [Bool](repeating: false, count: bxN * bzN)
        for bz in 0..<bzN {
            for bx in 0..<bxN {
                let e0 = Double(L.x(bx * L.blockSize)), e1 = Double(L.x(min((bx + 1) * L.blockSize, L.nx - 1)))
                let n1 = -Double(L.z(bz * L.blockSize)), n0 = -Double(L.z(min((bz + 1) * L.blockSize, L.nz - 1)))
                let d = rectDistance(e0, e1, n0, n1)
                let cells = (40 + 0.012 * d) * coarse / r.cellM
                var sp = 1
                while sp * 2 <= Int(cells), sp < 8 { sp *= 2 }
                spacing[bz * bxN + bx] = sp
                let m = r.cellM * 2
                skip[bz * bxN + bx] = e0 > inner.minEast + m && e1 < inner.maxEast - m
                    && n0 > inner.minNorth + m && n1 < inner.maxNorth - m
            }
        }
        let cols = r.cols
        func baseAt(_ i: Int, _ j: Int) -> Float {
            let v = r.values[min(max(j, 0), r.rows - 1) * cols + min(max(i, 0), r.cols - 1)]
            return v.isNaN ? noData : v
        }
        func heightAt(_ i: Int, _ j: Int) -> (h: Float, hidden: Bool) {
            let h = baseAt(i, j)
            let e = Double(L.x(i)), n = -Double(L.z(j))
            let edge = min(e - inner.minEast, inner.maxEast - e, n - inner.minNorth, inner.maxNorth - n)
            let wet = sea?[min(max(j, 0), r.rows - 1) * cols + min(max(i, 0), r.cols - 1)] ?? false
            // Under the far grid by more than a coarse cell's sag.
            if edge > 0 { return (h - 30, edge > r.cellM * 1.5 || wet) }
            return (h, wet)
        }
        var chunks: [Chunk] = []
        let chunkBlocks = 4
        for cz in stride(from: 0, to: bzN, by: chunkBlocks) {
            for cx in stride(from: 0, to: bxN, by: chunkBlocks) {
                if Task.isCancelled { return chunks }
                var mesh = MeshBuffer()
                for bz in cz..<min(cz + chunkBlocks, bzN) {
                    for bx in cx..<min(cx + chunkBlocks, bxN) where !skip[bz * bxN + bx] {
                        meshBlock(into: &mesh, lattice: L, bx: bx, bz: bz,
                                  spacing: { spacing[$1 * bxN + $0] },
                                  heightAt: heightAt, baseAt: baseAt, dropHidden: true,
                                  skirt: (bx == 0, bx == bxN - 1, bz == 0, bz == bzN - 1),
                                  skirtDepth: 200)
                    }
                }
                guard !mesh.isEmpty else { continue }
                let midI = min((cx + 2) * L.blockSize, L.nx - 1), midJ = min((cz + 2) * L.blockSize, L.nz - 1)
                chunks.append(Chunk(mesh: mesh, lod: nil,
                                    centre: SIMD3(L.x(midI), baseAt(midI, midJ), L.z(midJ)), nearRoute: false))
            }
        }
        return chunks
    }
}
