import Foundation
import simd

/// The Riviera's roadside (the Poggio di Sanremo; look.md sections 3-6):
/// the honey sandstone retaining walls that line most of the uphill edge,
/// grey squared stone and concrete, the sea-side parapets, the dry-stone
/// terraces on the slopes, galvanised W-beam guardrail on the drops,
/// tubular and spear railings, chain-link and shade net round the
/// greenhouse plots, reed screens, the hairpins' chevron plates, the
/// fans' giant letters, the trolleybus wires on the Aurelia and the
/// summit's furniture. All into `Output.props`: stone and concrete on the
/// `masonry` part (`WorldShaders.masonrySurface`), steel on `galvanised`
/// and `darkMetal`, mesh and netting on `chainLink` and `shadeNet`, small
/// paints on the sign atlas (`cj_signs_it`).
///
/// Walls at the carriageway edge come from two places: the Regione Liguria
/// CTR's retaining walls (scenery `walls`, their crests surveyed), snapped
/// to the edge where they run along it, and `CourseArt.masonry`, which
/// gives their stone and what stands on them and fills the stretches the
/// map misses. The CTR's other walls, the terraces (fasce) among them, are
/// built where they stand.
extension BuildingBuilder {
    /// Builds everything above; returns at once on a course without any.
    static func buildRivieraRoadside(_ out: inout Output, corridor: RoadCorridor, scenery: SceneryFile?,
                                     tier: RivieraDetail = .high) {
        let art = corridor.art
        let mapWalls = art.look.isRiviera ? (scenery?.walls ?? []) : []
        guard art.hasRivieraRoadside || !mapWalls.isEmpty else { return }
        var kit = RoadsideKit(cells: signCells(for: art.look))
        let sideRoads = RoadBuilder.SideRoadMask(scenery: scenery)
        let edges = EdgeWalls(corridor: corridor, walls: mapWalls, sideRoads: sideRoads)
        for run in edges.runs { buildEdgeWall(run, corridor: corridor, kit: &kit) }
        let fasce = art.masonry.filter { $0.terraces > 0 }
        if !fasce.isEmpty {
            var houses = Footprints(scenery: scenery)
            houses.addWalls(mapWalls, skip: edges.consumed, along: fasce, corridor: corridor)
            for m in fasce { buildFasce(m, corridor: corridor, sideRoads: sideRoads, houses: houses, kit: &kit) }
        }
        buildMapWalls(mapWalls, skip: edges.consumed, corridor: corridor, kit: &kit, tier: tier)
        buildGuardrails(corridor: corridor, sideRoads: sideRoads, kit: &kit)
        for run in art.railings {
            let line = vergeLine(corridor: corridor, span: run.span, side: run.side, offset: run.offset, sideRoads: sideRoads)
            for piece in line { emitRailing(run.kind, line: piece, side: run.side, kit: &kit) }
        }
        for word in art.paintedWords { paintWord(word, corridor: corridor, kit: &kit) }
        for chevron in art.chevrons { chevronPlate(chevron, corridor: corridor, kit: &kit) }
        for span in art.trolleyWires { trolleyWires(span, corridor: corridor, kit: &kit) }
        for item in art.furniture {
            if case .riviera(let prop) = item.kind { rivieraProp(prop, item: item, corridor: corridor, kit: &kit) }
        }
        for item in art.placed { placedProp(item, corridor: corridor, kit: &kit) }
        buildPoggioSummit(corridor: corridor, scenery: scenery, kit: &kit)  // RoadsideBuilder+PoggioSummit.swift
        kit.append(to: &out)
    }

    // MARK: - Meshes

    /// One mesh per material the Riviera's roadside draws with, appended
    /// to the props at the end.
    struct RoadsideKit {
        let cells: [String: SignCell]
        var stone = MeshBuffer(parts: 1)
        var galvanised = MeshBuffer(parts: 1)
        var dark = MeshBuffer(parts: 1)
        var chain = MeshBuffer(parts: 1)
        var net = MeshBuffer(parts: 1)
        var white = MeshBuffer(parts: 1)
        var wire = MeshBuffer(parts: 1)
        var sign = MeshBuffer(parts: 1)
        var timber = MeshBuffer(parts: 1)
        var concrete = MeshBuffer(parts: 1)
        var glass = MeshBuffer(parts: 1)

        init(cells: [String: SignCell]) { self.cells = cells }

        mutating func append(to out: inout Output) {
            let parts: [(MeshBuffer, PropPart)] = [
                (stone, .masonry), (galvanised, .galvanised), (dark, .darkMetal), (chain, .chainLink), (net, .shadeNet),
                (white, .whitePaint), (wire, .wire), (sign, .signFace), (timber, .darkWood), (concrete, .concrete),
                (glass, .lampGlass),
            ]
            for (m, part) in parts where !m.isEmpty { appendParts(&out.props, m, map: [0: part.rawValue]) }
        }

        /// `m` coloured by the plain sign-atlas cell `key` (`paint.*`),
        /// appended to the sign face.
        mutating func paint(_ m: MeshBuffer, _ key: String) {
            var m = m
            let (u, v) = cells[key]?.centre ?? (0, 0)
            for i in 0..<m.vertexCount { m.uvs[2 * i] = u; m.uvs[2 * i + 1] = v }
            sign.append(m, sx: 1, sy: 1, sz: 1, yaw: 0, tx: 0, ty: 0, tz: 0)
        }

        /// A masonry quad, corners counter-clockwise or not (it is wound to
        /// face the normals' mean): texcoord 0 = (`stone` code × 1024 +
        /// metres along the wall, height above the wall's foot), read by
        /// `WorldShaders.masonrySurface`.
        mutating func stoneQuad(_ p: [SIMD3<Float>], normals n: [SIMD3<Float>], along: [Double], foot: [Float],
                                stone: CourseArt.Stone) {
            let base = (along.min() ?? 0) - (along.min() ?? 0).truncatingRemainder(dividingBy: 1000)
            let code = Float(stone.rawValue) * 1024
            let first = UInt32(self.stone.vertexCount)
            for k in 0..<4 {
                let q = p[k], nn = n[k]
                self.stone.vertex(q.x, q.y, q.z, nn.x, nn.y, nn.z, code + Float(along[k] - base), q.y - foot[k])
            }
            let mean = n[0] + n[1] + n[2] + n[3]
            if simd_dot(simd_cross(p[1] - p[0], p[2] - p[0]), mean) >= 0 {
                self.stone.quad(first, first + 1, first + 2, first + 3)
            } else {
                self.stone.quad(first, first + 3, first + 2, first + 1)
            }
        }

        /// A box on the masonry part (`stone`): centre, axes along and
        /// across (horizontal) and half sizes; `along0` starts its pattern.
        mutating func stoneBox(_ c: SIMD3<Float>, along a: SIMD3<Float>, half h: SIMD3<Float>, stone: CourseArt.Stone,
                               along0: Double = 0, footY: Float? = nil) {
            let up = SIMD3<Float>(0, 1, 0)
            let b = simd_normalize(simd_cross(up, a))
            let foot = footY ?? (c.y - h.y)
            func P(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { c + a * (x * h.x) + up * (y * h.y) + b * (z * h.z) }
            let ax = Double(h.x), bz = Double(h.z)
            // Sides: +b, -b (along the length), +a, -a (the ends), the top.
            stoneQuad([P(-1, -1, 1), P(1, -1, 1), P(1, 1, 1), P(-1, 1, 1)], normals: Array(repeating: b, count: 4),
                      along: [along0, along0 + 2 * ax, along0 + 2 * ax, along0], foot: Array(repeating: foot, count: 4), stone: stone)
            stoneQuad([P(1, -1, -1), P(-1, -1, -1), P(-1, 1, -1), P(1, 1, -1)], normals: Array(repeating: -b, count: 4),
                      along: [along0, along0 + 2 * ax, along0 + 2 * ax, along0], foot: Array(repeating: foot, count: 4), stone: stone)
            stoneQuad([P(1, -1, 1), P(1, -1, -1), P(1, 1, -1), P(1, 1, 1)], normals: Array(repeating: a, count: 4),
                      along: [along0, along0 + 2 * bz, along0 + 2 * bz, along0], foot: Array(repeating: foot, count: 4), stone: stone)
            stoneQuad([P(-1, -1, -1), P(-1, -1, 1), P(-1, 1, 1), P(-1, 1, -1)], normals: Array(repeating: -a, count: 4),
                      along: [along0, along0 + 2 * bz, along0 + 2 * bz, along0], foot: Array(repeating: foot, count: 4), stone: stone)
            stoneQuad([P(-1, 1, 1), P(1, 1, 1), P(1, 1, -1), P(-1, 1, -1)], normals: Array(repeating: up, count: 4),
                      along: [along0, along0 + 2 * ax, along0 + 2 * ax, along0], foot: Array(repeating: foot, count: 4), stone: stone)
        }
    }

    // MARK: - Walls at the edge

    /// The walls along the carriageway edge, side by side, in runs of one
    /// look: from the CTR's walls that run along the edge (their crests)
    /// and `CourseArt.masonry`.
    struct EdgeWalls {
        struct Slot: Equatable {
            var stone: CourseArt.Stone
            var top: CourseArt.Railing?
            var coping: Bool
            var retains: Bool
            var offset: Double
            var height: ClosedRange<Double>
            /// The surveyed crest, when the CTR has the wall.
            var crest: Double?
            /// A wall holding the road up, its face to the drop.
            var holdsRoad: Bool
            /// Dry-stone terraces step up the bank behind it
            /// (`CourseArt.Masonry.terraces`): its top is the first tread.
            var terraced = false

            func sameRun(_ o: Slot) -> Bool {
                stone == o.stone && top == o.top && coping == o.coping && retains == o.retains
                    && abs(offset - o.offset) < 0.01 && holdsRoad == o.holdsRoad && (crest == nil) == (o.crest == nil)
                    && terraced == o.terraced
            }
        }

        struct Run {
            var side: Double
            var s0: Double
            var slots: [Slot]
        }

        /// Metres of route per slot.
        static let step = 1.0
        var runs: [Run] = []
        /// Indices of the CTR walls' points taken as edge walls, by wall.
        var consumed: [Int: Set<Int>] = [:]

        init(corridor: RoadCorridor, walls: [SceneryFile.Wall], sideRoads: RoadBuilder.SideRoadMask) {
            let n = Int(corridor.route.length / Self.step) + 1
            var slots: [[Slot?]] = [Array(repeating: nil, count: n), Array(repeating: nil, count: n)]
            func index(_ side: Double) -> Int { side < 0 ? 0 : 1 }
            // The CTR's retaining walls, dividing walls and parapets within
            // a few metres of the edge, along it: their crest by slot.
            for (w, wall) in walls.enumerated() where ["retaining", "masonry", "parapet"].contains(wall.kind) {
                let pts = Self.resampled(wall.points, every: 0.5)
                var hits: [(slot: Int, side: Double, crest: Double, holds: Bool, foot: Bool, k: Int)] = []
                // Points with the ground 1.2 m behind them up near the crest:
                // a bank the wall holds up.
                var banked = 0
                for (k, q) in pts.enumerated() {
                    let near = corridor.coarse.query(east: q.x, north: q.y)
                    guard near.dist < 12, near.s > 1, near.s < corridor.route.length - 1 else { continue }
                    let st = corridor.station(at: near.s)
                    let lat = (q.x - st.east) * st.rightE + (q.y - st.north) * st.rightN
                    let side: Double = lat >= 0 ? 1 : -1
                    let beyond = abs(lat) - st.reach(side)
                    guard beyond > -0.6, beyond < 2.8 else { continue }
                    let road = corridor.roadHeight(st, lateral: side * st.reach(side))
                    let behind = st.point(lateral: side * (abs(lat) + 1.2))
                    let groundBehind = Double(corridor.terrain.height(east: behind.east, north: behind.north))
                    if groundBehind > q.z - 0.6 { banked += 1 }
                    // A crest at the road's level holds the road up only where
                    // the ground falls away behind it; under a rising bank it
                    // is a low wall at the bank's foot (Via Val d'Olivi, route
                    // s 4090-4160: crest +0.0..0.6 m, the LiDAR bank +2-4 m
                    // within 3 m), whose face a wall holding the road up buried.
                    let low = q.z - road < 0.35
                    let holds = low && groundBehind < road - 0.3
                    hits.append((Int(near.s / Self.step), side, q.z, holds, low && !holds, k))
                }
                // A few stray points along the edge are not a wall along it.
                guard hits.count >= 6 else { continue }
                // The map's dividing walls and parapets (L3169) stand free, with
                // a back, unless the ground behind most of them is up at their
                // crest: then, like its retaining walls, they hold up a bank.
                let free = wall.kind != "retaining" && banked * 2 < hits.count
                for h in hits {
                    let i = index(h.side)
                    // (At a bank's foot: the surveyed crest, a low wall.)
                    var slot = slots[i][h.slot] ?? Slot(stone: .honeyRubble, top: nil, coping: true, retains: !h.holds && !free,
                                                        offset: 0.14, height: h.foot ? 0.3...1.2 : 0.6...8, crest: nil,
                                                        holdsRoad: h.holds)
                    slot.crest = max(slot.crest ?? -.infinity, h.crest)
                    slots[i][h.slot] = slot
                    consumed[w, default: []].insert(h.k)
                }
            }
            // The hand-placed walls: their look over the CTR's line, or the
            // whole wall where the CTR has none.
            for m in corridor.art.masonry {
                let i = index(m.side)
                var k = max(0, Int((m.span.lowerBound / Self.step).rounded()))
                while Double(k) * Self.step < m.span.upperBound, k < n {
                    let crest = slots[i][k]?.crest
                    // A parapet over a wall that holds the road up keeps the
                    // CTR's wall below it as well.
                    slots[i][k] = Slot(stone: m.look, top: m.top, coping: m.coping, retains: m.retains, offset: m.offset,
                                       height: m.height, crest: m.retains ? crest : nil, holdsRoad: false,
                                       terraced: m.terraces > 0)
                    k += 1
                }
            }
            // No wall across a side road's mouth. A lane that runs down
            // alongside, below the road, is no mouth: the parapet between
            // them stays (route s 977-1000, right: OSM's lane to the houses
            // below lies 1.5-2.5 m under the road within 1.5 m of the edge
            // in the LiDAR, and the 2024 frame at look s 684 has the rail
            // and the low concrete wall at the edge all along it).
            for side in [-1.0, 1.0] {
                let i = index(side)
                for k in 0..<n where slots[i][k] != nil {
                    let s = Double(k) * Self.step + Self.step / 2
                    let st = corridor.station(at: s)
                    let p = st.point(lateral: side * (st.reach(side) + 0.5))
                    let mouth = corridor.junctions.contains { $0.side == side && abs($0.s - s) < $0.width / 2 + 0.6 }
                    guard mouth || sideRoads.covers(east: p.east, north: p.north, margin: 0.3) else { continue }
                    let o = st.point(lateral: side * (st.reach(side) + 1.5))
                    let road = corridor.roadHeight(st, lateral: side * st.reach(side))
                    let below = Double(corridor.terrain.height(east: o.east, north: o.north)) < road - 0.8
                    if mouth || !below { slots[i][k] = nil }
                }
            }
            // Runs of one look; none under 3 m (a stub left between two
            // lanes' mouths, or a few stray points of the map's).
            for side in [-1.0, 1.0] {
                var current: Run?
                for (k, slot) in slots[index(side)].enumerated() {
                    if let slot, let run = current, let last = run.slots.last, last.sameRun(slot) {
                        current!.slots.append(slot)
                    } else {
                        if let run = current, run.slots.count >= 3 { runs.append(run) }
                        current = slot.map { Run(side: side, s0: Double(k) * Self.step, slots: [$0]) }
                    }
                }
                if let run = current, run.slots.count >= 3 { runs.append(run) }
            }
        }

        /// The polyline's points (east, north, crest) every `every` metres
        /// or closer, its own vertices kept.
        static func resampled(_ raw: [[Double]], every: Double) -> [SIMD3<Double>] {
            let pts = raw.compactMap { $0.count >= 3 ? SIMD3($0[0], $0[1], $0[2]) : nil }
            guard pts.count >= 2 else { return pts }
            var out: [SIMD3<Double>] = []
            for i in 0..<(pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                let n = max(1, Int((simd_distance(SIMD2(a.x, a.y), SIMD2(b.x, b.y)) / every).rounded(.up)))
                for k in 0..<n { out.append(a + (b - a) * (Double(k) / Double(n))) }
            }
            out.append(pts[pts.count - 1])
            return out
        }
    }

    /// One run of wall at the edge: its road face (or, for a wall holding
    /// the road up, its face to the drop) from below the road to its top,
    /// the top or a concrete coping, a parapet's back, the ends, and what
    /// stands on it.
    static func buildEdgeWall(_ run: EdgeWalls.Run, corridor: RoadCorridor, kit: inout RoadsideKit) {
        let side = run.side
        let first = run.slots[0]
        // Rendered retaining walls are sprayed concrete over the cut bank,
        // leaning back about 1 in 3 (the 2024 frame at 1840 m): a wide top
        // for the lean.
        let sloped = first.stone == .render && first.retains && !first.holdsRoad
        // Under terraces its top is the first tread, back to the first tier.
        let thickness = sloped ? 2.4 : first.terraced ? fasceFirstTread : first.retains || first.holdsRoad ? 0.55 : 0.3
        let ds = EdgeWalls.step
        var rnd = WorldRandom(run.s0, side, salt: 71)
        struct Section {
            var face: SIMD2<Double>
            var back: SIMD2<Double>
            var toRoad: SIMD3<Float>
            var road: Double
            var foot: Double
            var top: Double
            var backFoot: Double
            /// The face's top, set back by the wall's batter.
            var faceTop: SIMD2<Double> = .zero
            var s = 0.0
            /// On a bend tighter than 40 m.
            var bend = false
        }
        var secs: [Section] = []
        for j in 0...run.slots.count {
            let slot = run.slots[min(j, run.slots.count - 1)]
            let s = min(run.s0 + Double(j) * ds, corridor.route.length)
            let st = corridor.station(at: s)
            let reach = st.reach(side)
            // A thinner wall round the inside of a tight bend, so its back
            // doesn't fold.
            var thick = thickness
            if st.curvature * side > 0 {
                let room = 1 / max(abs(st.curvature), 1e-6) - reach - slot.offset
                thick = min(thick, max(0.12, room * 0.6))
            }
            let faceLat = side * (reach + slot.offset), backLat = side * (reach + slot.offset + thick)
            let f = st.point(lateral: faceLat), b = st.point(lateral: backLat)
            let road = corridor.roadHeight(st, lateral: side * reach)
            let groundFace = Double(corridor.terrain.height(east: f.east, north: f.north))
            let groundBack = Double(corridor.terrain.height(east: b.east, north: b.north))
            var top: Double
            var foot = min(road, groundFace) - 0.35
            if slot.holdsRoad {
                // Its face is the far one, down to the ground below it.
                let o = st.point(lateral: side * (reach + slot.offset + thick + 0.8))
                top = max(road + 0.04, slot.crest ?? road)
                foot = min(Double(corridor.terrain.height(east: o.east, north: o.north)), top - 0.4) - 0.3
            } else if slot.retains {
                if slot.terraced {
                    // (Before the map's crest: along these spans the CTR's
                    // dividing walls at the edge carry the hedge's or the
                    // first tier's height, 2.5-3.2 m, which hid the tiers.)
                    top = fasceRoadWallTop(corridor, st, side: side, offset: slot.offset, height: slot.height)
                } else if let crest = slot.crest, crest > road + slot.height.lowerBound - 0.3 {
                    // The surveyed crest, up to the photos' heights where a
                    // hand-placed span gives them; a crest well under them is
                    // something else on the map (the start ramp's 5-6 m wall
                    // over a low dividing wall's line), and the bank decides.
                    top = min(max(crest, road + 0.3), road + slot.height.upperBound)
                } else {
                    var bank = -Double.infinity
                    for d in [0.4, 1.2, 2.5] {
                        let q = st.point(lateral: side * (reach + slot.offset + thick + d))
                        bank = max(bank, Double(corridor.terrain.height(east: q.east, north: q.north)))
                    }
                    let rise = bank - road
                    // Where the ground falls away instead (a side read wrong
                    // in a photo), a low wall rather than a screen over the view.
                    top = road + (rise < 0 ? min(slot.height.lowerBound, 0.8)
                                           : min(max(rise + 0.05, slot.height.lowerBound), slot.height.upperBound))
                }
            } else {
                // A parapet: its designed height, or the map's crest.
                top = slot.crest.map { min(max($0, road + 0.4), road + 3) } ?? road + slot.height.upperBound
            }
            top = min(top, road + 9)
            let toRoad = SIMD3<Float>(Float(-side * st.rightE), 0, Float(side * st.rightN))
            secs.append(Section(face: SIMD2(f.east, f.north), back: SIMD2(b.east, b.north), toRoad: toRoad, road: road,
                                foot: foot, top: top, backFoot: min(groundBack, road) - 0.35, s: s,
                                bend: abs(st.curvature) > 1 / 40))
        }
        // A retaining wall's top (the bank's, or the map's crest) eased over
        // about 9 m (over 5 m the CTR's crests still rose and fell a metre
        // every 20 m like a wave), a few centimetres of unevenness in rubble.
        if first.retains, secs.count > 4 {
            let raw = secs.map(\.top)
            for j in secs.indices {
                let lo = max(0, j - 4), hi = min(secs.count - 1, j + 4)
                secs[j].top = raw[lo...hi].reduce(0, +) / Double(hi - lo + 1)
            }
        }
        let rubble = [CourseArt.Stone.honeyRubble, .greyRubble, .dryStone].contains(first.stone)
        if rubble && !first.coping {
            for j in secs.indices { secs[j].top += Double(rnd.range(-0.04, 0.04)) }
        }
        // Sections every 2 m where the wall runs straight (each is a face, a
        // top or coping, perhaps a back and a railing's rails: the edge walls
        // were the roadside's largest share of the props), every metre round
        // bends and at the ends.
        let all = secs
        secs = all.indices.filter { $0 % 2 == 0 || $0 == all.count - 1 || all[$0].bend }.map { all[$0] }
        // Stone retaining walls lean back into the bank, about 1 in 12
        // (look.md section 3: "slightly battered"); concrete stands plumb.
        let battered = first.retains && !first.holdsRoad
            && [CourseArt.Stone.honeyRubble, .greySquared, .dryStone, .greyRubble].contains(first.stone)
        let batter = sloped ? 0.33 : battered ? 0.08 : 0.0
        for j in secs.indices {
            let c = secs[j]
            let lean = min(batter * max(c.top - c.road, 0), simd_distance(c.face, c.back) * 0.6)
            secs[j].faceTop = c.face + simd_normalize(c.back - c.face) * lean
        }
        func P(_ p: SIMD2<Double>, _ y: Double) -> SIMD3<Float> { SIMD3(Float(p.x), Float(y), Float(-p.y)) }
        let up = SIMD3<Float>(0, 1, 0)
        let outward: Float = first.holdsRoad ? -1 : 1
        var along = Double(rnd.range(0, 300))
        let copeH = 0.1, overhang = 0.04
        for j in 0..<(secs.count - 1) {
            let a = secs[j], b = secs[j + 1]
            let len = simd_distance(a.face, b.face)
            guard len > 0.02 else { continue }
            let a1 = along + len
            let fa = first.holdsRoad ? a.back : a.face, fb = first.holdsRoad ? b.back : b.face
            let ta = first.holdsRoad ? a.back : a.faceTop, tb = first.holdsRoad ? b.back : b.faceTop
            let lift = up * Float(batter)
            let na = simd_normalize(a.toRoad * outward + lift), nb = simd_normalize(b.toRoad * outward + lift)
            let topA = a.top, topB = b.top
            // The face.
            kit.stoneQuad([P(fa, a.foot), P(fb, b.foot), P(tb, topB), P(ta, topA)], normals: [na, nb, nb, na],
                          along: [along, a1, a1, along], foot: [Float(a.foot), Float(b.foot), Float(b.foot), Float(a.foot)],
                          stone: first.stone)
            // The top, or the coping over it.
            if first.coping {
                // Proud of the road face by 4 cm; of a parapet's back, or the
                // drop side of a wall holding the road up, too.
                let ra = SIMD2(Double(a.toRoad.x), Double(-a.toRoad.z)), rb = SIMD2(Double(b.toRoad.x), Double(-b.toRoad.z))
                let backOver = first.retains && !first.holdsRoad ? 0 : overhang
                let ca = a.faceTop + ra * overhang, cb = b.faceTop + rb * overhang
                let ba = a.back - ra * backOver, bb = b.back - rb * backOver
                // Heights from the wall's foot, as on its face: the shader's
                // damp, splash and occlusion at a foot are for the bottom of
                // the wall, and turned a coping measured from itself black.
                let f0 = [Float(a.foot), Float(b.foot), Float(b.foot), Float(a.foot)]
                kit.stoneQuad([P(ca, topA - 0.02), P(cb, topB - 0.02), P(cb, topB + copeH), P(ca, topA + copeH)],
                              normals: [a.toRoad, b.toRoad, b.toRoad, a.toRoad], along: [along, a1, a1, along], foot: f0,
                              stone: .coping)
                kit.stoneQuad([P(ca, topA + copeH), P(cb, topB + copeH), P(bb, topB + copeH), P(ba, topA + copeH)],
                              normals: [up, up, up, up], along: [along, a1, a1, along], foot: f0, stone: .coping)
                if backOver > 0 {
                    kit.stoneQuad([P(ba, topA - 0.02), P(bb, topB - 0.02), P(bb, topB + copeH), P(ba, topA + copeH)],
                                  normals: [-a.toRoad, -b.toRoad, -b.toRoad, -a.toRoad], along: [along, a1, a1, along],
                                  foot: f0, stone: .coping)
                }
            } else {
                kit.stoneQuad([P(a.faceTop, topA), P(b.faceTop, topB), P(b.back, topB), P(a.back, topA)], normals: [up, up, up, up],
                              along: [along, a1, a1, along], foot: [Float(a.foot), Float(b.foot), Float(b.foot), Float(a.foot)],
                              stone: first.stone)
            }
            // A parapet's back, down to the ground behind it; a wall
            // holding the road up shows the road its top only.
            if !first.retains && !first.holdsRoad {
                kit.stoneQuad([P(a.back, a.backFoot), P(b.back, b.backFoot), P(b.back, topB), P(a.back, topA)],
                              normals: [-na, -nb, -nb, -na], along: [along, a1, a1, along],
                              foot: [Float(a.backFoot), Float(b.backFoot), Float(b.backFoot), Float(a.backFoot)], stone: first.stone)
            }
            along = a1
        }
        // The ends.
        for (j, sign) in [(0, -1.0), (secs.count - 1, 1.0)] {
            let c = secs[j]
            let st = corridor.station(at: c.s)
            let n = SIMD3<Float>(Float(st.dirE * sign), 0, Float(-st.dirN * sign))
            let top = c.top + (first.coping ? copeH : 0)
            kit.stoneQuad([P(c.face, c.foot), P(c.back, c.foot), P(c.back, top), P(c.faceTop, top)], normals: [n, n, n, n],
                          along: [0, 0.5, 0.5, 0], foot: [Float(c.foot), Float(c.foot), Float(c.foot), Float(c.foot)],
                          stone: first.stone)
        }
        // What stands on it: along its top, near the road face of a
        // retaining wall, in the middle of a parapet.
        // Shade net stands on the bank a metre back from a retaining wall's
        // crest, on the ground there (the 2023 frame at 2150 m: on posts
        // behind the wall, the shrubs and the fig on the crest in front).
        if let rail = first.top {
            let net = rail == .shadeNet && first.retains && !first.holdsRoad
            let inset = net ? 1.1 : first.retains ? 0.14 : thickness / 2
            var line: [(p: SIMD2<Double>, y: Double)] = []
            for c in secs {
                let dir = simd_normalize(c.back - c.face)
                let p = c.faceTop + dir * inset
                // (Its foot hidden behind the crest where the bank there is low.)
                let y = net ? max(Double(corridor.terrain.height(east: p.x, north: p.y)), c.top - 0.3) - 0.05
                    : c.top + (first.coping ? copeH : 0)
                line.append((p, y))
            }
            emitRailing(rail, line: line, side: side, kit: &kit)
        }
    }

    // MARK: - Terraces over the edge walls

    /// The scenery's house footprints as boxes, for keeping terraces out
    /// of them, and the CTR's own walls behind the edge along the terraced
    /// spans as points (`addWalls`).
    struct Footprints {
        var boxes: [(lo: SIMD2<Double>, hi: SIMD2<Double>)] = []

        init(scenery: SceneryFile?) {
            for b in scenery?.buildings ?? [] {
                let pts = b.ring.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }
                guard let first = pts.first else { continue }
                boxes.append(pts.reduce((lo: first, hi: first)) { (lo: pointwiseMin($0.lo, $1), hi: pointwiseMax($0.hi, $1)) })
            }
        }

        /// The map's walls within 15 m of the road along `spans`, less the
        /// points taken as edge walls: where the CTR surveyed a terrace or
        /// retaining wall behind the edge (route s 1008-1055, left: a 4-5 m
        /// terrace wall 2 m behind the road wall) the map's wall stands and
        /// no tier is laid through it.
        mutating func addWalls(_ walls: [SceneryFile.Wall], skip: [Int: Set<Int>], along spans: [CourseArt.Masonry],
                               corridor: RoadCorridor) {
            for (w, wall) in walls.enumerated() where wall.kind != "fence" {
                let taken = skip[w] ?? []
                for (k, q) in EdgeWalls.resampled(wall.points, every: 0.5).enumerated() where !taken.contains(k) {
                    let near = corridor.coarse.query(east: q.x, north: q.y)
                    guard near.dist < 15, spans.contains(where: { $0.span.contains(near.s) }) else { continue }
                    boxes.append((lo: SIMD2(q.x, q.y), hi: SIMD2(q.x, q.y)))
                }
            }
        }

        func contains(_ p: SIMD2<Double>, margin: Double) -> Bool {
            boxes.contains { p.x > $0.lo.x - margin && p.x < $0.hi.x + margin && p.y > $0.lo.y - margin && p.y < $0.hi.y + margin }
        }
    }

    /// The first tread: the wall at the edge (0.55 m) and a narrow ledge
    /// behind it, to the first tier's face.
    static let fasceFirstTread = 1.0
    /// Metres from one tier's face to the next. The 2024 frame at 1064 m
    /// has three or four faces stacked over the road wall, each in full
    /// view from the saddle: narrow treads under faces of a metre or so.
    /// (At 3 m, from the road the treads hid every face above the first.)
    static let fascePitch = 1.9

    /// The top of a wall at the edge with terraces behind it: the bank a
    /// little behind its face, within the span's heights. (The 1 m LiDAR
    /// smears the wall's own 1.5-2 m step over 2-3 m, so the bank further
    /// back, which the other walls follow, is the first tier's top and
    /// hid it.)
    static func fasceRoadWallTop(_ corridor: RoadCorridor, _ st: RoadCorridor.Station, side: Double, offset: Double,
                                 height: ClosedRange<Double>) -> Double {
        let reach = st.reach(side)
        let road = corridor.roadHeight(st, lateral: side * reach)
        let q = st.point(lateral: side * (reach + offset + 0.7))
        let bank = Double(corridor.terrain.height(east: q.east, north: q.north))
        return road + min(max(bank - road + 0.1, height.lowerBound), height.upperBound)
    }

    /// Tier `k` (0 the lowest) of the terraces behind `m`: its face and the
    /// back of its tread, metres beyond the carriageway edge (`st.reach`),
    /// wherever it is built.
    static func fasceTier(_ m: CourseArt.Masonry, k: Int) -> (face: Double, treadEnd: Double) {
        let face = m.offset + fasceFirstTread + Double(k) * fascePitch
        return (face, face + fascePitch * (k == m.terraces - 1 ? 0.85 : 1.0))
    }

    /// The terraces behind `m` at route `s`, as `buildFasce` lays them
    /// (before it keeps them off lanes, houses and other legs of the road):
    /// each tier's face and tread end beyond the edge, its face's foot and
    /// its tread's height. The bank's rise from the road wall's top to the
    /// ground at the back of the top tread is shared out evenly, tier by
    /// tier, 0.8 to 1.8 m a face (the 1 m LiDAR smooths the steps into a
    /// ramp; its rise is the survey's), up to 2.2 m where the bank humps
    /// over a tread: the treads level, the top one meeting the bank. Fewer tiers where the bank rises less, none where
    /// it does not rise 0.8 m.
    static func fasceTiers(_ m: CourseArt.Masonry, at s: Double, corridor: RoadCorridor)
        -> [(face: Double, treadEnd: Double, foot: Double, top: Double)] {
        guard m.terraces > 0 else { return [] }
        let st = corridor.station(at: s)
        let side = m.side, reach = st.reach(side)
        let road = corridor.roadHeight(st, lateral: side * reach)
        func ground(_ o: Double) -> Double {
            let p = st.point(lateral: side * (reach + o))
            return Double(corridor.terrain.height(east: p.east, north: p.north))
        }
        let wallTop = fasceRoadWallTop(corridor, st, side: side, offset: m.offset, height: m.height)
        var n = m.terraces, rise = 0.0
        while n > 0 {
            let back = fasceTier(m, k: n - 1).face + fascePitch * 0.85
            rise = (min(ground(back), road + 14) - wallTop) / Double(n)
            if rise >= 0.8 { break }
            n -= 1
        }
        guard n > 0 else { return [] }
        rise = min(rise, 1.8)
        var out: [(face: Double, treadEnd: Double, foot: Double, top: Double)] = []
        var below = wallTop
        for k in 0..<n {
            let face = fasceTier(m, k: k).face
            let treadEnd = face + fascePitch * (k == n - 1 ? 0.85 : 1.0)
            // Over the bank wherever it humps above the even share (else the
            // grass came up through the tread in front of the next face).
            let hump = max(ground(face + fascePitch * 0.5), ground(treadEnd - 0.2)) + 0.05
            let top = min(max(wallTop + rise * Double(k + 1), hump), below + 2.2)
            out.append((face, treadEnd, min(below, ground(face)) - 0.3, top))
            below = top
        }
        return out
    }

    /// Dry-stone terraces (fasce) stepping up the bank behind a wall at the
    /// edge (`CourseArt.Masonry.terraces`): the 2024 frames at look s 654,
    /// 684 and 1064 m show three or four bare, sun-bleached tiers stacked
    /// over the road wall, narrow grassy treads between them, houses on
    /// top. The wall at the edge is kept to its photo height and its top
    /// is the first tread (`fasceFirstTread`); each tier is a battered
    /// face 1.9 m further up the slope than the last and a level tread
    /// (`fasceTiers`). None across a lane, near a house or the map's own
    /// walls, over another leg of the road or round the inside of a bend
    /// tighter than their reach.
    static func buildFasce(_ m: CourseArt.Masonry, corridor: RoadCorridor, sideRoads: RoadBuilder.SideRoadMask,
                           houses: Footprints, kit: inout RoadsideKit) {
        struct Sec {
            var face: SIMD2<Double>
            var faceTop: SIMD2<Double>
            var tread: SIMD2<Double>
            var foot: Double
            var top: Double
            var toRoad: SIMD3<Float>
            var dir: SIMD3<Float>
        }
        let side = m.side
        func clear(_ p: SIMD2<Double>) -> Bool {
            !sideRoads.covers(east: p.x, north: p.y, margin: 0.5) && !houses.contains(p, margin: 1.5)
                && !(corridor.mainRoadDistance(east: p.x, north: p.y).map { $0.dist < $0.halfWidth + 0.9 } ?? false)
        }
        func P(_ p: SIMD2<Double>, _ y: Double) -> SIMD3<Float> { SIMD3(Float(p.x), Float(y), Float(-p.y)) }
        let up = SIMD3<Float>(0, 1, 0)
        var rnd = WorldRandom(m.span.lowerBound, side, salt: 47)
        func emit(_ secs: [Sec]) {
            guard secs.count >= 2 else { return }
            var along = Double(rnd.range(0, 300))
            for j in 0..<(secs.count - 1) {
                let a = secs[j], b = secs[j + 1]
                let len = simd_distance(a.face, b.face)
                guard len > 0.02 else { continue }
                let a1 = along + len
                let na = simd_normalize(a.toRoad + up * 0.12), nb = simd_normalize(b.toRoad + up * 0.12)
                let feet = [Float(a.foot), Float(b.foot), Float(b.foot), Float(a.foot)]
                kit.stoneQuad([P(a.face, a.foot), P(b.face, b.foot), P(b.faceTop, b.top), P(a.faceTop, a.top)],
                              normals: [na, nb, nb, na], along: [along, a1, a1, along], foot: feet, stone: .dryStone)
                kit.stoneQuad([P(a.faceTop, a.top), P(b.faceTop, b.top), P(b.tread, b.top), P(a.tread, a.top)],
                              normals: [up, up, up, up], along: [along, a1, a1, along], foot: feet, stone: .dryStone)
                // The capstones, 7 cm proud of the face: the line of shade under
                // them parts one tier from the next, as in the 2024 frame at
                // 1064 m (seen from the road the faces otherwise ran together
                // into one tall wall, the treads out of sight above the eye).
                let la = a.faceTop + SIMD2(Double(a.toRoad.x), Double(-a.toRoad.z)) * 0.07
                let lb = b.faceTop + SIMD2(Double(b.toRoad.x), Double(-b.toRoad.z)) * 0.07
                kit.stoneQuad([P(la, a.top - 0.08), P(lb, b.top - 0.08), P(lb, b.top + 0.02), P(la, a.top + 0.02)],
                              normals: [a.toRoad, b.toRoad, b.toRoad, a.toRoad], along: [along, a1, a1, along], foot: feet,
                              stone: .dryStone)
                kit.stoneQuad([P(a.faceTop, a.top - 0.08), P(b.faceTop, b.top - 0.08), P(lb, b.top - 0.08), P(la, a.top - 0.08)],
                              normals: [-up, -up, -up, -up], along: [along, a1, a1, along], foot: feet, stone: .dryStone)
                kit.stoneQuad([P(la, a.top + 0.02), P(lb, b.top + 0.02), P(b.faceTop, b.top + 0.02), P(a.faceTop, a.top + 0.02)],
                              normals: [up, up, up, up], along: [along, a1, a1, along], foot: feet, stone: .dryStone)
                along = a1
            }
            for (c, sign) in [(secs[0], Float(-1)), (secs[secs.count - 1], Float(1))] {
                let n = c.dir * sign
                kit.stoneQuad([P(c.face, c.foot), P(c.tread, c.foot), P(c.tread, c.top), P(c.faceTop, c.top)],
                              normals: [n, n, n, n], along: [0, 0.6, 0.6, 0], foot: Array(repeating: Float(c.foot), count: 4),
                              stone: .dryStone)
            }
        }
        let end = min(m.span.upperBound, corridor.route.length - 1)
        var pieces = [[Sec]](repeating: [], count: m.terraces)
        var s = max(m.span.lowerBound, 1)
        while s <= end {
            let st = corridor.station(at: s)
            let reach = st.reach(side)
            let tiers = fasceTiers(m, at: s, corridor: corridor)
            let toRoad = SIMD3<Float>(Float(-side * st.rightE), 0, Float(side * st.rightN))
            let back = SIMD2(-Double(toRoad.x), Double(toRoad.z))
            for k in 0..<m.terraces {
                var sec: Sec?
                if k < tiers.count {
                    let t = tiers[k]
                    let f = st.point(lateral: side * (reach + t.face)), e = st.point(lateral: side * (reach + t.treadEnd))
                    let face = SIMD2(f.east, f.north), tread = SIMD2(e.east, e.north)
                    // Round the inside of a bend tighter than the tier's reach
                    // the offset line would fold back on itself.
                    let folds = st.curvature * side > 0 && 1 / max(abs(st.curvature), 1e-6) < reach + t.treadEnd
                    if !folds, clear(face), clear(tread) {
                        // Battered about 1 in 8, the face's top set back.
                        sec = Sec(face: face, faceTop: face + back * (0.12 * (t.top - t.foot - 0.3)), tread: tread,
                                  foot: t.foot, top: t.top, toRoad: toRoad, dir: SIMD3(Float(st.dirE), 0, Float(-st.dirN)))
                    }
                }
                if let sec {
                    pieces[k].append(sec)
                } else {
                    emit(pieces[k])
                    pieces[k] = []
                }
            }
            s += abs(st.curvature) > 1 / 40 ? 1 : 2
        }
        for piece in pieces { emit(piece) }
    }
    // MARK: - The map's walls and terraces

    /// The CTR's walls away from the edge, where they stand: retaining
    /// walls and terraces as a face to their lower side and a top (dry
    /// stone for the terraces, honey sandstone for the rest), dividing
    /// walls and parapets standing free, fences as chain-link. Out to 250 m
    /// from the route for terraces, 120 m for the rest and 60 m for fences
    /// on high (`RivieraDetail`), coarser from 30 m and again from 90 m.
    static func buildMapWalls(_ walls: [SceneryFile.Wall], skip: [Int: Set<Int>], corridor: RoadCorridor,
                              kit: inout RoadsideKit, tier: RivieraDetail = .high) {
        let terrain = corridor.terrain
        func ground(_ p: SIMD2<Double>) -> Double { Double(terrain.height(east: p.x, north: p.y)) }
        func P(_ p: SIMD2<Double>, _ y: Double) -> SIMD3<Float> { SIMD3(Float(p.x), Float(y), Float(-p.y)) }
        let up = SIMD3<Float>(0, 1, 0)
        for (w, wall) in walls.enumerated() {
            let terrace = wall.kind == "terrace"
            let reachM = terrace ? tier.terraceWallM : tier.otherWallM
            let fine = EdgeWalls.resampled(wall.points, every: 1.5)
            guard fine.count >= 2 else { continue }
            let mid = fine[fine.count / 2]
            let near = corridor.coarse.query(east: mid.x, north: mid.y)
            guard near.dist < reachM else { continue }
            // Points every 1.5 m near the road, 3 m from 30 m (where a step
            // in a wall's foot or top is under a pixel), 6 m beyond 90 m.
            let pts = near.dist > 90 ? EdgeWalls.resampled(wall.points, every: 6)
                : near.dist > 30 ? EdgeWalls.resampled(wall.points, every: 3) : fine
            // Points taken as edge walls, and any on the carriageway, split it.
            let taken = skip[w] ?? []
            var pieces: [[SIMD3<Double>]] = [[]]
            let raw = EdgeWalls.resampled(wall.points, every: 0.5)
            for q in pts {
                let onRoad = corridor.mainRoadDistance(east: q.x, north: q.y).map { $0.dist < $0.halfWidth + 0.4 } ?? false
                // Nearest raw point's index: taken ones were the edge's.
                let edge = !taken.isEmpty && raw.indices.contains { taken.contains($0) && simd_distance(raw[$0], q) < 0.6 }
                if onRoad || edge {
                    if !(pieces.last?.isEmpty ?? true) { pieces.append([]) }
                } else {
                    pieces[pieces.count - 1].append(q)
                }
            }
            var rnd = WorldRandom(mid.x, mid.y, salt: 93)
            // What the split leaves of a wall shorter than 3 m is a stub (a
            // lone metre of masonry at route s 4100, left, between the edge
            // wall and the road): not built. A short wall left whole stays.
            let split = pieces.count > 1 || !taken.isEmpty
            func length(_ p: [SIMD3<Double>]) -> Double {
                zip(p, p.dropFirst()).reduce(0) { $0 + simd_distance(SIMD2($1.0.x, $1.0.y), SIMD2($1.1.x, $1.1.y)) }
            }
            for piece in pieces where piece.count >= 2 && (!split || length(piece) >= 3) {
                if wall.kind == "fence" {
                    guard near.dist < tier.fenceM else { continue }
                    let line = piece.map { (p: SIMD2($0.x, $0.y), y: ground(SIMD2($0.x, $0.y))) }
                    emitRailing(.chainLink(green: rnd.unit() < 0.4), line: line, side: 1, kit: &kit)
                    continue
                }
                let free = wall.kind == "masonry" || wall.kind == "parapet"
                let stone: CourseArt.Stone = terrace ? .dryStone : (free ? .greyRubble : .honeyRubble)
                let thick = free ? 0.32 : 0.45
                var along = Double(rnd.range(0, 300))
                for k in 0..<(piece.count - 1) {
                    let a3 = piece[k], b3 = piece[k + 1]
                    let a = SIMD2(a3.x, a3.y), b = SIMD2(b3.x, b3.y)
                    let len = simd_distance(a, b)
                    guard len > 0.05 else { continue }
                    let d = (b - a) / len
                    let nrm = SIMD2(d.y, -d.x)
                    // The face looks down the slope.
                    let plus = ground(a + nrm) + ground(b + nrm), minus = ground(a - nrm) + ground(b - nrm)
                    let low: Double = plus < minus ? 1 : -1
                    let face = nrm * low
                    let lowA = ground(a + face * 0.7), lowB = ground(b + face * 0.7)
                    let highA = ground(a - face * 0.9), highB = ground(b - face * 0.9)
                    var topA = max(a3.z, lowA + 0.35), topB = max(b3.z, lowB + 0.35)
                    if free {
                        let h = min(max(wall.heightM ?? (wall.kind == "parapet" ? 0.9 : 1.6), 0.5), 3)
                        topA = max(a3.z, max(lowA, highA) + 0.4, min(lowA, highA) + h)
                        topB = max(b3.z, max(lowB, highB) + 0.4, min(lowB, highB) + h)
                    } else {
                        // Never far above the ground it holds up.
                        topA = min(topA, highA + 0.6); topB = min(topB, highB + 0.6)
                    }
                    guard topA - lowA < 9, topB - lowB < 9 else { continue }
                    let footA = min(lowA, a3.z) - 0.3, footB = min(lowB, b3.z) - 0.3
                    let backA = a - face * thick, backB = b - face * thick
                    let n3 = SIMD3<Float>(Float(face.x), 0, Float(-face.y))
                    let a1 = along + len
                    let fa = [Float(footA), Float(footB), Float(footB), Float(footA)]
                    kit.stoneQuad([P(a, footA), P(b, footB), P(b, topB), P(a, topA)], normals: [n3, n3, n3, n3],
                                  along: [along, a1, a1, along], foot: fa, stone: stone)
                    kit.stoneQuad([P(a, topA), P(b, topB), P(backB, topB), P(backA, topA)], normals: [up, up, up, up],
                                  along: [along, a1, a1, along], foot: fa, stone: stone)
                    if free {
                        let gA = ground(backA) - 0.3, gB = ground(backB) - 0.3
                        kit.stoneQuad([P(backA, gA), P(backB, gB), P(backB, topB), P(backA, topA)],
                                      normals: [-n3, -n3, -n3, -n3], along: [along, a1, a1, along],
                                      foot: [Float(gA), Float(gB), Float(gB), Float(gA)], stone: stone)
                    }
                    along = a1
                }
            }
        }
    }

    // MARK: - Guardrail

    /// The W-beam's cross-section, metres: (towards the road from the
    /// back of the beam, up from its middle), top to bottom. 310 mm high,
    /// two waves 83 mm deep (the "doppia onda", EN 1317 N2/H1).
    static let wBeam: [SIMD2<Float>] = [
        SIMD2(0.0, 0.155), SIMD2(0.015, 0.148), SIMD2(0.058, 0.112), SIMD2(0.083, 0.076), SIMD2(0.075, 0.044),
        SIMD2(0.032, 0.012), SIMD2(0.022, 0.0), SIMD2(0.032, -0.012), SIMD2(0.075, -0.044), SIMD2(0.083, -0.076),
        SIMD2(0.058, -0.112), SIMD2(0.015, -0.148), SIMD2(0.0, -0.155),
    ]

    /// Galvanised W-beam guardrail on C-posts 2.25 m apart, the rail's top
    /// 0.75 m over the road, on spacer blocks 0.15 m in front of the posts;
    /// at each end the beam turns down to the ground and away from the
    /// road (a buried terminal). Broken at side roads.
    static func buildGuardrails(corridor: RoadCorridor, sideRoads: RoadBuilder.SideRoadMask, kit: inout RoadsideKit) {
        // The cross-section's normals, towards the road side.
        let prof = wBeam
        var normals: [SIMD2<Float>] = []
        for k in prof.indices {
            let a = prof[max(k - 1, 0)], b = prof[min(k + 1, prof.count - 1)]
            let t = simd_normalize(b - a)
            normals.append(SIMD2(-t.y, t.x).x >= 0 ? SIMD2(-t.y, t.x) : SIMD2(t.y, -t.x))
        }
        for run in corridor.art.guardrails {
            let side = run.side
            for samples in vergeSamples(corridor: corridor, span: run.span, side: side, offset: run.offset, step: 0.75,
                                        sideRoads: sideRoads) where samples.count >= 5 {
                // The beam's sections every 1.5 m where it runs straight (a
                // 13-point section is 24 triangles a step), every 0.75 m at
                // its ends and round bends tighter than 40 m.
                let piece = samples.indices.filter { k in
                    let s = samples[k].s
                    return k % 2 == 0 || k == samples.count - 1 || s - samples[0].s < 3.5 || samples.last!.s - s < 3.5
                        || abs(corridor.station(at: s).curvature) > 1 / 40
                }.map { samples[$0] }
                let total = piece.last!.s - piece.first!.s
                var rails: [(c: SIMD3<Float>, toRoad: SIMD3<Float>)] = []
                for q in piece {
                    let st = corridor.station(at: q.s)
                    let reach = st.reach(side)
                    let toRoad = SIMD3<Float>(Float(-side * st.rightE), 0, Float(side * st.rightN))
                    let road = corridor.roadHeight(st, lateral: side * reach)
                    // The ends: down to 0.2 m over the ground, 0.35 m away from the road.
                    let e = min(q.s - piece.first!.s, piece.last!.s - q.s)
                    let tail = 1 - smoothstepD(0, min(3.0, total / 3), e)
                    let lat = side * (reach + run.offset - 0.17 + 0.35 * tail)
                    let p = st.point(lateral: lat)
                    let ground = Double(corridor.terrain.height(east: p.east, north: p.north))
                    let y = (road + 0.6) * (1 - tail) + (min(ground, road) + 0.2) * tail
                    rails.append((SIMD3(Float(p.east), Float(y), Float(-p.north)), toRoad))
                }
                let first = UInt32(kit.galvanised.vertexCount)
                let up = SIMD3<Float>(0, 1, 0)
                for r in rails {
                    for (k, q) in prof.enumerated() {
                        let v = r.c + r.toRoad * q.x + up * q.y
                        let nn = r.toRoad * normals[k].x + up * normals[k].y
                        kit.galvanised.vertex(v.x, v.y, v.z, nn.x, nn.y, nn.z, 0, 0)
                    }
                }
                let w = UInt32(prof.count)
                for j in 0..<UInt32(rails.count - 1) {
                    for k in 0..<(w - 1) {
                        let a = first + j * w + k, b = a + w
                        // Wound so the side facing the road is the front.
                        if side > 0 { kit.galvanised.quad(a, b, b + 1, a + 1) } else { kit.galvanised.quad(a, a + 1, b + 1, b) }
                    }
                }
                // Posts and spacers.
                var s = piece.first!.s + 0.6
                while s < piece.last!.s - 0.3 {
                    let st = corridor.station(at: s)
                    let reach = st.reach(side)
                    let p = RoadBuilder.vergePoint(corridor, st, side: side, offset: reach - st.halfWidth + run.offset)
                    let road = corridor.roadHeight(st, lateral: side * reach)
                    let toRoad = SIMD3<Float>(Float(-side * st.rightE), 0, Float(side * st.rightN))
                    let along = SIMD3<Float>(Float(st.dirE), 0, Float(-st.dirN))
                    let foot = Float(min(p.y, road)) - 0.35, top = Float(road) + 0.72
                    let base = SIMD3<Float>(Float(p.east), 0, Float(-p.north))
                    BuildingBuilder.emitPropBox(&kit.galvanised, centre: base + SIMD3(0, (foot + top) / 2, 0), x: along, z: toRoad,
                                                half: SIMD3(0.05, (top - foot) / 2, 0.035))
                    BuildingBuilder.emitPropBox(&kit.galvanised, centre: base + toRoad * 0.1 + SIMD3(0, Float(road) + 0.6, 0),
                                                x: along, z: toRoad, half: SIMD3(0.035, 0.1, 0.065))
                    s += 2.25
                }
            }
        }
    }

    // MARK: - Railings, fences, screens

    /// Points on the verge at `offset` beyond the edge, every `step` metres
    /// over `span`, in pieces broken at side roads.
    static func vergeSamples(corridor: RoadCorridor, span: CourseArt.Span, side: Double, offset: Double, step: Double,
                             sideRoads: RoadBuilder.SideRoadMask) -> [[(s: Double, p: SIMD2<Double>, y: Double)]] {
        var out: [[(s: Double, p: SIMD2<Double>, y: Double)]] = [[]]
        var s = max(span.lowerBound, 0)
        let end = min(span.upperBound, corridor.route.length)
        while s <= end + 1e-6 {
            let st = corridor.station(at: s)
            let o = st.reach(side) - st.halfWidth + offset
            let p = RoadBuilder.vergePoint(corridor, st, side: side, offset: o)
            let mouth = corridor.junctions.contains { $0.side == side && abs($0.s - s) < $0.width / 2 + 0.6 }
            if mouth || sideRoads.covers(east: p.east, north: p.north, margin: 0.4) {
                if !(out.last?.isEmpty ?? true) { out.append([]) }
            } else {
                out[out.count - 1].append((s, SIMD2(p.east, p.north), p.y))
            }
            s += step
        }
        return out.filter { $0.count >= 2 }
    }

    /// `vergeSamples` every metre as railing lines (plan point, foot).
    static func vergeLine(corridor: RoadCorridor, span: CourseArt.Span, side: Double, offset: Double,
                          sideRoads: RoadBuilder.SideRoadMask) -> [[(p: SIMD2<Double>, y: Double)]] {
        vergeSamples(corridor: corridor, span: span, side: side, offset: offset, step: 1, sideRoads: sideRoads)
            .map { $0.map { (p: $0.p, y: $0.y - 0.05) } }
    }

    /// A railing, fence or screen along `line` (plan points about a metre
    /// apart, each with the height its posts stand on). `side` is the side
    /// of the road it stands on: its face to the road is the other way.
    static func emitRailing(_ kind: CourseArt.Railing, line: [(p: SIMD2<Double>, y: Double)], side: Double,
                            kit: inout RoadsideKit) {
        guard line.count >= 2 else { return }
        func P(_ q: (p: SIMD2<Double>, y: Double), _ dy: Double) -> SIMD3<Float> {
            SIMD3(Float(q.p.x), Float(q.y + dy), Float(-q.p.y))
        }
        // Cumulative length, and the points every `pitch` metres along it.
        var arc = [0.0]
        for k in 1..<line.count { arc.append(arc[k - 1] + simd_distance(line[k - 1].p, line[k].p)) }
        let total = arc.last!
        guard total > 0.3 else { return }
        func at(_ a: Double) -> (p: SIMD2<Double>, y: Double, dir: SIMD2<Double>) {
            var k = 1
            while k < arc.count - 1, arc[k] < a { k += 1 }
            let t = min(max((a - arc[k - 1]) / max(arc[k] - arc[k - 1], 1e-6), 0), 1)
            let d = line[k].p - line[k - 1].p
            let l = max(simd_length(d), 1e-6)
            return (line[k - 1].p + d * t, line[k - 1].y + (line[k].y - line[k - 1].y) * t, d / l)
        }
        func every(_ pitch: Double, inset: Double = 0) -> [(p: SIMD2<Double>, y: Double, dir: SIMD2<Double>)] {
            let n = max(1, Int((total - 2 * inset) / pitch))
            return (0...n).map { at(inset + (total - 2 * inset) * Double($0) / Double(n)) }
        }
        func rail(_ m: inout MeshBuffer, _ dy: Double, _ r: Float, sides: Int = 6) {
            for k in 1..<line.count {
                TreeArchetype.tube(&m, P(line[k - 1], dy), P(line[k], dy), r, r, sides: sides, height: 100)
            }
        }
        /// A panel of `height` along the line: chain-link, net or a screen.
        func panel(_ height: Double, sag: Double = 0, stone: CourseArt.Stone? = nil, into m: inout MeshBuffer) {
            var a0 = 0.0
            for k in 1..<line.count {
                let qa = line[k - 1], qb = line[k]
                let a1 = a0 + simd_distance(qa.p, qb.p)
                let d = qb.p - qa.p
                let l = max(simd_length(d), 1e-6)
                let n2 = SIMD2(d.y, -d.x) / l * -side
                let n = SIMD3<Float>(Float(n2.x), 0, Float(-n2.y))
                // Sagging between posts 2.5 m apart.
                let ta = height - sag * sin(.pi * a0.truncatingRemainder(dividingBy: 2.5) / 2.5)
                let tb = height - sag * sin(.pi * a1.truncatingRemainder(dividingBy: 2.5) / 2.5)
                let corners = [P(qa, 0.04), P(qb, 0.04), P(qb, tb), P(qa, ta)]
                if let stone {
                    kit.stoneQuad(corners, normals: [n, n, n, n], along: [a0, a1, a1, a0],
                                  foot: [corners[0].y, corners[1].y, corners[1].y, corners[0].y], stone: stone)
                    let back = corners.map { $0 - n * 0.015 }
                    kit.stoneQuad([back[1], back[0], back[3], back[2]], normals: [-n, -n, -n, -n], along: [a1, a0, a0, a1],
                                  foot: [back[1].y, back[0].y, back[0].y, back[1].y], stone: stone)
                } else {
                    let first = UInt32(m.vertexCount)
                    for (q, uv) in zip(corners, [(a0, 0.04), (a1, 0.04), (a1, tb), (a0, ta)]) {
                        m.vertex(q.x, q.y, q.z, n.x, n.y, n.z, Float(uv.0), Float(uv.1))
                    }
                    m.quad(first, first + 1, first + 2, first + 3)
                }
                a0 = a1
            }
        }
        let h = kind.height
        switch kind {
        case .tubular:
            for q in every(2.0) {
                let b = (p: q.p, y: q.y)
                TreeArchetype.tube(&kit.galvanised, P(b, -0.05), P(b, h), 0.026, 0.026, sides: 6, height: 100)
            }
            rail(&kit.galvanised, h, 0.026)
            rail(&kit.galvanised, h * 0.5, 0.022)
        case .bars, .paintedBars:
            var m = MeshBuffer(parts: 1)
            for q in every(2.0) {
                let b = (p: q.p, y: q.y)
                TreeArchetype.tube(&m, P(b, -0.05), P(b, h), 0.03, 0.03, sides: 4, height: 100)
            }
            rail(&m, h, 0.024)
            rail(&m, 0.1, 0.016, sides: 4)
            if kind == .bars { kit.galvanised.append(m, sx: 1, sy: 1, sz: 1, yaw: 0, tx: 0, ty: 0, tz: 0) }
            else { kit.paint(m, "paint.blue") }
            // The bars, 22 mm round at 12 cm, drawn by the chain-link shader
            // on a panel, bar by bar near and their coverage beyond (as tubes
            // they shimmered in moire over the sea); texcoord 0's height
            // offset by 200, or 300 for blue paint.
            var bars = MeshBuffer(parts: 1)
            panel(h - 0.02, into: &bars)
            let code: Float = kind == .bars ? 200 : 300
            for i in 0..<bars.vertexCount { bars.uvs[2 * i + 1] += code }
            kit.chain.append(bars, sx: 1, sy: 1, sz: 1, yaw: 0, tx: 0, ty: 0, tz: 0)
        case .blackBars:
            var m = MeshBuffer(parts: 1)
            for q in every(2.0) {
                let b = (p: q.p, y: q.y)
                TreeArchetype.tube(&m, P(b, -0.05), P(b, h), 0.03, 0.03, sides: 4, height: 100)
            }
            // The 18 mm bars as three-sided tubes: at 12 cm apart they are
            // most of the railing's triangles, and nobody sees the facets.
            for q in every(0.12, inset: 0.06) {
                let b = (p: q.p, y: q.y)
                TreeArchetype.tube(&m, P(b, 0.1), P(b, h - 0.02), 0.009, 0.009, sides: 3, height: 100)
            }
            rail(&m, h, 0.024)
            rail(&m, 0.1, 0.016, sides: 4)
            kit.dark.append(m, sx: 1, sy: 1, sz: 1, yaw: 0, tx: 0, ty: 0, tz: 0)
        case .rusty:
            var m = MeshBuffer(parts: 1)
            for q in every(2.2) {
                let b = (p: q.p, y: q.y)
                TreeArchetype.tube(&m, P(b, -0.05), P(b, h), 0.022, 0.022, sides: 4, height: 100)
            }
            for q in every(0.16, inset: 0.08) {
                let b = (p: q.p, y: q.y)
                TreeArchetype.tube(&m, P(b, 0.08), P(b, h - 0.03), 0.008, 0.008, sides: 4, height: 100)
            }
            rail(&m, h, 0.02, sides: 4)
            rail(&m, 0.08, 0.014, sides: 4)
            kit.paint(m, "paint.corten")
        case .spear(let pillars):
            var m = MeshBuffer(parts: 1)
            // Square bars (four-sided tubes, no caps) and their spear tips.
            for q in every(0.13, inset: 0.07) {
                let b = (p: q.p, y: q.y)
                TreeArchetype.tube(&m, P(b, 0), P(b, h), 0.0099, 0.0099, sides: 4, height: 100)
                TreeArchetype.tube(&m, P(b, h), P(b, h + 0.09), 0.018, 0.0, sides: 3, height: 100)
            }
            rail(&m, 0.15, 0.014, sides: 4)
            rail(&m, h - 0.12, 0.014, sides: 4)
            kit.dark.append(m, sx: 1, sy: 1, sz: 1, yaw: 0, tx: 0, ty: 0, tz: 0)
            if pillars {
                // Square stone pillars every 6.4 m (the villa frontages at
                // 840-990: a pillar to a bay of railing, 2024 frame at 839 m),
                // a concrete cap on each.
                for q in every(6.4) {
                    let along = SIMD3<Float>(Float(q.dir.x), 0, Float(-q.dir.y))
                    let base = P((p: q.p, y: q.y), 0)
                    kit.stoneBox(base + SIMD3(0, Float(h + 0.1) / 2 - 0.1, 0), along: along,
                                 half: SIMD3(0.2, Float(h + 0.1) / 2, 0.2), stone: .greySquared)
                    kit.stoneBox(base + SIMD3(0, Float(h) + 0.05, 0), along: along, half: SIMD3(0.24, 0.045, 0.24), stone: .coping,
                                 footY: base.y)
                }
            }
        case .chainLink(let green):
            var posts = MeshBuffer(parts: 1)
            for q in every(2.5) {
                let b = (p: q.p, y: q.y)
                TreeArchetype.tube(&posts, P(b, -0.1), P(b, h + 0.05), 0.024, 0.024, sides: 6, height: 100)
            }
            if green { kit.paint(posts, "paint.green") }
            else { kit.galvanised.append(posts, sx: 1, sy: 1, sz: 1, yaw: 0, tx: 0, ty: 0, tz: 0) }
            rail(&kit.wire, h, 0.004, sides: 3)
            var mesh = MeshBuffer(parts: 1)
            panel(h, into: &mesh)
            // Green plastic-coated mesh: the chain-link shader reads its
            // colour from texcoord 0's height (above 50 m: green).
            if green { for i in 0..<mesh.vertexCount { mesh.uvs[2 * i + 1] += 100 } }
            kit.chain.append(mesh, sx: 1, sy: 1, sz: 1, yaw: 0, tx: 0, ty: 0, tz: 0)
        case .shadeNet:
            for q in every(2.5) {
                let b = (p: q.p, y: q.y)
                TreeArchetype.tube(&kit.galvanised, P(b, -0.1), P(b, h + 0.05), 0.026, 0.026, sides: 6, height: 100)
            }
            rail(&kit.wire, h, 0.004, sides: 3)
            var net = MeshBuffer(parts: 1)
            panel(h - 0.03, sag: 0.06, into: &net)
            kit.net.append(net, sx: 1, sy: 1, sz: 1, yaw: 0, tx: 0, ty: 0, tz: 0)
        case .reedScreen:
            for q in every(2.0) {
                let b = (p: q.p, y: q.y)
                TreeArchetype.tube(&kit.timber, P(b, -0.1), P(b, h - 0.05), 0.035, 0.03, sides: 5, height: 100)
            }
            var unused = MeshBuffer(parts: 1)
            panel(h, stone: .reeds, into: &unused)
        case .corrugated:
            for q in every(2.0) {
                let b = (p: q.p, y: q.y)
                TreeArchetype.tube(&kit.timber, P(b, -0.1), P(b, h + 0.05), 0.05, 0.045, sides: 5, height: 100)
            }
            var unused = MeshBuffer(parts: 1)
            panel(h, stone: .rustSheet, into: &unused)
        }
    }

    // MARK: - Painted letters

    /// Strokes of a hand-painted capital or digit in a box `width` wide and
    /// 1 high (x right, y up).
    static func glyph(_ c: Character) -> (width: Double, strokes: [[SIMD2<Double>]]) {
        func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, from a0: Double = 0, to a1: Double = 360,
                     steps: Int = 18) -> [SIMD2<Double>] {
            var out: [SIMD2<Double>] = []
            for k in 0...steps {
                let f = Double(k) / Double(steps)
                let a: Double = (a0 + (a1 - a0) * f) * Double.pi / 180
                out.append(SIMD2<Double>(cx + rx * cos(a), cy + ry * sin(a)))
            }
            return out
        }
        typealias V = SIMD2<Double>
        switch c {
        case "I": return (0.3, [[V(0.12, 0), V(0.12, 1)]])
        case "L": return (0.72, [[V(0.12, 1), V(0.1, 0), V(0.62, 0.02)]])
        case "P":
            let stem: [V] = [V(0.12, 0), V(0.12, 1), V(0.45, 0.99)]
            let bowl: [V] = ellipse(0.42, 0.75, 0.22, 0.24, from: 90, to: -90, steps: 10)
            return (0.74, [stem + bowl + [V(0.12, 0.51)]])
        case "O": return (0.86, [ellipse(0.42, 0.5, 0.32, 0.5)])
        case "G":
            let arc: [V] = ellipse(0.42, 0.5, 0.32, 0.5, from: 35, to: 345, steps: 18)
            return (0.86, [arc + [V(0.74, 0.44), V(0.48, 0.44)]])
        case "1": return (0.5, [[V(0.1, 0.78), V(0.3, 1), V(0.3, 0)]])
        case "9":
            let loop: [V] = ellipse(0.34, 0.7, 0.26, 0.3, steps: 14)
            return (0.72, [loop + [V(0.6, 0.7), V(0.5, 0)]])
        case "6":
            let loop: [V] = ellipse(0.36, 0.3, 0.27, 0.3, from: 180, to: 540, steps: 16)
            return (0.72, [[V(0.56, 0.96), V(0.22, 0.6)] + loop])
        case "0": return (0.74, [ellipse(0.36, 0.5, 0.28, 0.5)])
        default: return (0.5, [])
        }
    }

    /// Big white letters brushed onto the wall at the edge (the fans' "IL
    /// POGGIO" on the dark wall below the top): from 35 cm over the road,
    /// strokes about a seventh of the letter high, a little uneven, widely
    /// spaced, a few runs of paint below them, 1.5 cm proud of the face.
    static func paintWord(_ word: (s: Double, side: Double, text: String, height: Double), corridor: RoadCorridor,
                          kit: inout RoadsideKit) {
        let h = word.height
        let glyphs = word.text.map { glyph($0) }
        let gap = 0.3
        let width = glyphs.reduce(0) { $0 + $1.width * h } + gap * h * Double(max(glyphs.count - 1, 0))
        let wall = corridor.art.masonry.first { $0.side * word.side > 0 && $0.span.contains(word.s) }
        let offset = (wall?.offset ?? 0.14) - 0.015
        var rnd = WorldRandom(word.s, word.side, salt: 17)
        // A point on the wall face `u` metres along the road from the word's
        // start, `y` above the road there; and the face's normal.
        func face(_ u: Double, _ y: Double) -> (SIMD3<Float>, SIMD3<Float>) {
            let s = word.s - width / 2 + u
            let st = corridor.station(at: s)
            let reach = st.reach(word.side)
            let p = st.point(lateral: word.side * (reach + offset))
            let road = corridor.roadHeight(st, lateral: word.side * reach)
            let n = SIMD3<Float>(Float(-word.side * st.rightE), 0, Float(word.side * st.rightN))
            return (SIMD3(Float(p.east), Float(road + 0.35 + y), Float(-p.north)), n)
        }
        let stroke = 0.15 * h
        var u0 = 0.0
        for g in glyphs {
            for line in g.strokes where line.count >= 2 {
                for k in 1..<line.count {
                    let a = line[k - 1], b = line[k]
                    let d = b - a
                    let l = simd_length(d)
                    guard l > 1e-4 else { continue }
                    let nrm = SIMD2(-d.y, d.x) / l * (stroke / h / 2)
                    let w0 = 1 + Double(rnd.range(-0.15, 0.15)), w1 = 1 + Double(rnd.range(-0.15, 0.15))
                    let corners: [SIMD2<Double>] = [a - nrm * w0, b - nrm * w1, b + nrm * w1, a + nrm * w0]
                    let first = UInt32(kit.white.vertexCount)
                    for c in corners {
                        let (p, n) = face(u0 + c.x * h, c.y * h)
                        kit.white.vertex(p.x, p.y, p.z, n.x, n.y, n.z, 0, 0)
                    }
                    // Wound to face the road.
                    let (p0, n0) = face(u0 + corners[0].x * h, corners[0].y * h)
                    let (p1, _) = face(u0 + corners[1].x * h, corners[1].y * h)
                    let (p2, _) = face(u0 + corners[2].x * h, corners[2].y * h)
                    if simd_dot(simd_cross(p1 - p0, p2 - p0), n0) >= 0 {
                        kit.white.quad(first, first + 1, first + 2, first + 3)
                    } else {
                        kit.white.quad(first, first + 3, first + 2, first + 1)
                    }
                    // Joints between strokes: a round blob at each bend.
                    // A run of paint now and then from a low point.
                    if rnd.unit() < 0.18, min(a.y, b.y) < 0.3 {
                        let x = (a.x + b.x) / 2, len = Double(rnd.range(0.05, 0.22))
                        let dw = stroke / h * 0.12
                        let run: [SIMD2<Double>] = [SIMD2(x - dw, min(a.y, b.y)), SIMD2(x + dw, min(a.y, b.y)),
                                                    SIMD2(x + dw * 0.6, min(a.y, b.y) - len), SIMD2(x - dw * 0.6, min(a.y, b.y) - len)]
                        let f2 = UInt32(kit.white.vertexCount)
                        for c in run {
                            let (p, n) = face(u0 + c.x * h, c.y * h)
                            kit.white.vertex(p.x, p.y, p.z, n.x, n.y, n.z, 0, 0)
                        }
                        let (q0, m0) = face(u0 + run[0].x * h, run[0].y * h)
                        let (q1, _) = face(u0 + run[1].x * h, run[1].y * h)
                        let (q2, _) = face(u0 + run[2].x * h, run[2].y * h)
                        if simd_dot(simd_cross(q1 - q0, q2 - q0), m0) >= 0 {
                            kit.white.quad(f2, f2 + 1, f2 + 2, f2 + 3)
                        } else {
                            kit.white.quad(f2, f2 + 3, f2 + 2, f2 + 1)
                        }
                    }
                }
            }
            u0 += (g.width + gap) * h
        }
    }

    // MARK: - Chevron plates

    /// A black chevron plate on the outside wall of a hairpin, 1.3 m up its
    /// road face, turned 25° towards the riders coming round; on a short
    /// galvanised post where no wall stands.
    static func chevronPlate(_ c: (s: Double, side: Double, pointsLeft: Bool), corridor: RoadCorridor, kit: inout RoadsideKit) {
        guard let cell = kit.cells[c.pointsLeft ? "it.chevron.left" : "it.chevron.right"] else { return }
        let st = corridor.station(at: c.s)
        let reach = st.reach(c.side)
        let wall = corridor.art.masonry.first { $0.side * c.side > 0 && $0.span.contains(c.s) && $0.retains }
        // On the face, set back 1.3 m up a battered stone wall (`buildEdgeWall`).
        let lean = wall.map { [.honeyRubble, .greySquared, .dryStone, .greyRubble].contains($0.look) ? 0.08 * 1.4 : 0 } ?? 0
        let lat = c.side * (reach + (wall.map { $0.offset - 0.03 + lean } ?? 0.45))
        let p = st.point(lateral: lat)
        let road = corridor.roadHeight(st, lateral: c.side * reach)
        let toRoad = SIMD3<Float>(Float(-c.side * st.rightE), 0, Float(c.side * st.rightN))
        let along = SIMD3<Float>(Float(st.dirE), 0, Float(-st.dirN))
        let n = simd_normalize(toRoad * cos(0.44) - along * sin(0.44))
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), n))
        let centre = SIMD3<Float>(Float(p.east), Float(road + 1.3), Float(-p.north)) + n * 0.02
        var back = MeshBuffer(parts: 1)
        plate(&kit.sign, &back, cell: cell, centre: centre, right: right, normal: n)
        kit.galvanised.append(back, sx: 1, sy: 1, sz: 1, yaw: 0, tx: 0, ty: 0, tz: 0)
        if wall == nil {
            let g = RoadBuilder.vergePoint(corridor, st, side: c.side, offset: reach - st.halfWidth + 0.45)
            TreeArchetype.tube(&kit.galvanised, SIMD3(Float(g.east), Float(g.y) - 0.3, Float(-g.north)) - n * 0.03,
                               SIMD3(Float(g.east), Float(road + 1.6), Float(-g.north)) - n * 0.03, 0.03, 0.03, sides: 6, height: 100)
        }
    }

    // MARK: - Trolleybus wires

    /// A trolleybus overhead along `span`: steel poles either side about
    /// every 30 m, a span wire between them 7 m up, and over each lane a
    /// pair of contact wires 0.6 m apart at 5.6 m, hung from the span
    /// wires and staggered a little side to side.
    static func trolleyWires(_ span: CourseArt.Span, corridor: RoadCorridor, kit: inout RoadsideKit) {
        var rnd = WorldRandom(span.lowerBound, span.upperBound, salt: 5)
        var prev: [SIMD3<Float>]?
        var s = span.lowerBound + 4
        while s <= span.upperBound {
            let st = corridor.station(at: s)
            let road = Float(st.elev)
            var ends: [SIMD3<Float>] = []
            for side in [-1.0, 1.0] {
                let g = RoadBuilder.vergePoint(corridor, st, side: side, offset: st.reach(side) - st.halfWidth + 1.2)
                let base = SIMD3<Float>(Float(g.east), Float(g.y) - 0.3, Float(-g.north))
                let top = SIMD3<Float>(base.x, road + 7.6, base.z)
                TreeArchetype.tube(&kit.galvanised, base, top, 0.11, 0.08, sides: 8, height: 100)
                ends.append(SIMD3(base.x, road + 7.1, base.z))
            }
            TreeArchetype.tube(&kit.wire, ends[0], ends[1], 0.006, 0.006, sides: 3, height: 100)
            // The contact wires' points under this span wire.
            let zig = Float(rnd.range(-0.2, 0.2))
            var pts: [SIMD3<Float>] = []
            for lane in [-1.0, 1.0] {
                for wire in [-0.3, 0.3] {
                    let p = st.point(lateral: lane * st.halfWidth * 0.5 + wire + Double(zig))
                    pts.append(SIMD3(Float(p.east), road + 5.6, Float(-p.north)))
                }
            }
            for q in pts {
                // Droppers up to the span wire.
                TreeArchetype.tube(&kit.wire, q, SIMD3(q.x, road + 7.05, q.z), 0.005, 0.005, sides: 3, height: 100)
            }
            if let prev {
                for k in pts.indices {
                    let a = prev[k], b = pts[k]
                    let mid = (a + b) / 2 - SIMD3(0, 0.12, 0)
                    TreeArchetype.tube(&kit.wire, a, mid, 0.007, 0.007, sides: 3, height: 100)
                    TreeArchetype.tube(&kit.wire, mid, b, 0.007, 0.007, sides: 3, height: 100)
                }
            }
            prev = pts
            s += 28 + Double(rnd.range(-3, 3))
        }
    }
}

extension WorldLook {
    /// The sign atlas the course's plates and paints come from
    /// (scripts/courses/textures/bake_signs.py; `--it` for the Riviera's).
    var signAtlas: String { isRiviera ? "cj_signs_it" : "cj_signs" }
}
