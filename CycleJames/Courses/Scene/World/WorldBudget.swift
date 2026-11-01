import Foundation
import SceneKit
import QuartzCore
import simd

/// The Riviera's world budget. The Poggio di Sanremo is a 4.3 km ride
/// through a terraced, built-up hillside: 2,000 buildings and greenhouse
/// bands, 1,760 mapped walls, guardrails and balconies along most of the
/// road. Built the Flemish way it came to 4.5 M triangles on high with
/// every building, prop and verge in one node each, so all of them were
/// drawn whole in every frame and in every shadow cascade wherever the
/// camera looked (1.6-2.2 M triangles in view; the Oude Kwaremont 0.6-1.2 M).
///
/// Here, for the Riviera only (every Flemish course keeps its meshes and
/// nodes exactly):
/// - `WorldTiles`: the whole-course meshes cut into square tiles, so
///   SceneKit culls them to the view and to each shadow cascade, and the
///   small props let go of beyond the distance where a railing or a
///   bollard is under a pixel; the plant clusters with only light trees
///   gathered four to a node, for fewer draws;
/// - `WorldConfig.riviera()` and `RivieraDetail`: the tier knobs the
///   Poggio's terrain, plants, buildings and roadside are built with.
/// High then has 0.46-1.5 M triangles and 100-670 draws in view (the
/// Kwaremont 0.6-1.2 M and 180-710), and looks the same within a JPEG's
/// noise (shots in the budget report).
enum WorldTiles {
    /// Tile edges, metres. The road's ribbons in 192 m tiles (a few draws
    /// each in view); buildings and props, spread over the whole hillside
    /// with a dozen materials, in 256 m ones, so a view across the valley
    /// stays within the Oude Kwaremont's draws.
    static let roadSize: Float = 192
    static let builtSize: Float = 256

    /// Nodes for `mesh`, one per tile with any of its triangles, each at its
    /// tile's centre (SceneKit picks a level of detail by the distance to
    /// the node). `hideBeyond`: camera distance from the tile's centre past
    /// which it draws only the parts in `keepBeyond` (nothing without).
    static func nodes(_ mesh: MeshBuffer, materials: [SCNMaterial], size: Float, hideBeyond: Float? = nil,
                      keepBeyond: Set<Int>? = nil, casts: Bool, name: String? = nil) -> [SCNNode] {
        var out: [SCNNode] = []
        // Each tile let go of once its geometry is made.
        var tiles = mesh.tiles(size: size)
        while var tile = tiles.popLast() {
            let centre = tile.boxCentre
            tile.translate(by: -centre)
            guard let g = tile.geometry(materials: materials) else { continue }
            if let d = hideBeyond {
                var farTile = tile
                for k in farTile.parts.indices where !(keepBeyond?.contains(k) ?? false) { farTile.parts[k] = [] }
                g.levelsOfDetail = [SCNLevelOfDetail(geometry: farTile.compacted().geometry(materials: materials),
                                                     worldSpaceDistance: CGFloat(d))]
            }
            let node = SCNNode(geometry: g)
            node.simdPosition = centre
            node.castsShadow = casts
            node.name = name
            out.append(node)
        }
        return out
    }
}

/// How finely the Riviera's buildings and roadside are built on each tier
/// (`BuildingBuilder.build`). High draws everything within 60 m of the road
/// as the buildings and roadside work left it; balanced and battery give
/// up the finest ironwork and the furthest walls first.
struct RivieraDetail: Sendable {
    /// Balcony rails bar by bar (15 cm) and balustrades baluster by
    /// baluster (20 cm) within this distance of the route; further out a
    /// rail on posts every 1.2 m, a balustrade as rails and a panel.
    var fineRailM: Double
    /// The same for the balustrades round roof terraces.
    var fineRoofRailM: Double
    /// Balcony bars as a strip each way (4 triangles) rather than a square
    /// bar (8): 1.8 cm of iron is two pixels across at 10 m.
    var flatBars: Bool
    /// Houses with their windows and doors cut, within this distance;
    /// beyond, painted bays.
    var houseDetailM: Double
    /// Greenhouses span by span within this, as boxes whose roof the
    /// shader draws in spans out to `greenhouseMaxM`, and none beyond (a
    /// few pixels of grey glass there, which the ground's 2022 photo
    /// already shows).
    var greenhouseDetailM: Double
    var greenhouseMaxM: Double
    /// The map's walls (CTR): terraces, the other walls, fences.
    var terraceWallM: Double
    var otherWallM: Double
    var fenceM: Double
    /// Camera distance from a props tile's centre (`WorldTiles.builtSize`,
    /// so its contents up to 180 m nearer) past which its ironwork, lamp
    /// glass, chain-link and shade netting let go (`ironParts`); the rest
    /// of the props from 500 m, but for the stone walls and guardrails.
    /// On the Poggio the ironwork is a quarter to a half of the props in
    /// view (balcony and roof rails, spear railings, gates: 25-72 k
    /// triangles at the 1650-4031 eye views on high, the shot report's
    /// "props by part"), bars 1.5-4 cm thick: under a pixel from ~60 m on
    /// battery's 1024-px textures and no multisampling, where they only
    /// alias.
    var ironM: Float

    /// The props parts `ironM` applies to.
    static let ironParts: Set<BuildingBuilder.PropPart> = [.darkMetal, .lampGlass, .chainLink, .shadeNet]

    static let high = RivieraDetail(fineRailM: 35, fineRoofRailM: 60, flatBars: false,
                                    houseDetailM: BuildingBuilder.detailRouteDistance,
                                    greenhouseDetailM: BuildingBuilder.greenhouseDetailDistance, greenhouseMaxM: 500,
                                    terraceWallM: 250, otherWallM: 120, fenceM: 60, ironM: 420)
    static let balanced = RivieraDetail(fineRailM: 22, fineRoofRailM: 30, flatBars: true, houseDetailM: 60,
                                        greenhouseDetailM: 110, greenhouseMaxM: 450,
                                        terraceWallM: 180, otherWallM: 90, fenceM: 45, ironM: 340)
    static let battery = RivieraDetail(fineRailM: 15, fineRoofRailM: 15, flatBars: true, houseDetailM: 40,
                                       greenhouseDetailM: 60, greenhouseMaxM: 350,
                                       terraceWallM: 100, otherWallM: 60, fenceM: 30, ironM: 220)

    static func make(_ q: GraphicsQuality) -> RivieraDetail {
        var d: RivieraDetail
        switch q {
        case .high: d = .high
        case .balanced: d = .balanced
        case .battery: d = .battery
        }
        #if DEBUG
        if WorldConfig.budgetRound1 { d.ironM = 500 }
        #endif
        return d
    }
}

extension WorldConfig {
    /// The tier's knobs for the Riviera. High keeps its 1 m terrain and
    /// its plants. Balanced and battery draw the 2 m and 4 m terrain (and
    /// on balanced the 1 m) a little closer in and the distant shrubs less
    /// far:
    /// terrain and plants are half of what the Poggio builds. (The full
    /// trees keep their reach: a cluster drawn in full leaves out the trees
    /// beyond it, so a shorter reach takes trees away 60-90 m from the
    /// camera.)
    ///
    /// Round 2 (31 October): the 2 m and 4 m lattices end nearer on every
    /// tier, which takes the Poggio's built triangles back towards the
    /// first shoot's (4.40 / 3.49 / 2.41 M) after the fasce, scrub, side
    /// roads and summit added to them; 20 shots over the three tiers at
    /// the same positions with the first round's knobs (`-budgetRound1`)
    /// differ by 0.0-0.3 of 255 on average, at most 4 pixels in 10,000 by
    /// more than 40 (far slopes' shading). The 1 m lattice keeps its reach
    /// on high: the side roads are draped on it to 4 m short of its edge
    /// (`buildSideRoads`' reach).
    func riviera() -> WorldConfig {
        var c = self
        #if DEBUG
        if Self.budgetRound1 { return rivieraRound1() }
        #endif
        switch quality {
        case .high:
            c.terrain2mRadius = 125; c.terrain4mRadius = 320
        case .balanced:
            c.terrain1mRadius = 30; c.terrain2mRadius = 80; c.terrain4mRadius = 220
            c.shrubMaxRouteRadius = 320
        case .battery:
            c.terrain2mRadius = 30; c.terrain4mRadius = 100
            c.shrubMaxRouteRadius = 130
        }
        return c
    }

    #if DEBUG
    /// Development aid: `-budgetRound1` builds the Riviera with the first
    /// round's knobs (the terrain radii above, all props to 500 m), for
    /// A/B shots on one binary.
    static var budgetRound1: Bool { ProcessInfo.processInfo.arguments.contains("-budgetRound1") }

    private func rivieraRound1() -> WorldConfig {
        var c = self
        switch quality {
        case .high:
            break
        case .balanced:
            c.terrain1mRadius = 30; c.terrain2mRadius = 120; c.terrain4mRadius = 300
            c.shrubMaxRouteRadius = 320
        case .battery:
            c.terrain2mRadius = 50; c.terrain4mRadius = 180
            c.shrubMaxRouteRadius = 130
        }
        return c
    }
    #endif
}

extension WorldTiles {
    /// Edge of the cells the light-only plant clusters are gathered in.
    static let lightClusterSize: Float = 96

    /// The plant clusters with no full geometry, merged four to one by
    /// their centres on a 96 m grid (those with full trees as they are).
    /// Such a cluster's light trees swap to impostors at the tier's
    /// distance from the merged centre, at most 68 m from their own
    /// (34 m before): at 330 m, under the impostors' own pixels' worth.
    static func mergeLightClusters(_ clusters: [VegetationBuilder.Cluster]) -> [VegetationBuilder.Cluster] {
        var out: [VegetationBuilder.Cluster] = []
        var merged: [SIMD2<Int32>: Int] = [:]
        for c in clusters {
            guard c.full.isEmpty, !c.light.isEmpty else { out.append(c); continue }
            let centre = c.light.boxCentre
            let key = SIMD2(Int32((centre.x / lightClusterSize).rounded(.down)),
                            Int32((centre.z / lightClusterSize).rounded(.down)))
            if let i = merged[key], out[i].light.sameChannels(as: c.light), out[i].impostor.sameChannels(as: c.impostor) {
                out[i].light.appendExactly(c.light)
                out[i].impostor.appendExactly(c.impostor)
            } else {
                merged[key] = out.count
                out.append(c)
            }
        }
        return out
    }
}

extension MeshBuffer {
    /// Whether `other` carries the same optional vertex channels.
    func sameChannels(as other: MeshBuffer) -> Bool {
        let n = vertexCount, m = other.vertexCount
        func has(_ a: [Float], _ k: Int, _ v: Int) -> Bool { a.count == v * k }
        return parts.count == other.parts.count
            && has(normals, 3, n) == has(other.normals, 3, m) && has(uvs, 2, n) == has(other.uvs, 2, m)
            && has(uv2, 2, n) == has(other.uv2, 2, m) && has(uv3, 2, n) == has(other.uv3, 2, m)
            && has(uv4, 2, n) == has(other.uv4, 2, m) && has(colors, 4, n) == has(other.colors, 4, m)
    }

    /// `boundsCentre` by scalars (quicker in Debug builds).
    var boxCentre: SIMD3<Float> {
        positions.withUnsafeBufferPointer { p in
            guard p.count >= 3 else { return .zero }
            var lo = (p[0], p[1], p[2]), hi = lo
            var i = 3
            while i + 2 < p.count {
                let x = p[i], y = p[i + 1], z = p[i + 2]
                if x < lo.0 { lo.0 = x }
                if x > hi.0 { hi.0 = x }
                if y < lo.1 { lo.1 = y }
                if y > hi.1 { hi.1 = y }
                if z < lo.2 { lo.2 = z }
                if z > hi.2 { hi.2 = z }
                i += 3
            }
            return SIMD3((lo.0 + hi.0) / 2, (lo.1 + hi.1) / 2, (lo.2 + hi.2) / 2)
        }
    }

    /// The mesh with only the vertices its parts use.
    func compacted() -> MeshBuffer {
        var remap = [UInt32](repeating: .max, count: vertexCount)
        var used: [Int] = []
        var out = MeshBuffer(parts: parts.count)
        for (k, part) in parts.enumerated() {
            out.parts[k] = Self.reindex(part, remap: &remap, used: &used)
        }
        copyChannels(of: used, into: &out)
        return out
    }

    /// `indices` renumbered in the order their vertices are first met
    /// (`remap` holds each one's new number, `used` the old ones in order).
    static func reindex(_ indices: [UInt32], remap: inout [UInt32], used: inout [Int]) -> [UInt32] {
        [UInt32](unsafeUninitializedCapacity: indices.count) { out, count in
            indices.withUnsafeBufferPointer { src in
                remap.withUnsafeMutableBufferPointer { map in
                    var i = 0
                    while i < src.count {
                        let v = Int(src[i])
                        if map[v] == .max {
                            map[v] = UInt32(used.count)
                            used.append(v)
                        }
                        out[i] = map[v]
                        i += 1
                    }
                }
            }
            count = indices.count
        }
    }

    /// Every vertex channel of the vertices `used`, in that order, into `m`.
    func copyChannels(of used: [Int], into m: inout MeshBuffer) {
        let n = vertexCount
        func gather(_ src: [Float], _ c: Int) -> [Float] {
            guard src.count == n * c else { return [] }
            return [Float](unsafeUninitializedCapacity: used.count * c) { out, count in
                src.withUnsafeBufferPointer { s in
                    used.withUnsafeBufferPointer { u in
                        var o = 0, i = 0
                        while i < u.count {
                            let base = c * u[i]
                            var j = 0
                            while j < c { out[o] = s[base + j]; o += 1; j += 1 }
                            i += 1
                        }
                    }
                }
                count = used.count * c
            }
        }
        m.positions = gather(positions, 3)
        m.normals = gather(normals, 3)
        m.uvs = gather(uvs, 2)
        m.uv2 = gather(uv2, 2)
        m.uv3 = gather(uv3, 2)
        m.uv4 = gather(uv4, 2)
        m.colors = gather(colors, 4)
    }

    /// Appends `other` as it is (`sameChannels`): every vertex and channel
    /// copied, the parts one to one.
    mutating func appendExactly(_ other: MeshBuffer) {
        let base = UInt32(vertexCount)
        positions.append(contentsOf: other.positions)
        normals.append(contentsOf: other.normals)
        uvs.append(contentsOf: other.uvs)
        uv2.append(contentsOf: other.uv2)
        uv3.append(contentsOf: other.uv3)
        uv4.append(contentsOf: other.uv4)
        colors.append(contentsOf: other.colors)
        for (k, src) in other.parts.enumerated() {
            parts[k].reserveCapacity(parts[k].count + src.count)
            for idx in src { parts[k].append(idx + base) }
        }
    }

    /// The mesh cut into square tiles `size` metres across on the ground
    /// (scene x and z, from the origin), each triangle going to the tile
    /// its centre is in, each tile keeping only the vertices its triangles
    /// use. Parts and every vertex channel carry over.
    func tiles(size: Float) -> [MeshBuffer] {
        let n = vertexCount
        guard n > 0, !isEmpty else { return [] }
        // Every part's triangles in one list, and each one's part.
        var flat: [UInt32] = []
        flat.reserveCapacity(triangleCount * 3)
        var partOf: [Int32] = []
        partOf.reserveCapacity(triangleCount)
        for (k, part) in parts.enumerated() {
            let whole = part.count / 3 * 3
            flat.append(contentsOf: part[0..<whole])
            partOf.append(contentsOf: repeatElement(Int32(k), count: whole / 3))
        }
        let triangles = partOf.count
        // Each triangle's tile, on the world's own grid so every mesh's
        // tiles line up; then the triangles sorted by tile (a counting sort
        // that keeps their order).
        var tileOf = [Int32](repeating: 0, count: triangles)
        var cols = 0, tileCount = 0
        positions.withUnsafeBufferPointer { pos in
            flat.withUnsafeBufferPointer { idx in
                // (Scalars and while loops: SIMD and ranges are slow in Debug.)
                var x0 = Float.greatestFiniteMagnitude, z0 = x0, x1 = -x0, z1 = -x0
                var i = 0
                while i < n {
                    let x = pos[3 * i], z = pos[3 * i + 2]
                    if x < x0 { x0 = x }
                    if x > x1 { x1 = x }
                    if z < z0 { z0 = z }
                    if z > z1 { z1 = z }
                    i += 1
                }
                x0 = (x0 / size).rounded(.down) * size
                z0 = (z0 / size).rounded(.down) * size
                cols = Int((x1 - x0) / size) + 1
                let rows = Int((z1 - z0) / size) + 1
                tileCount = cols * rows
                tileOf.withUnsafeMutableBufferPointer { tileOf in
                    var t = 0
                    while t < triangles {
                        let a = Int(idx[3 * t]), b = Int(idx[3 * t + 1]), c = Int(idx[3 * t + 2])
                        let x = (pos[3 * a] + pos[3 * b] + pos[3 * c]) / 3
                        let z = (pos[3 * a + 2] + pos[3 * b + 2] + pos[3 * c + 2]) / 3
                        let col = min(max(Int((x - x0) / size), 0), cols - 1)
                        let row = min(max(Int((z - z0) / size), 0), rows - 1)
                        tileOf[t] = Int32(row * cols + col)
                        t += 1
                    }
                }
            }
        }
        var start = [Int](repeating: 0, count: tileCount + 1)
        var order = [Int32](repeating: 0, count: triangles)
        tileOf.withUnsafeBufferPointer { tileOf in
            start.withUnsafeMutableBufferPointer { start in
                var t = 0
                while t < triangles { start[Int(tileOf[t]) + 1] += 1; t += 1 }
                var i = 1
                while i < start.count { start[i] += start[i - 1]; i += 1 }
                var fill = Array(start)
                order.withUnsafeMutableBufferPointer { order in
                    fill.withUnsafeMutableBufferPointer { fill in
                        var t = 0
                        while t < triangles {
                            let tile = Int(tileOf[t])
                            order[fill[tile]] = Int32(t)
                            fill[tile] += 1
                            t += 1
                        }
                    }
                }
            }
        }
        var remap = [UInt32](repeating: .max, count: n)
        var out: [MeshBuffer] = []
        for tile in 0..<tileCount where start[tile + 1] > start[tile] {
            // The tile's triangles in their order, which (the sort being
            // stable) is part by part.
            let first = start[tile], count = start[tile + 1] - first
            let local = [UInt32](unsafeUninitializedCapacity: count * 3) { buf, filled in
                flat.withUnsafeBufferPointer { idx in
                    order.withUnsafeBufferPointer { ord in
                        for o in 0..<count {
                            let t = Int(ord[first + o])
                            buf[3 * o] = idx[3 * t]; buf[3 * o + 1] = idx[3 * t + 1]; buf[3 * o + 2] = idx[3 * t + 2]
                        }
                    }
                }
                filled = count * 3
            }
            var used: [Int] = []
            let renumbered = Self.reindex(local, remap: &remap, used: &used)
            var m = MeshBuffer(parts: parts.count)
            var o = 0
            while o < count {
                let k = Int(partOf[Int(order[first + o])])
                var e = o + 1
                while e < count, partOf[Int(order[first + e])] == Int32(k) { e += 1 }
                m.parts[k] = Array(renumbered[(3 * o)..<(3 * e)])
                o = e
            }
            copyChannels(of: used, into: &m)
            remap.withUnsafeMutableBufferPointer { map in for v in used { map[v] = .max } }
            out.append(m)
        }
        return out
    }
}

#if DEBUG
/// Development aid: where a world's triangles lie, by mesh (and material
/// part) and by distance from the route, written beside the world shots as
/// budget_<quality><tag>.txt. Turned on by `-worldBudget` together with
/// `-worldShots`; costs a route query per triangle, so it is off otherwise.
struct WorldBudgetReport {
    static var enabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-worldBudget") && WorldDebugShots.directory != nil
    }

    /// Upper edges of the distance bands, metres from the centreline.
    static let bands: [Double] = [30, 60, 120, 250, 450, .infinity]

    let corridor: RoadCorridor
    private var rows: [String: [Int]] = [:]

    init(corridor: RoadCorridor) { self.corridor = corridor }

    /// Bins every triangle of `m` (moved by `offset` into the world) by its
    /// centre's distance from the route; `perPart` keeps the parts apart.
    mutating func add(_ name: String, _ m: MeshBuffer, offset: SIMD3<Float> = .zero, perPart: Bool = false) {
        let p = m.positions
        for (k, part) in m.parts.enumerated() where !part.isEmpty {
            let key = perPart ? "\(name) [\(k)]" : name
            var row = rows[key] ?? [Int](repeating: 0, count: Self.bands.count)
            var t = 0
            while t + 2 < part.count {
                let a = Int(part[t]), b = Int(part[t + 1]), c = Int(part[t + 2])
                let x = (p[3 * a] + p[3 * b] + p[3 * c]) / 3 + offset.x
                let z = (p[3 * a + 2] + p[3 * b + 2] + p[3 * c + 2]) / 3 + offset.z
                let d = corridor.coarse.query(east: Double(x), north: Double(-z)).dist
                row[Self.bands.firstIndex { d < $0 } ?? Self.bands.count - 1] += 1
                t += 3
            }
            rows[key] = row
        }
    }

    func write(quality: GraphicsQuality) {
        guard let dir = WorldDebugShots.directory else { return }
        var lines = ["triangles by distance from the route (m): <30 <60 <120 <250 <450 beyond | total"]
        for (k, row) in rows.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(k): " + row.map(String.init).joined(separator: " ") + " | \(row.reduce(0, +))")
        }
        var sum = [Int](repeating: 0, count: Self.bands.count)
        for row in rows.values { for i in sum.indices { sum[i] += row[i] } }
        lines.append("  ALL: " + sum.map(String.init).joined(separator: " ") + " | \(sum.reduce(0, +))")
        let url = URL(fileURLWithPath: dir).appendingPathComponent("budget_\(quality.rawValue)\(WorldDebugShots.tag).txt")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
#endif

/// Each builder's own time, for the world log (cj_world_log): the builders
/// run side by side, so a stage's time there is only the longest of those
/// it waits for. Wall time from the builder's start to its end and the CPU
/// time of its thread (each builder is synchronous, so it runs on one
/// thread from start to end). Safe from any thread.
final class WorldBuildTimes: @unchecked Sendable {
    struct Entry {
        let name: String
        /// Seconds from the start of the world build.
        let start: Double
        let wall: Double
        let cpu: Double
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let origin: Double

    init(origin: Double) { self.origin = origin }

    func time<T>(_ name: String, _ body: () -> T) -> T {
        let t0 = CACurrentMediaTime(), c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let out = body()
        let entry = Entry(name: name, start: t0 - origin, wall: CACurrentMediaTime() - t0,
                          cpu: Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0) / 1e9)
        lock.lock()
        entries.append(entry)
        lock.unlock()
        return out
    }

    var all: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.sorted { $0.start < $1.start }
    }

    /// `time`, its result handed over in a `WorldHandOver`.
    func handOver<T>(_ name: String, _ body: () -> T) -> WorldHandOver<T> {
        WorldHandOver(time(name, body))
    }

    /// CPU time of the whole process so far (every thread), seconds.
    static func processCPU() -> Double {
        var u = rusage()
        guard getrusage(RUSAGE_SELF, &u) == 0 else { return 0 }
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(u.ru_utime) + s(u.ru_stime)
    }
}

/// A builder's result, taken out once (`take`). An `async let` keeps the
/// value its task returned until the scope it was declared in ends, so a
/// world build that awaited the meshes itself would hold every one of
/// them to its end, whatever it let go of; through this, only the box.
final class WorldHandOver<T>: @unchecked Sendable {
    private var value: T?

    init(_ value: T) { self.value = value }

    func take() -> T {
        guard let v = value else { preconditionFailure("WorldHandOver taken twice") }
        value = nil
        return v
    }
}

extension MeshBuffer {
    /// Bytes its vertex channels and indices take (as a SceneKit geometry
    /// keeps them too: 4 bytes a float, 2 or 4 an index).
    var byteCount: Int {
        let floats = positions.count + normals.count + uvs.count + uv2.count + uv3.count + uv4.count + colors.count
        let indices = parts.reduce(0) { $0 + $1.count }
        return 4 * floats + (vertexCount <= 65_535 ? 2 : 4) * indices
    }
}

extension BuildingBuilder.EdgeWalls {
    /// The walls along the edge for `corridor`, made once per world build
    /// and shared: the road's aprons (`RoadCorridor.edgeAprons`, in
    /// `RoadBuilder.build`) and the roadside (`buildRivieraRoadside`, in
    /// `BuildingBuilder.build`) both need them and run side by side, and
    /// on the Poggio each pass costs ~1.6 s of a Debug build's CPU. A
    /// caller that comes while another is making them waits for that one.
    /// Only for the corridor's own scenery walls and side roads (the
    /// cache is keyed by the corridor and the walls' count); tests that
    /// try other walls call `init` itself.
    static func shared(corridor: RoadCorridor, walls: [SceneryFile.Wall],
                       sideRoads: @autoclosure () -> RoadBuilder.SideRoadMask) -> Self {
        EdgeWallsCache.lock.lock()
        defer { EdgeWallsCache.lock.unlock() }
        if let hit = EdgeWallsCache.table.object(forKey: corridor), hit.walls == walls.count { return hit.edges }
        let edges = Self(corridor: corridor, walls: walls, sideRoads: sideRoads())
        EdgeWallsCache.table.setObject(EdgeWallsCache.Entry(walls: walls.count, edges: edges), forKey: corridor)
        return edges
    }
}

/// `EdgeWalls.shared`'s store: by corridor, held only while it lives.
private enum EdgeWallsCache {
    final class Entry {
        let walls: Int
        let edges: BuildingBuilder.EdgeWalls
        init(walls: Int, edges: BuildingBuilder.EdgeWalls) { self.walls = walls; self.edges = edges }
    }

    static let lock = NSLock()
    nonisolated(unsafe) static let table = NSMapTable<RoadCorridor, Entry>.weakToStrongObjects()
}
