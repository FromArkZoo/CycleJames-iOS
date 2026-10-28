import Foundation
import simd

/// Flemish village buildings from the footprints, plus the roadside props
/// from the climb's description (street lamps, fences and paddock rails,
/// utility poles and their wires, brick walls) and water.
///
/// Walls are drawn from cj_facade.jpg (rows: white-painted brick, red-brown
/// brick, cream render, dark brick; columns: upper window, ground window,
/// door bay, blank) at true scale: the blank wall of the building's row,
/// which `WorldShaders.wallSurface` wraps every 3 m, around windows and a
/// door cut from the other columns and set out at the building's own bay
/// pitch. Barns and sheds show the road a big timber or steel door the
/// shader paints. Below the floor and up to a plinth height runs a plinth
/// band (tarred, painted, bluestone or cement); `wallSurface` tints and
/// weathers each building.
/// Gabled roofs split the footprint along the ridge of its best-fit
/// rectangle, so L-shaped and irregular plans still get closed, sloping
/// roofs; they overhang the walls, with fascia and barge boards along their
/// edges and ridge tiles along the top, all on the cj_roof.jpg atlas
/// (`WorldShaders.roofSurface`).
enum BuildingBuilder {
    struct Output {
        /// Texcoord 0 = `Paint`, texcoord 1 = (height above the ground under
        /// the vertex, metres below the wall top), texcoord 2 = (`wallCode`,
        /// seed): see `WorldShaders.wallSurface`.
        var walls = MeshBuffer()
        /// Part 0 pantiles, part 1 slate, sheet and flat roofs, both drawn
        /// by `WorldShaders.roofSurface`; texcoord 1 = (id + seed / 2,
        /// metres up from the eave line), see `roofVertex`.
        var roofs = MeshBuffer(parts: 2)
        /// Parts: see `PropPart`.
        var props = MeshBuffer(parts: PropPart.allCases.count)
        /// Ponds.
        var water = MeshBuffer()
        /// Stream ribbons; texcoord 1 = (open sky 0...1, -).
        var streams = MeshBuffer()
        var count = 0
    }

    enum WallRow: Int { case painted = 0, redBrick, cream, darkBrick }

    /// The tiles of cj_roof.jpg (scripts/courses/textures/bake_buildings.py).
    enum RoofCover: Int { case redPantile = 0, smokedPantile, slate, sheet }

    /// Roof ids `WorldShaders.roofSurface` paints without the atlas. Slate
    /// and smoked-pantile roofs get a plain dark ridge: their tiles' laps
    /// read as a row of light dashes along it.
    enum RoofTrim: Int { case whiteBoard = 4, darkBoard, flatRoof, darkRidge }

    /// What a wall vertex is, for `WorldShaders.wallSurface`: the doors are
    /// barns' and sheds', painted by the shader (`Paint.door`); a dry-stone
    /// retaining wall's slabs are laid by the shader too.
    enum WallKind: Int {
        case wall = 0, tarPlinth, paintedPlinth, stonePlinth, cementPlinth, stack, timberDoor, steelDoor, dryStone
    }

    /// Texcoord 2 x of a wall vertex: its kind and the building's tint
    /// (an index into the shader's tints).
    static func wallCode(_ kind: WallKind, tint: Int) -> Float { Float(kind.rawValue * 8 + tint) }

    /// Material slots of `Output.props`, in `WorldMaterials.props` order.
    /// `signFace` is the sign atlas (cj_signs.png): plates, grates and the
    /// plain paints of a few props.
    enum PropPart: Int, CaseIterable {
        case darkMetal = 0, lampGlass, wood, wire, whitePaint, concrete, darkWood, greyMetal, signFace
    }

    struct Style {
        var row: WallRow
        var pantile: Bool
        var pitchDeg: Double
        var shed: Bool
        // The rest is set by `dress`.
        var roof: RoofCover = .slate
        /// Index into `WorldShaders.wallSurface`'s tints.
        var tint = 0
        /// `.wall` for none.
        var plinth: WallKind = .wall
        /// Plinth top above the floor, metres.
        var plinthHeight = 0.0
        /// Spacing of the window bays, metres.
        var bayPitch = 3.0
        /// Chance of a window in a bay of the front wall (others about half).
        var windowChance: Float = 0.85
        /// The building's usual window; about one in four differs.
        var window: OpeningCut = .ground
        /// Window width against the atlas's.
        var windowScale = 1.0
        var boards: RoofTrim = .whiteBoard
        /// A barn's or shed's big door.
        var shedDoor: WallKind = .timberDoor
        /// 0..<1, per building: tint phase, weathering, roof variation.
        var seed: Float = 0
    }

    /// `canopy` is the LiDAR vegetation height above the ground, for the
    /// streams under the roadside bushes. Returns early, partly built, when
    /// the task is cancelled.
    static func build(corridor: RoadCorridor, scenery: SceneryFile?, canopy: HeightRaster? = nil) -> Output {
        var out = Output()
        let terrain = corridor.terrain
        // Footprints a hand-placed landmark is built on whole.
        let landmarks = Set(domedChapelSites(corridor: corridor, scenery: scenery).map { $0.index })
        for (index, b) in (scenery?.buildings ?? []).enumerated() {
            if Task.isCancelled { return out }
            if landmarks.contains(index) { continue }
            var ring = b.ring.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }
            ring = cleaned(ring)
            guard ring.count >= 3 else { continue }
            if signedArea(ring) < 0 { ring.reverse() }
            let area = signedArea(ring)
            guard area > 4 else { continue }
            let place = lookPlace(ring, corridor: corridor)
            let style = chooseStyle(b, area: area, look: place.map {
                corridor.art.houseLook(s: $0.s, routeDistance: $0.dist, side: $0.side, kind: b.kind)
            } ?? nil, index: index)
            // L-, T- and U-shaped plans are roofed piece by piece (churches
            // whole, for their single tower).
            let pieces = b.kind == "church" || b.roofShape == "flat" ? [ring] : roofPieces(ring)
            for (k, piece) in pieces.enumerated() {
                emitBuilding(&out, ring: piece, footprint: ring, area: signedArea(piece), building: b, style: style,
                             terrain: terrain, corridor: corridor, seed: UInt64(index + 1) &+ UInt64(k) &* 7919,
                             detail: (place?.dist ?? .infinity) < detailRouteDistance)
            }
            out.count += 1
        }
        buildSummitWall(&out, corridor: corridor)
        buildStoneWalls(&out, corridor: corridor)
        buildLamps(&out, corridor: corridor)
        // Fences stop at the mouths of the side roads they would cross.
        let sideRoads = RoadBuilder.SideRoadMask(scenery: scenery)
        buildFences(&out, corridor: corridor, sideRoads: sideRoads)
        buildRails(&out, corridor: corridor, sideRoads: sideRoads)
        buildPoles(&out, corridor: corridor)
        buildSigns(&out, corridor: corridor, scenery: scenery)
        buildGrates(&out, corridor: corridor)
        buildFurniture(&out, corridor: corridor, scenery: scenery)
        buildWater(&out, scenery: scenery, terrain: terrain, canopy: canopy)
        out.walls.computeNormals()
        out.roofs.computeNormals()
        out.water.computeNormals()
        out.streams.computeNormals()
        return out
    }

    // MARK: - Style

    /// Where a footprint sits for `CourseArt.houseLook`: the route distance
    /// and distance from the route of its vertex centroid, and its side.
    static func lookPlace(_ ring: [SIMD2<Double>], corridor: RoadCorridor) -> (s: Double, dist: Double, side: Double)? {
        guard !ring.isEmpty else { return nil }
        let centroid = ring.reduce(SIMD2<Double>.zero, +) / Double(ring.count)
        let q = corridor.coarse.query(east: centroid.x, north: centroid.y)
        let st = corridor.station(at: q.s)
        let side: Double = (centroid.x - st.east) * st.rightE + (centroid.y - st.north) * st.rightN >= 0 ? 1 : -1
        return (q.s, q.dist, side)
    }

    static func chooseStyle(_ b: SceneryFile.Building, area: Double, look: CourseArt.HouseLook.Look?, index: Int) -> Style {
        var style = baseStyle(b, area: area, look: look, index: index)
        dress(&style, kind: b.kind, index: index)
        return style
    }

    /// Walls, roof colour and pitch from the look of the place.
    static func baseStyle(_ b: SceneryFile.Building, area: Double, look: CourseArt.HouseLook.Look?, index: Int) -> Style {
        var r = WorldRandom(seed: UInt64(index) &* 2_654_435_761 &+ 99)
        let kind = b.kind ?? "other"
        let shed = (kind == "other" && (area < 45 || b.heightM < 4)) || kind == "barn"
        let pitch = Double(r.range(38, 48))
        if kind == "church" {
            // Brick, unless a look asks for a white-washed one (Kwaremont's
            // Sint-Amandus).
            let painted = look == .whitewashedCottages || look == .paleRender
            return Style(row: painted ? .painted : .darkBrick, pantile: false, pitchDeg: 55, shed: false)
        }
        switch look {
        case .whitewashedCottages where !shed:
            // White-washed cottages under dark roofs (the Steengat).
            return Style(row: r.unit() < 0.85 ? .painted : .cream, pantile: r.unit() < 0.15, pitchDeg: pitch, shed: false)
        case .hilltopFarms:
            // Farms: red brick with orange pantiles, a cream house.
            if kind == "house" { return Style(row: .cream, pantile: false, pitchDeg: pitch, shed: false) }
            return Style(row: .redBrick, pantile: true, pitchDeg: pitch, shed: shed)
        case .redBrickPantiles:
            return Style(row: r.unit() < 0.85 ? .redBrick : .darkBrick, pantile: true, pitchDeg: pitch, shed: shed)
        case .whitewashedPantiles:
            return Style(row: shed && r.unit() < 0.5 ? .redBrick : .painted, pantile: true, pitchDeg: pitch, shed: shed)
        case .paleRender:
            // Small and flat-roofed buildings too (the Paterberg's summit
            // cottage, a white single-storey school).
            return Style(row: r.unit() < 0.7 ? .painted : .cream, pantile: false, pitchDeg: shed ? pitch * 0.8 : pitch,
                         shed: shed)
        case .paleRenderTiles where !shed:
            return Style(row: .painted, pantile: true, pitchDeg: pitch, shed: false)
        case .redBrickSlate:
            return Style(row: .redBrick, pantile: false, pitchDeg: pitch, shed: shed)
        case .darkBrick where !shed:
            return Style(row: .darkBrick, pantile: r.unit() < 0.2, pitchDeg: pitch + 4, shed: false)
        case .villageMix where !shed:
            let u = r.unit()
            let row: WallRow = u < 0.45 ? .redBrick : u < 0.7 ? .painted : u < 0.85 ? .cream : .darkBrick
            return Style(row: row, pantile: r.unit() < 0.3, pitchDeg: pitch, shed: false)
        default:
            break
        }
        if shed {
            return Style(row: r.unit() < 0.6 ? .redBrick : .darkBrick, pantile: r.unit() < 0.5, pitchDeg: pitch * 0.8, shed: true)
        }
        let u = r.unit()
        let row: WallRow = u < 0.28 ? .painted : u < 0.66 ? .redBrick : u < 0.8 ? .cream : .darkBrick
        return Style(row: row, pantile: r.unit() < 0.35, pitchDeg: pitch, shed: false)
    }

    /// The details `baseStyle` leaves open, from a random stream of their
    /// own (so the walls and roofs it picks stay as they were): roof cover,
    /// wall tint, plinth, window rhythm and trim, all fixed per building.
    /// White-washed walls stand on a tarred or painted black plinth, brick
    /// on bluestone or cement, as in the villages.
    static func dress(_ s: inout Style, kind: String?, index: Int) {
        var r = WorldRandom(seed: UInt64(index) &* 0x2545_F491 &+ 17)
        func pick<T>(_ options: [(Double, T)]) -> T {
            var x = Double(r.unit()) * options.reduce(0) { $0 + $1.0 }
            for (w, v) in options {
                if x < w { return v }
                x -= w
            }
            return options[options.count - 1].1
        }
        s.seed = r.unit()
        if kind == "church" {
            s.roof = .slate
        } else if s.pantile {
            s.roof = .redPantile
        } else if s.shed {
            s.roof = r.unit() < 0.5 ? .sheet : .smokedPantile
        } else {
            s.roof = r.unit() < 0.55 ? .smokedPantile : .slate
        }
        switch s.row {
        case .painted:
            s.tint = pick([(3, 0), (3, 1), (2, 2), (1, 3), (1, 4), (0.5, 7)])
            s.plinth = pick([(0.65, WallKind.tarPlinth), (0.35, .paintedPlinth)])
            s.plinthHeight = Double(r.range(0.45, 0.8))
            s.boards = r.unit() < 0.6 ? .darkBoard : .whiteBoard
        case .redBrick:
            s.tint = pick([(3, 0), (1, 4), (2, 5), (2, 6)])
            s.plinth = pick([(0.45, WallKind.stonePlinth), (0.3, .cementPlinth), (0.25, .wall)])
            s.plinthHeight = Double(r.range(0.3, 0.55))
            s.boards = r.unit() < 0.65 ? .whiteBoard : .darkBoard
        case .cream:
            s.tint = pick([(2, 0), (2, 1), (2, 3), (1, 7), (1, 4)])
            s.plinth = pick([(0.5, WallKind.cementPlinth), (0.3, .paintedPlinth), (0.2, .tarPlinth)])
            s.plinthHeight = Double(r.range(0.4, 0.7))
            s.boards = r.unit() < 0.5 ? .whiteBoard : .darkBoard
        case .darkBrick:
            s.tint = pick([(3, 0), (1, 4), (1, 6)])
            s.plinth = r.unit() < 0.6 ? .stonePlinth : .wall
            s.plinthHeight = Double(r.range(0.3, 0.5))
            s.boards = r.unit() < 0.8 ? .darkBoard : .whiteBoard
        }
        if s.shed {
            s.plinth = r.unit() < 0.5 ? .cementPlinth : .wall
            s.plinthHeight = Double(r.range(0.25, 0.45))
            s.boards = .darkBoard
        }
        if s.plinth == .wall { s.plinthHeight = 0 }
        s.bayPitch = Double(r.range(2.5, 3.6))
        s.windowChance = r.range(0.72, 0.95)
        s.window = pick([(0.45, OpeningCut.ground), (0.4, .upper), (0.15, .narrow)])
        s.windowScale = Double(r.range(0.94, 1.08))
        s.shedDoor = r.unit() < 0.6 ? .timberDoor : .steelDoor
    }

    // MARK: - Building

    /// Buildings whose centre is this close to the route get their walls
    /// laid out window by window (`layoutOpenings`); further out, where a
    /// window is a few pixels, whole facade bays (`emitBayWall`).
    static let detailRouteDistance = 75.0

    static func emitBuilding(_ out: inout Output, ring: [SIMD2<Double>], footprint: [SIMD2<Double>], area: Double,
                             building b: SceneryFile.Building, style: Style, terrain: TerrainSampler,
                             corridor: RoadCorridor, seed: UInt64, detail: Bool = true) {
        var rnd = WorldRandom(seed: seed &* 31 &+ 7)
        let obb = orientedBox(ring)
        var groundMin = Double.infinity, groundMax = -Double.infinity
        for p in ring {
            let h = Double(terrain.height(east: p.x, north: p.y))
            groundMin = min(groundMin, h); groundMax = max(groundMax, h)
        }
        let floorY = b.groundElevM ?? groundMax
        let baseY = min(groundMin, floorY) - 0.4
        let height = max(b.heightM, 2.4)
        let ridgeY = floorY + height
        let shape = b.roofShape ?? "unknown"
        var flat = shape == "flat" || height < 3.0 || (style.shed && area < 25)
        let hw = obb.halfShort
        var rise = tan(style.pitchDeg * .pi / 180) * hw
        var eaveY = ridgeY - rise
        if eaveY - floorY < 2.3 {
            eaveY = floorY + 2.3
            rise = ridgeY - eaveY
        }
        if rise < 0.6 { flat = true }
        if flat { eaveY = ridgeY; rise = 0 }
        // Under a low eave the windows drop a few courses, onto a lower plinth.
        var style = style
        if eaveY - floorY < 2.9 { style.plinthHeight = min(style.plinthHeight, 0.42) }

        func roofY(_ p: SIMD2<Double>) -> Double {
            if flat { return ridgeY }
            let dn = abs(simd_dot(p - obb.centre, obb.short))
            return eaveY + rise * (1 - dn / max(hw, 0.01))
        }
        func ground(_ p: SIMD2<Double>) -> Double { Double(terrain.height(east: p.x, north: p.y)) }

        // Front door on the wall that faces the route; a barn's or shed's
        // big door only where the road passes within 40 m.
        var doorEdge = -1
        var best = Double.infinity
        for i in ring.indices {
            let a = ring[i], c = ring[(i + 1) % ring.count]
            guard simd_length(c - a) >= (style.shed ? 1.6 : 3) else { continue }
            let mid = (a + c) / 2
            let d = corridor.coarse.query(east: mid.x, north: mid.y).dist
            if d < best { best = d; doorEdge = i }
        }
        if style.shed, best >= 40 { doorEdge = -1 }

        // Walls, one per edge; a gable's top rises to the ridge and falls
        // again. Edges inside the footprint (where an L-shaped plan was cut
        // into pieces) stay blank.
        for i in ring.indices {
            let a = ring[i], c = ring[(i + 1) % ring.count]
            let len = simd_length(c - a)
            guard len > 0.05 else { continue }
            let dir = (c - a) / len
            var w = WallFrame(a: a, dir: dir, len: len, top0: roofY(a), top1: roofY(c), floorY: floorY, baseY: baseY,
                              ground: groundSamples(a, c, ground))
            if !flat {
                let fa = simd_dot(a - obb.centre, obb.short), fc = simd_dot(c - obb.centre, obb.short)
                if fa * fc < 0 {
                    let u = len * fa / (fa - fc)
                    w.uRidge = u
                    w.topRidge = roofY(a + dir * u)
                }
            }
            let mid = (a + c) / 2
            let outside = distanceToRing(mid, footprint) < 0.05
            guard detail else {
                emitBayWall(&out.walls, w, style: style, windows: outside, rnd: &rnd)
                continue
            }
            // Walls looking at the road get the front's windows too; any the
            // road sees, no long blank stretch.
            let q = corridor.coarse.query(east: mid.x, north: mid.y)
            let st = corridor.station(at: q.s)
            let toRoad = SIMD2(st.east, st.north) - mid
            let facesRoad = q.dist < 40 && simd_dot(w.nrm, toRoad) > 0.5 * simd_length(toRoad)
            let seen = facesRoad || seenFromRoute(mid, facing: w.nrm, s: q.s, dist: q.dist, corridor: corridor)
            let openings: [Opening]
            if !outside {
                openings = []
            } else if style.shed {
                openings = layoutShedOpenings(w, style: style, door: i == doorEdge, seen: seen, rnd: &rnd)
            } else {
                openings = layoutOpenings(w, style: style, eaveY: eaveY, door: i == doorEdge ? len * Double(rnd.range(0.3, 0.7)) : nil,
                                          front: i == doorEdge || facesRoad, seen: seen, rnd: &rnd)
            }
            emitWall(&out.walls, w, style: style, openings: openings)
        }

        // Roof.
        let part = style.roof.rawValue <= RoofCover.smokedPantile.rawValue ? 0 : 1
        let cover = style.roof.rawValue, sd = style.seed
        let board = style.boards.rawValue
        let ridge = style.roof == .slate || style.roof == .smokedPantile ? RoofTrim.darkRidge.rawValue : cover
        let rectangular = area / (4 * obb.halfLong * obb.halfShort) > 0.86
        func P(_ p: SIMD2<Double>, _ y: Double) -> SIMD3<Float> { SIMD3(Float(p.x), Float(y), Float(-p.y)) }
        if flat {
            // A flat roof behind a low coping.
            emitRoofPolygon(&out.roofs, ring, y: { _ in ridgeY + 0.02 }, uv: { p in (Float(p.x), Float(p.y)) },
                            id: RoofTrim.flatRoof.rawValue, seed: sd, up: { _ in 0 }, part: 1)
            for i in ring.indices {
                let a = ring[i], c = ring[(i + 1) % ring.count]
                guard let n = outward(a, c) else { continue }
                emitBoard(&out.roofs, a + n * 0.03, c + n * 0.03, ya: ridgeY + 0.02, yb: ridgeY + 0.02, out: n,
                          depth: 0.3, lip: 0.14, id: RoofTrim.darkBoard.rawValue, seed: sd, part: 1)
            }
        } else if rectangular {
            let hl = obb.halfLong + 0.25, hs = hw + 0.35
            let slope = rise / max(hw, 0.01)
            let cosP = 1 / sqrt(1 + slope * slope)
            func at(_ t: Double, _ n: Double) -> SIMD2<Double> { obb.centre + obb.long * t + obb.short * n }
            func y(_ n: Double) -> Double { eaveY + rise * (1 - abs(n) / hw) + 0.03 }
            for side in [-1.0, 1.0] {
                let corners: [(Double, Double)] = side > 0 ? [(-hl, 0), (hl, 0), (hl, hs), (-hl, hs)] : [(hl, 0), (-hl, 0), (-hl, -hs), (hl, -hs)]
                let first = UInt32(out.roofs.vertexCount)
                for (t, n) in corners {
                    roofVertex(&out.roofs, P(at(t, n), y(n)), (Float(t), Float(abs(n) / cosP)), id: cover, seed: sd,
                               up: Float((hw - abs(n)) / cosP))
                }
                out.roofs.tri(first, first + 1, first + 2, part: part)
                out.roofs.tri(first, first + 2, first + 3, part: part)
                // The eave: a fascia board, and a soffit back up to the top
                // of the wall, which leaves a shadow line under it.
                let n = side * hs, fascia = 0.2
                let outN = obb.short * side
                emitBoard(&out.roofs, at(-hl, n), at(hl, n), ya: y(n), yb: y(n), out: outN, depth: fascia, id: board,
                          seed: sd, part: part)
                let ys = y(n) - fascia, yw = eaveY - 0.04
                roofQuad(&out.roofs, [P(at(-hl, n), ys), P(at(hl, n), ys), P(at(hl, side * hw), yw), P(at(-hl, side * hw), yw)],
                         facing: SIMD3(0, -1, 0), uv: [(0, 0), (Float(2 * hl), 0), (Float(2 * hl), 0.35), (0, 0.35)],
                         id: board, seed: sd, up: 0, part: part)
                // Barge boards down both verges.
                for end in [-1.0, 1.0] {
                    emitBoard(&out.roofs, at(end * hl, 0), at(end * hl, n), ya: y(0), yb: y(n), out: obb.long * end,
                              depth: 0.22, id: board, seed: sd, part: part)
                }
            }
            emitRidge(&out.roofs, at(-hl, 0), at(hl, 0), y: eaveY + rise + 0.03, id: ridge, seed: sd,
                      up: Float(hw / cosP), part: part)
        } else {
            let slope = rise / max(hw, 0.01)
            let cosP = 1 / sqrt(1 + slope * slope)
            // Overhang the outer edges as the rectangular roofs do; the cut
            // edges a neighbouring piece shares stay, so the pieces still meet.
            let reach = 0.3
            let roofed = overhang(ring, footprint: footprint, d: reach) ?? ring
            for side in [-1.0, 1.0] {
                let half = clipHalfPlane(roofed, normal: obb.short * side, origin: obb.centre)
                guard half.count >= 3 else { continue }
                emitRoofPolygon(&out.roofs, half, y: { roofY($0) + 0.03 }, uv: { p in
                    let d = p - obb.centre
                    return (Float(simd_dot(d, obb.long)), Float(abs(simd_dot(d, obb.short)) / cosP))
                }, id: cover, seed: sd, up: { p in Float((hw - abs(simd_dot(p - obb.centre, obb.short))) / cosP) }, part: part)
                // Boards along the outer edges, ridge tiles along the top.
                for i in half.indices {
                    let a = half[i], c = half[(i + 1) % half.count]
                    guard let n = outward(a, c) else { continue }
                    let da = abs(simd_dot(a - obb.centre, obb.short)), dc = abs(simd_dot(c - obb.centre, obb.short))
                    if da < 0.02, dc < 0.02 {
                        if side > 0 {
                            emitRidge(&out.roofs, a, c, y: eaveY + rise + 0.03, id: ridge, seed: sd,
                                      up: Float(hw / cosP), part: part)
                        }
                        continue
                    }
                    let gap = distanceToRing((a + c) / 2, footprint)
                    guard gap < 0.06 || abs(gap - reach) < 0.06 else { continue }
                    let ya = roofY(a) + 0.03, yc = roofY(c) + 0.03
                    emitBoard(&out.roofs, a, c, ya: ya, yb: yc, out: n, depth: abs(ya - yc) < 0.05 ? 0.2 : 0.22,
                              id: board, seed: sd, part: part)
                }
            }
        }

        // A church gets its west tower and spire (Melden's Sint-Martinus is
        // seen from the upper climb); the LiDAR height is the spire tip. A
        // town church's (over 1000 m²: Geraardsbergen's Sint-Bartholomeus)
        // is its nave's ridge, the thin spire too small to lift it: its
        // tower stands above the nave and the spire about as tall again.
        if b.kind == "church" {
            let town = area > 1000
            let ts = min(obb.halfShort * 2 * 0.8, town ? 8.5 : 6.5)
            let west = obb.long.x > 0 ? -1.0 : 1.0
            let c = obb.centre + obb.long * (west * (obb.halfLong - ts / 2))
            let towerTop = floorY + height * (town ? 1.2 : 0.68)
            let spireTop = floorY + height * (town ? 1.8 : 1.0)
            emitBox(&out.walls, centre: c, along: obb.long, halfA: ts / 2, halfB: ts / 2, y0: baseY, y1: towerTop,
                    floorY: floorY, style: style, eaves: true, ground: ground)
            let side = SIMD2(obb.long.y, -obb.long.x)
            let h2 = ts / 2 + 0.2
            let along: SIMD2<Double> = obb.long * h2
            let across: SIMD2<Double> = side * h2
            let corners: [SIMD2<Double>] = [c - along - across, c + along - across,
                                            c + along + across, c - along + across]
            let apex = SIMD3<Float>(Float(c.x), Float(spireTop), Float(-c.y))
            let slant = Float(simd_length(SIMD2(spireTop - towerTop, h2)))
            for k in 0..<4 {
                let p0 = corners[k], p1 = corners[(k + 1) % 4]
                let first = UInt32(out.roofs.vertexCount)
                let slate = RoofCover.slate.rawValue
                roofVertex(&out.roofs, P(p0, towerTop), (0, slant), id: slate, seed: sd, up: 0)
                roofVertex(&out.roofs, P(p1, towerTop), (Float(2 * h2), slant), id: slate, seed: sd, up: 0)
                roofVertex(&out.roofs, apex, (Float(h2), 0), id: slate, seed: sd, up: slant)
                out.roofs.tri(first, first + 1, first + 2, part: 1)
            }
        }

        // A chimney on most houses, in brick (or the white-wash).
        if !flat, !style.shed, rnd.unit() < 0.6 {
            let t = Double(rnd.range(-0.6, 0.6)) * obb.halfLong
            let c = obb.centre + obb.long * t + obb.short * (hw * 0.25)
            let y0 = roofY(c) - 0.6
            var stack = style
            if style.row != .painted || rnd.unit() < 0.5 { stack.row = .redBrick; stack.tint = 0 }
            emitBox(&out.walls, centre: c, along: obb.long, halfA: 0.28, halfB: 0.28, y0: y0, y1: ridgeY + 0.6,
                    style: stack, kind: .stack, ground: { _ in y0 + 0.6 })
        }
    }

    /// Whether riders see a wall at `mid` facing `facing`: some point of the
    /// route within 45 m lies in front of it, not only the nearest, so a
    /// wall turned to riders coming up the road counts too.
    static func seenFromRoute(_ mid: SIMD2<Double>, facing: SIMD2<Double>, s: Double, dist: Double,
                              corridor: RoadCorridor) -> Bool {
        guard dist < 45 else { return false }
        for ds in stride(from: -40.0, through: 40.0, by: 10) {
            let st = corridor.station(at: s + ds)
            let d = SIMD2(st.east, st.north) - mid
            let l = simd_length(d)
            if l < 45, simd_dot(facing, d) > 0.3 * l { return true }
        }
        return false
    }

    /// Terrain heights along a -> c, about a metre apart (`WallFrame.ground`).
    static func groundSamples(_ a: SIMD2<Double>, _ c: SIMD2<Double>, _ ground: (SIMD2<Double>) -> Double) -> [Double] {
        let n = max(1, Int(simd_distance(a, c).rounded(.up)))
        return (0...n).map { ground(a + (c - a) * (Double($0) / Double(n))) }
    }

    /// How far, in metres, the ground under a wall may stray from the
    /// straight line `emitFace` interpolates between two cuts.
    static let groundTolerance = 0.06

    /// The ground samples of `w` (distances along it) that a line through
    /// them needs to stay within `tolerance` of the ground everywhere
    /// (Douglas-Peucker), its ends left out: where `emitFace` cuts the wall
    /// so the height above the ground it writes (the damp foot, the green,
    /// the contact shade) follows a sag or a hump under a long blank wall.
    static func groundBreaks(_ w: WallFrame, tolerance: Double) -> [Double] {
        let g = w.ground, n = g.count
        guard n > 2 else { return [] }
        var keep = [Bool](repeating: false, count: n)
        var spans = [(0, n - 1)]
        while let (i, j) = spans.popLast() {
            var worst = tolerance, at = -1
            for k in (i + 1)..<j {
                let off = abs(g[k] - g[i] - (g[j] - g[i]) * Double(k - i) / Double(j - i))
                if off > worst { worst = off; at = k }
            }
            guard at > 0 else { continue }
            keep[at] = true
            spans += [(i, at), (at, j)]
        }
        return keep.indices.filter { keep[$0] }.map { w.len * Double($0) / Double(n - 1) }
    }

    // MARK: - Walls

    /// A wall in plan, from `a` along `dir` for `len` metres, facing out to
    /// its right; its top linear, or on a gable linear each side of
    /// `uRidge`; the ground under it sampled evenly along it.
    struct WallFrame {
        var a: SIMD2<Double>
        var dir: SIMD2<Double>
        var len: Double
        var top0: Double
        var top1: Double
        var uRidge: Double? = nil
        var topRidge = 0.0
        var floorY: Double
        var baseY: Double
        /// Terrain heights at u = len * k / (count - 1).
        var ground: [Double]
        /// False under no eaves (chimneys, garden walls): `emitPiece` then
        /// writes `noEaves` for the metres below the top, so the shader's
        /// eave shade and rain streaks stay off.
        var eaves = true

        /// Outward for counter-clockwise rings.
        var nrm: SIMD2<Double> { SIMD2(dir.y, -dir.x) }

        func top(_ u: Double) -> Double {
            guard let r = uRidge else { return top0 + (top1 - top0) * u / max(len, 1e-6) }
            return u <= r ? top0 + (topRidge - top0) * u / max(r, 1e-6)
                          : topRidge + (top1 - topRidge) * (u - r) / max(len - r, 1e-6)
        }

        var maxTop: Double { max(top0, top1, uRidge == nil ? -.infinity : topRidge) }

        func groundAt(_ u: Double) -> Double {
            guard ground.count > 1 else { return ground.first ?? baseY }
            let x = min(max(u / max(len, 1e-6), 0), 1) * Double(ground.count - 1)
            let i = min(Int(x), ground.count - 2), f = x - Double(i)
            return ground[i] + (ground[i + 1] - ground[i]) * f
        }
    }

    /// Windows and the door as cj_facade.jpg draws them (bake_materials.py
    /// `bake_facades`): the cell column, and the box in metres of the 3 m
    /// cell, from its lower left, that holds the frame, sill and lintel.
    enum OpeningCut {
        case upper, ground, narrow, door

        var col: Int {
            switch self {
            case .upper: return 0
            case .ground: return 1
            case .narrow, .door: return 2
            }
        }

        var u: (Double, Double) {
            switch self {
            case .upper, .ground: return (0.87, 2.13)
            case .narrow: return (2.03, 2.75)
            case .door: return (0.6, 1.67)
            }
        }

        var v: (Double, Double) {
            switch self {
            case .upper: return (0.83, 2.47)
            case .ground: return (0.88, 2.52)
            case .narrow: return (0.95, 2.16)
            case .door: return (0, 2.31)
            }
        }
    }

    /// A window or door on a wall: the box [u0, u1] x [y0, y1] showing
    /// `cut`, at its own height and stretched across by at most a few
    /// per cent, or, for a barn's big door, painted by the shader.
    struct Opening {
        var cut: OpeningCut
        var u0: Double, u1: Double, y0: Double, y1: Double
        /// `.timberDoor` or `.steelDoor` for a door `wallSurface` paints
        /// (`Paint.door`, its size in whole decimetres); nil for an atlas cut.
        var painted: WallKind? = nil
    }

    /// One brick course of cj_facade.jpg (38 to the 3 m cell): openings
    /// move up or down by whole courses so the brickwork keeps its line.
    static let brickCourse = 3.0 / 38

    /// `cut` centred at `centre` with its cell's floor at `base`, lowered by
    /// up to `drop` courses until all of it fits under the wall top; nil
    /// where it would run off the wall, a window into the plinth, or it
    /// comes within 0.3 m of an opening in `clear`.
    static func fit(_ cut: OpeningCut, _ w: WallFrame, style: Style, centre: Double, base: Double, drop: Int,
                    clear: [Opening]) -> Opening? {
        let width = (cut.u.1 - cut.u.0) * (cut == .door ? 1 : style.windowScale)
        for k in 0...drop {
            let b = base - Double(k) * brickCourse
            let o = Opening(cut: cut, u0: centre - width / 2, u1: centre + width / 2, y0: b + cut.v.0, y1: b + cut.v.1)
            guard o.u0 > 0.25, o.u1 < w.len - 0.25, cut == .door || o.y0 > w.floorY + style.plinthHeight + 0.03 else {
                return nil
            }
            guard o.y1 + 0.08 <= min(w.top(o.u0), w.top(o.u1)) else { continue }
            if clear.contains(where: { $0.u0 < o.u1 + 0.3 && o.u0 < $0.u1 + 0.3 && $0.y0 < o.y1 + 0.3 && o.y0 < $0.y1 + 0.3 }) {
                return nil
            }
            return o
        }
        return nil
    }

    /// Windows and the door on one wall: bays at the building's own pitch,
    /// a little jittered and some left blank (on a wall the road sees,
    /// `seen`, never two in a row, nor the first on a long one, nor every
    /// bay of its ground floor); upper windows over the ground ones; a small
    /// window high in a tall gable (always on a gable the road sees); the
    /// door, if any, in the bay nearest `door`. A window goes only where all
    /// of it fits under the wall top, lowered a few courses under a low eave
    /// (never into the plinth); on a seen wall a narrow one where the usual
    /// one won't fit.
    static func layoutOpenings(_ w: WallFrame, style: Style, eaveY: Double, door: Double?, front: Bool, seen: Bool = false,
                               rnd: inout WorldRandom) -> [Opening] {
        guard !style.shed, w.len >= 1.8 else { return [] }
        var out: [Opening] = []
        func place(_ cut: OpeningCut, centre: Double, base: Double, drop: Int = 0) -> Opening? {
            fit(cut, w, style: style, centre: centre, base: base, drop: drop, clear: out)
        }
        let storeys = max(1, Int(((w.maxTop - w.floorY) / 3 - 1e-6).rounded(.up)))
        let margin = 0.75
        let usable = w.len - 2 * margin
        if usable > 0.3 {
            let n = max(1, Int((usable / style.bayPitch).rounded()))
            let step = usable / Double(n)
            let doorBay = door.map { min(max(Int((($0 - margin) / step).rounded(.down)), 0), n - 1) }
            let chance = front ? style.windowChance : style.windowChance * 0.55
            var blankRun = seen && w.len >= 8 ? 1 : 0
            for k in 0..<n {
                let cu = margin + (Double(k) + 0.5 + Double(rnd.range(-0.08, 0.08))) * step
                var below = false
                // The last bay of a seen wall whose ground floor is still blank.
                let last = seen && k == n - 1 && !out.contains { $0.y0 < w.floorY + 2 }
                if k == doorBay, let o = place(.door, centre: cu, base: w.floorY) {
                    out.append(o)
                    below = true
                } else if rnd.unit() < chance || (seen && blankRun > 0) || last {
                    let cut: OpeningCut = rnd.unit() < 0.75 ? style.window : (style.window == .narrow ? .ground : .narrow)
                    if let o = place(cut, centre: cu, base: w.floorY, drop: 6)
                        ?? (seen && cut != .narrow ? place(.narrow, centre: cu, base: w.floorY, drop: 6) : nil) {
                        out.append(o)
                        below = true
                    }
                }
                blankRun = below ? 0 : blankRun + 1
                let upper: Float = (below ? (seen ? 1 : 0.9) : 0.3) * (front || seen ? 1 : 0.75)
                for s in 1..<storeys where rnd.unit() < upper {
                    // Upper floors: the plain upper window (its cell has no
                    // plinth painted in), sometimes a narrow one; where the
                    // road sees the wall, over every ground opening.
                    let cut: OpeningCut = rnd.unit() < 0.8 ? .upper : .narrow
                    if let o = place(cut, centre: cu, base: w.floorY + Double(s) * 3, drop: 6) { out.append(o) }
                }
            }
        }
        // A small window high in a tall gable, under the ridge.
        if let r = w.uRidge, w.topRidge - eaveY > 2.6, storeys > 1, rnd.unit() < 0.65 || seen {
            for s in stride(from: storeys - 1, through: 1, by: -1) {
                if let o = place(.narrow, centre: r, base: w.floorY + Double(s) * 3, drop: 6) {
                    out.append(o)
                    break
                }
            }
        }
        return out
    }

    /// A barn or shed wall: on the one nearest the route (`door`) a big
    /// timber or steel door, garage-sized on a small shed and a plain board
    /// door on a garden shed; along a long wall the road sees, small windows
    /// every 3 to 4 m clear of the door (never two missed in a row), high
    /// under the eave. Door sizes are whole decimetres (`Paint.door`).
    static func layoutShedOpenings(_ w: WallFrame, style: Style, door: Bool, seen: Bool,
                                   rnd: inout WorldRandom) -> [Opening] {
        var out: [Opening] = []
        if door, w.len >= 1.6 {
            let size: (Float, Float, Float, Float) = w.len >= 6 ? (2.6, 3.8, 2.6, 3.4)
                : w.len >= 3.4 ? (2.2, 2.6, 2.0, 2.3) : (0.85, 1.0, 1.85, 2.0)
            let width = (min(Double(rnd.range(size.0, size.1)), w.len - 0.8) * 10).rounded(.down) / 10
            let centre = min(max(w.len * Double(rnd.range(0.3, 0.7)), width / 2 + 0.4), w.len - width / 2 - 0.4)
            let u0 = centre - width / 2
            let room = min(w.top(u0), w.top(u0 + width)) - w.floorY - 0.3
            let height = (min(Double(rnd.range(size.2, size.3)), room) * 10).rounded(.down) / 10
            if width >= 0.8, height >= 1.7 {
                out.append(Opening(cut: .door, u0: u0, u1: u0 + width, y0: w.floorY, y1: w.floorY + height,
                                   painted: style.shedDoor))
            }
        }
        guard seen, w.len >= 5 else { return out }
        let pitch = Double(rnd.range(3.0, 4.2))
        var cu = 1.0 + Double(rnd.range(0, 0.8))
        var missed = false
        // Their heads just under the soffit (the eave, or the lower end of a
        // sloping top), their cells on whole courses from the floor.
        let courses = ((min(w.top0, w.top1) - 0.1 - OpeningCut.narrow.v.1 - w.floorY) / brickCourse).rounded(.down)
        let base = w.floorY + courses * brickCourse
        while cu < w.len - 0.9 {
            if rnd.unit() < 0.7 || missed,
               let o = fit(.narrow, w, style: style, centre: cu, base: base, drop: 8, clear: out) {
                out.append(o)
                missed = false
            } else {
                missed = true
            }
            cu += pitch
        }
        return out
    }

    /// One wall: a plinth band from below the ground to the plinth top,
    /// then the storeys: the blank wall of the building's row at true scale
    /// (from the building's own phase), around `openings`, which are cut
    /// from the window and door cells or painted. Nothing is stretched, so
    /// a ground floor on a slope keeps the shape of the floors above it.
    static func emitWall(_ m: inout MeshBuffer, _ w: WallFrame, style: Style, openings: [Opening], kind: WallKind = .wall) {
        guard w.len > 0.05 else { return }
        let row = style.row.rawValue
        let code = wallCode(kind, tint: style.tint)
        let holes = openings.map { o -> Hole in
            if let door = o.painted {
                let size = SIMD2(((o.u1 - o.u0) * 10).rounded(), ((o.y1 - o.y0) * 10).rounded())
                return Hole(rect: o, paint: .door(origin: SIMD2(o.u0, o.y0), size: size), code: wallCode(door, tint: style.tint))
            }
            let c = o.cut
            return Hole(rect: o, paint: .cell(col: c.col, row: row, origin: SIMD2(o.u0, o.y0), cu0: c.u.0,
                                              cuPerM: (c.u.1 - c.u.0) / (o.u1 - o.u0), cv0: c.v.0), code: code)
        }
        emitFace(&m, w, holes: holes, plinthTop: kind == .stack ? w.baseY : w.floorY + style.plinthHeight,
                 plinthCode: wallCode(style.plinth, tint: style.tint), code: code,
                 blank: .blank(row: row, phase: Double(style.seed) * 3), seed: style.seed)
    }

    /// A wall far from the route, in fewer triangles: the plinth band, then
    /// each storey a row of bays, some a whole upper-window cell stretched
    /// across to fit the wall but never up it, in blank wall.
    static func emitBayWall(_ m: inout MeshBuffer, _ w: WallFrame, style: Style, windows: Bool, rnd: inout WorldRandom) {
        guard w.len > 0.05 else { return }
        let row = style.row.rawValue
        let plinthTop = w.floorY + style.plinthHeight
        let code = wallCode(.wall, tint: style.tint)
        let bays = max(1, Int((w.len / 3).rounded()))
        let bw = w.len / Double(bays)
        let storeys = max(1, Int(((w.maxTop - w.floorY) / 3 - 1e-6).rounded(.up)))
        var cells: [Hole] = []
        for k in 0..<storeys {
            let base = w.floorY + Double(k) * 3
            for j in 0..<bays {
                let u0 = Double(j) * bw, u1 = u0 + bw
                let fits = min(w.top(u0), w.top(u1)) >= base + 2.55 && bw > 1.8
                if windows && !style.shed && fits && rnd.unit() < style.windowChance * 0.8 {
                    cells.append(Hole(rect: Opening(cut: .upper, u0: u0, u1: u1, y0: max(base, plinthTop), y1: base + 3),
                                      paint: .cell(col: 0, row: row, origin: SIMD2(u0, base), cu0: 0, cuPerM: 3 / bw, cv0: 0),
                                      code: code))
                }
            }
        }
        emitFace(&m, w, holes: cells, plinthTop: plinthTop, plinthCode: wallCode(style.plinth, tint: style.tint), code: code,
                 blank: .blank(row: row, phase: Double(style.seed) * 3), seed: style.seed)
    }

    /// An opening as `emitFace` draws it.
    struct Hole {
        var rect: Opening
        var paint: Paint
        var code: Float
    }

    /// One face of a wall, from its foot to its top, watertight: split along
    /// the wall at every hole edge, the ridge and where the ground under it
    /// bends (`groundBreaks`), each strip stacked in pieces (the plinth
    /// band, the wall above it and the holes across the strip), so the blank
    /// wall lies over no opening however they stack (an upper window over a
    /// wider door, a gable window over both). Every piece also takes the
    /// vertices its neighbours have on the edges they share, so no
    /// T-junction leaves a crack of background. The shader wraps the blank
    /// wall (`Paint.blank`), so it needs no cut where its texture repeats.
    static func emitFace(_ m: inout MeshBuffer, _ w: WallFrame, holes: [Hole], plinthTop: Double, plinthCode: Float,
                         code: Float, blank: Paint, seed: Float) {
        let y0 = w.baseY, y1 = w.maxTop + 0.01
        let band = min(max(plinthTop, y0), y1)
        let inside = holes.filter { $0.rect.u1 > 0 && $0.rect.u0 < w.len && $0.rect.y1 > y0 && $0.rect.y0 < y1 }
        var cuts = [0.0, w.len] + inside.flatMap { [max($0.rect.u0, 0), min($0.rect.u1, w.len)] }
        if let r = w.uRidge, r > 0, r < w.len { cuts.append(r) }
        // And where the ground bends, unless another cut is close by.
        let bends = groundBreaks(w, tolerance: groundTolerance)
        cuts += bends.filter { b in !cuts.contains { abs($0 - b) < 0.15 } }
        cuts.sort()
        var us = [0.0]
        for c in cuts where c - us[us.count - 1] > 1e-4 { us.append(c) }
        us[us.count - 1] = w.len
        // Each strip's pieces, bottom to top: (from, to, hole or nil, code).
        var strips: [[(ya: Double, yb: Double, hole: Int?, code: Float)]] = []
        for i in 0..<(us.count - 1) {
            let mid = (us[i] + us[i + 1]) / 2
            var pieces: [(ya: Double, yb: Double, hole: Int?, code: Float)] = []
            var ya = y0
            func blankTo(_ yb: Double) {
                if band > ya + 1e-4, band < yb - 1e-4 {
                    pieces.append((ya, band, nil, plinthCode))
                    pieces.append((band, yb, nil, code))
                } else if yb - ya > 1e-4 {
                    pieces.append((ya, yb, nil, ya < band - 1e-4 ? plinthCode : code))
                }
            }
            let across = inside.indices.filter { inside[$0].rect.u0 < mid && mid < inside[$0].rect.u1 }
            for k in across.sorted(by: { inside[$0].rect.y0 < inside[$1].rect.y0 }) {
                let h = inside[k].rect
                if h.y0 > ya { blankTo(min(h.y0, y1)) }
                let hb = max(h.y0, ya), ht = min(h.y1, y1)
                if ht - hb > 1e-4 { pieces.append((hb, ht, k, inside[k].code)) }
                ya = max(ya, ht)
            }
            if y1 > ya { blankTo(y1) }
            strips.append(pieces)
        }
        // The breaks on each line between strips: both strips' own.
        let breaks = strips.map { $0.flatMap { [$0.ya, $0.yb] } }
        let lines = (0..<us.count).map { i -> [Double] in
            Array(Set((i > 0 ? breaks[i - 1] : []) + (i < strips.count ? breaks[i] : []))).sorted()
        }
        for (i, pieces) in strips.enumerated() {
            let ua = us[i], ub = us[i + 1]
            for p in pieces {
                let right = lines[i + 1].filter { $0 > p.ya + 1e-6 && $0 < p.yb - 1e-6 }
                let left = lines[i].filter { $0 > p.ya + 1e-6 && $0 < p.yb - 1e-6 }
                let poly = [(ua, p.ya), (ub, p.ya)] + right.map { (ub, $0) } + [(ub, p.yb), (ua, p.yb)]
                    + left.reversed().map { (ua, $0) }
                emitPiece(&m, w, clipTop(poly, top: w.top), paint: p.hole.map { inside[$0].paint } ?? blank, code: p.code,
                          seed: seed, centred: !left.isEmpty)
            }
        }
    }

    /// What a wall piece shows, as texcoord 0 (`WorldShaders.wallSurface`).
    enum Paint {
        /// Cell (col, row) of cj_facade.jpg from cell metres (cu0, cv0) at
        /// `origin` (u, y), `cuPerM` cell metres per wall metre across and
        /// one per metre up.
        case cell(col: Int, row: Int, origin: SIMD2<Double>, cu0: Double, cuPerM: Double, cv0: Double)
        /// The blank cell of `row`, which the shader wraps every 3 m along
        /// (from `phase`) and up (from the floor): (2 + (u + phase) / 3,
        /// 32 + 64 row + (y - floor) / 3).
        case blank(row: Int, phase: Double)
        /// A door the shader paints, `size` whole decimetres from `origin`
        /// (u, y): 2 + 8 size + metres from its lower left.
        case door(origin: SIMD2<Double>, size: SIMD2<Double>)
    }

    /// Metres below the top `emitPiece` writes on a wall under no eaves.
    static let noEaves: Float = 30

    /// A convex wall-space polygon (u, y) from its lower left, showing
    /// `paint`: a fan from that corner, or, `centred` (when vertices lie
    /// along its left edge, in line with the corner), round its centre, so
    /// every edge piece has a triangle of its own. Every vertex gets the
    /// channels `WorldShaders.wallSurface` reads.
    static func emitPiece(_ m: inout MeshBuffer, _ w: WallFrame, _ poly: [(Double, Double)], paint: Paint, code: Float,
                          seed: Float, centred: Bool) {
        guard poly.count >= 3 else { return }
        let n = w.nrm
        func put(_ u: Double, _ y: Double) {
            let p = w.a + w.dir * u
            let uv: (Float, Float)
            switch paint {
            case let .cell(col, row, o, cu0, cuPerM, cv0):
                uv = atlasUV(col: col, row: row, fu: (cu0 + (u - o.x) * cuPerM) / 3, fv: (cv0 + y - o.y) / 3)
            case let .blank(row, phase):
                uv = (Float(2 + (u + phase) / 3), Float(32 + 64 * Double(row) + (y - w.floorY) / 3))
            case let .door(o, size):
                uv = (Float(2 + 8 * size.x + u - o.x), Float(2 + 8 * size.y + y - o.y))
            }
            m.vertex(Float(p.x), Float(y), Float(-p.y), Float(n.x), 0, Float(-n.y), uv.0, uv.1)
            m.texcoord2(Float(y - w.groundAt(u)), w.eaves ? Float(w.top(u) - y) : noEaves)
            m.texcoord3(code, seed)
        }
        let first = UInt32(m.vertexCount)
        for (u, y) in poly { put(u, y) }
        let k = UInt32(poly.count)
        if centred {
            put(poly.reduce(0) { $0 + $1.0 } / Double(poly.count), poly.reduce(0) { $0 + $1.1 } / Double(poly.count))
            for t in 0..<k { m.tri(first + k, first + t, first + (t + 1) % k) }
        } else {
            for t in 1..<(k - 1) { m.tri(first, first + t, first + t + 1) }
        }
    }

    @inline(__always)
    static func atlasUV(col: Int, row: Int, fu: Double, fv: Double) -> (Float, Float) {
        let inset = 0.006
        let u = (Double(col) + inset + fu * (1 - 2 * inset)) / 4
        let v = (Double(row) + inset + (1 - fv) * (1 - 2 * inset)) / 4
        return (Float(u), Float(v))
    }

    /// Clips a wall-space polygon (u, y) to y <= `top`, which must be
    /// linear over the polygon's span.
    static func clipTop(_ poly: [(Double, Double)], top: (Double) -> Double) -> [(Double, Double)] {
        func g(_ p: (Double, Double)) -> Double { top(p.0) - p.1 }
        var out: [(Double, Double)] = []
        for i in poly.indices {
            let p = poly[i], q = poly[(i + 1) % poly.count]
            let gp = g(p), gq = g(q)
            if gp >= 0 { out.append(p) }
            if (gp >= 0) != (gq >= 0) {
                let t = gp / (gp - gq)
                out.append((p.0 + (q.0 - p.0) * t, p.1 + (q.1 - p.1) * t))
            }
        }
        return out
    }

    /// Closed box (walls and top) in blank wall: chimneys, the church tower
    /// and garden walls. `ground` gives the height their foot meets; only
    /// the tower, under its spire, has `eaves`.
    static func emitBox(_ m: inout MeshBuffer, centre: SIMD2<Double>, along: SIMD2<Double>, halfA: Double, halfB: Double,
                        y0: Double, y1: Double, floorY: Double? = nil, style: Style, kind: WallKind = .wall,
                        eaves: Bool = false, ground: (SIMD2<Double>) -> Double) {
        let side = SIMD2<Double>(along.y, -along.x)
        let a: SIMD2<Double> = along * halfA
        let b: SIMD2<Double> = side * halfB
        let c0: SIMD2<Double> = centre - a - b
        let c1: SIMD2<Double> = centre + a - b
        let c2: SIMD2<Double> = centre + a + b
        let c3: SIMD2<Double> = centre - a + b
        var ring: [SIMD2<Double>] = [c0, c1, c2, c3]
        if signedArea(ring) < 0 { ring.reverse() }
        for i in 0..<4 {
            let p = ring[i], q = ring[(i + 1) % 4]
            let len = simd_distance(p, q)
            guard len > 1e-6 else { continue }
            var w = WallFrame(a: p, dir: (q - p) / len, len: len, top0: y1, top1: y1, floorY: floorY ?? y0, baseY: y0,
                              ground: groundSamples(p, q, ground))
            w.eaves = eaves
            emitWall(&m, w, style: style, openings: [], kind: kind)
        }
        let tris = earClip(ring)
        let first = UInt32(m.vertexCount)
        let code = wallCode(kind, tint: style.tint)
        for p in ring {
            let uv = atlasUV(col: 3, row: style.row.rawValue, fu: 0.5, fv: 0.5)
            m.vertex(Float(p.x), Float(y1), Float(-p.y), 0, 1, 0, uv.0, uv.1)
            m.texcoord2(Float(y1 - ground(p)), noEaves)
            m.texcoord3(code, style.seed)
        }
        for (a, b, c) in tris { m.tri(first + UInt32(a), first + UInt32(b), first + UInt32(c)) }
    }

    // MARK: - Roofs

    /// A roof vertex with the channels `WorldShaders.roofSurface` reads:
    /// texcoord 0 = (metres along the eaves, metres down the slope),
    /// texcoord 1 = (`RoofCover` or `RoofTrim` id + seed / 2, metres up
    /// from the eave line). Every roof writer goes through here.
    @discardableResult
    @inline(__always)
    static func roofVertex(_ m: inout MeshBuffer, _ p: SIMD3<Float>, _ uv: (Float, Float), id: Int, seed: Float,
                           up: Float) -> UInt32 {
        let i = m.vertex(p.x, p.y, p.z, 0, 1, 0, uv.0, uv.1)
        m.texcoord2(Float(id) + seed * 0.5, up)
        return i
    }

    /// Upward-facing triangulated roof polygon.
    static func emitRoofPolygon(_ m: inout MeshBuffer, _ poly: [SIMD2<Double>], y: (SIMD2<Double>) -> Double,
                                uv: (SIMD2<Double>) -> (Float, Float), id: Int, seed: Float,
                                up: (SIMD2<Double>) -> Float, part: Int) {
        let tris = earClip(poly)
        guard !tris.isEmpty else { return }
        let first = UInt32(m.vertexCount)
        for p in poly {
            roofVertex(&m, SIMD3(Float(p.x), Float(y(p)), Float(-p.y)), uv(p), id: id, seed: seed, up: up(p))
        }
        for (a, b, c) in tris {
            m.tri(first + UInt32(a), first + UInt32(b), first + UInt32(c), part: part)
        }
    }

    /// A quad wound to face `n` (as `emitPropBox` does).
    static func roofQuad(_ m: inout MeshBuffer, _ p: [SIMD3<Float>], facing n: SIMD3<Float>, uv: [(Float, Float)],
                         id: Int, seed: Float, up: Float, part: Int) {
        let first = UInt32(m.vertexCount)
        for k in 0..<4 { roofVertex(&m, p[k], uv[k], id: id, seed: seed, up: up) }
        if simd_dot(simd_cross(p[1] - p[0], p[2] - p[0]), n) >= 0 {
            m.quad(first, first + 1, first + 2, first + 3, part: part)
        } else {
            m.quad(first, first + 3, first + 2, first + 1, part: part)
        }
    }

    /// A board `depth` deep hanging from the roof edge a -> c (roof heights
    /// ya, yb there) and standing `lip` above it, facing `out` in plan: a
    /// fascia under an eave, a barge board down a verge. It gives the roof
    /// its thickness at the edge.
    static func emitBoard(_ m: inout MeshBuffer, _ a: SIMD2<Double>, _ c: SIMD2<Double>, ya: Double, yb: Double,
                          out: SIMD2<Double>, depth: Double, lip: Double = 0.03, id: Int, seed: Float, part: Int) {
        let len = Float(simd_distance(a, c))
        guard len > 0.05 else { return }
        func P(_ p: SIMD2<Double>, _ y: Double) -> SIMD3<Float> { SIMD3(Float(p.x), Float(y), Float(-p.y)) }
        let h = Float(depth + lip)
        roofQuad(&m, [P(a, ya - depth), P(c, yb - depth), P(c, yb + lip), P(a, ya + lip)],
                 facing: SIMD3(Float(out.x), 0, Float(-out.y)), uv: [(0, h), (len, h), (len, 0), (0, 0)],
                 id: id, seed: seed, up: 0, part: part)
    }

    /// Half-round ridge tiles along a -> c, their axis at `y` (the ridge
    /// line), wrapping a little past the horizontal to meet the slopes, with
    /// closed ends. The uv takes a pantile's crown across and its courses
    /// along, so the caps overlap like the real ones.
    static func emitRidge(_ m: inout MeshBuffer, _ a: SIMD2<Double>, _ c: SIMD2<Double>, y: Double, id: Int,
                          seed: Float, up: Float, part: Int) {
        let len = Float(simd_distance(a, c))
        guard len > 0.2 else { return }
        let d = (c - a) / Double(len)
        let side = SIMD3<Float>(Float(d.y), 0, Float(d.x))
        let axis = SIMD3<Float>(Float(d.x), 0, Float(-d.y))
        let r: Float = 0.12, segs = 5
        let ends = [SIMD3<Float>(Float(a.x), Float(y) - 0.05, Float(-a.y)), SIMD3<Float>(Float(c.x), Float(y) - 0.05, Float(-c.y))]
        func ring(_ j: Int) -> SIMD3<Float> {
            let ang = -0.44 + Float(j) / Float(segs) * (Float.pi + 0.88)
            return side * (cos(ang) * r) + SIMD3(0, sin(ang) * r, 0)
        }
        let first = UInt32(m.vertexCount)
        for (k, e) in ends.enumerated() {
            for j in 0...segs {
                roofVertex(&m, e + ring(j), (0.01 + 0.165 * Float(j) / Float(segs), Float(k) * len), id: id, seed: seed, up: up)
            }
        }
        for j in 0..<segs {
            let a0 = first + UInt32(j), a1 = a0 + 1, b0 = first + UInt32(segs + 1 + j), b1 = b0 + 1
            m.tri(a0, b0, a1, part: part)
            m.tri(a1, b0, b1, part: part)
        }
        // End caps: fans facing out along the ridge.
        for (k, e) in ends.enumerated() {
            let n = k == 0 ? -axis : axis
            for j in 0..<segs {
                let p = [e, e + ring(j), e + ring(j + 1)]
                let f = UInt32(m.vertexCount)
                for q in p { roofVertex(&m, q, (0.09, 0), id: id, seed: seed, up: up) }
                if simd_dot(simd_cross(p[1] - p[0], p[2] - p[0]), n) >= 0 {
                    m.tri(f, f + 1, f + 2, part: part)
                } else {
                    m.tri(f, f + 2, f + 1, part: part)
                }
            }
        }
    }

    /// Outward unit normal (in plan) of the edge a -> c of a counter-clockwise ring.
    static func outward(_ a: SIMD2<Double>, _ c: SIMD2<Double>) -> SIMD2<Double>? {
        let e = c - a, l = simd_length(e)
        return l > 0.05 ? SIMD2(e.y, -e.x) / l : nil
    }

    /// `piece` with each edge that lies on `footprint` moved out by `d`;
    /// new corners are where neighbouring edge lines meet. Edges cut inside
    /// the footprint (shared with a neighbouring piece) stay, so where one
    /// runs on from an outer edge the outline steps. Nil when the result
    /// would not be a sound outline (a corner moving far, or the area
    /// shrinking).
    static func overhang(_ piece: [SIMD2<Double>], footprint: [SIMD2<Double>], d: Double) -> [SIMD2<Double>]? {
        let n = piece.count
        guard n >= 3 else { return nil }
        let shift = (0..<n).map { i -> Double in
            let a = piece[i], b = piece[(i + 1) % n]
            return distanceToRing((a + b) / 2, footprint) < 0.02 ? d : 0
        }
        var out: [SIMD2<Double>] = []
        for i in 0..<n {
            let j = (i + n - 1) % n
            let p0 = piece[j], p1 = piece[i], p2 = piece[(i + 1) % n]
            guard let n0 = outward(p0, p1), let n1 = outward(p1, p2) else { return nil }
            let e0 = p1 - p0, e1 = p2 - p1
            let a0 = p1 + n0 * shift[j], a1 = p1 + n1 * shift[i]
            let cr = e0.x * e1.y - e0.y * e1.x
            var corner: [SIMD2<Double>]
            if abs(cr) < 1e-6 * simd_length(e0) * simd_length(e1) {
                // Straight on: one point, or a step where only one side moves.
                corner = abs(shift[j] - shift[i]) < 1e-9 ? [a0] : [a0, a1]
            } else {
                let q = a1 - a0
                corner = [a0 + e0 * ((q.x * e1.y - q.y * e1.x) / cr)]
            }
            guard corner.allSatisfy({ simd_distance($0, p1) <= 3 * d + 1e-9 }) else { return nil }
            out += corner
        }
        guard signedArea(out) > signedArea(piece) else { return nil }
        return out
    }

    /// Distance from `p` to the nearest edge of a closed ring.
    static func distanceToRing(_ p: SIMD2<Double>, _ ring: [SIMD2<Double>]) -> Double {
        var best = Double.infinity
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            let e = b - a
            let t = min(max(simd_dot(p - a, e) / max(simd_length_squared(e), 1e-12), 0), 1)
            best = min(best, simd_distance(p, a + e * t))
        }
        return best
    }

    /// Upward-facing triangulated polygon.
    static func emitPolygon(_ m: inout MeshBuffer, _ poly: [SIMD2<Double>], y: (SIMD2<Double>) -> Double,
                            uv: (SIMD2<Double>) -> (Float, Float), part: Int) {
        let tris = earClip(poly)
        guard !tris.isEmpty else { return }
        let first = UInt32(m.vertexCount)
        for p in poly {
            let t = uv(p)
            m.vertex(Float(p.x), Float(y(p)), Float(-p.y), 0, 1, 0, t.0, t.1)
        }
        // Counter-clockwise in (east, north) is counter-clockwise seen from
        // above in scene space too, so the triangles face up as they are.
        for (a, b, c) in tris {
            m.tri(first + UInt32(a), first + UInt32(b), first + UInt32(c), part: part)
        }
    }

    // MARK: - Props

    /// Brick walls just off the road (on the Koppenberg, beside the farm on
    /// the right where the cobbles end).
    static func buildSummitWall(_ out: inout Output, corridor: RoadCorridor) {
        for (span, side) in corridor.art.walls {
            buildWall(&out, corridor: corridor, from: span.lowerBound, to: span.upperBound, side: side)
        }
    }

    private static func buildWall(_ out: inout Output, corridor: RoadCorridor, from s0: Double, to s1: Double,
                                  side: Double) {
        var prev: (SIMD2<Double>, Double)?
        var s = s0
        while s <= s1 + 0.01 {
            let st = corridor.station(at: s)
            let p = st.point(lateral: side * (st.halfWidth + 0.55))
            let ground = Double(corridor.terrain.height(east: p.east, north: p.north))
            let here = SIMD2(p.east, p.north)
            if let (a, ga) = prev {
                let mid = (a + here) / 2
                let along = simd_normalize(here - a)
                let half = simd_length(here - a) / 2 + 0.01
                let y0 = min(ga, ground) - 0.3
                emitBox(&out.walls, centre: mid, along: along, halfA: half, halfB: 0.15, y0: y0,
                        y1: max(ga, ground) + 1.7, style: Style(row: .redBrick, pantile: false, pitchDeg: 0, shed: true),
                        ground: { Double(corridor.terrain.height(east: $0.x, north: $0.y)) })
            }
            prev = (here, ground)
            s += 3
        }
    }

    /// Dry-stone retaining walls at the carriageway edge (the Muur's park
    /// lane): a 0.35 m thick face from below the road up to the bank 1.5 m
    /// behind it, never more than the run's height above the road, in 1.5 m
    /// pieces. The face's slabs are `WallKind.dryStone`'s.
    static func buildStoneWalls(_ out: inout Output, corridor: RoadCorridor) {
        let style = Style(row: .cream, pantile: false, pitchDeg: 0, shed: true)
        for run in corridor.art.stoneWalls {
            var prev: (p: SIMD2<Double>, road: Double, top: Double)?
            var s = run.span.lowerBound
            while s <= run.span.upperBound + 0.01 {
                let st = corridor.station(at: s)
                let edge = run.side * (st.halfWidth + 0.2)
                let road = corridor.roadHeight(st, lateral: edge)
                let c = st.point(lateral: run.side * (st.halfWidth + 0.375))
                let back = st.point(lateral: run.side * (st.halfWidth + 1.7))
                let bank = Double(corridor.terrain.height(east: back.east, north: back.north))
                let top = road + min(run.height, max(bank - road, 0.3))
                let here = SIMD2(c.east, c.north)
                if let a = prev, simd_distance(a.p, here) > 0.05 {
                    let foot = min(a.road, road)
                    emitBox(&out.walls, centre: (a.p + here) / 2, along: simd_normalize(here - a.p),
                            halfA: simd_distance(a.p, here) / 2 + 0.01, halfB: 0.175, y0: foot - 0.3,
                            y1: (a.top + top) / 2, style: style, kind: .dryStone, ground: { _ in foot })
                }
                prev = (here, road, top)
                s += 1.5
            }
        }
    }

    /// Street lamps leaning over the road (black lanterns along the left of
    /// the Steengat; grey and LED ones on the Kwaremont).
    static func buildLamps(_ out: inout Output, corridor: RoadCorridor) {
        for run in corridor.art.lamps {
            var s = run.span.lowerBound
            while s < run.span.upperBound {
                buildLamp(&out, corridor: corridor, at: s, side: run.side, style: run.style)
                s += run.spacing
            }
        }
    }

    private static func buildLamp(_ out: inout Output, corridor: RoadCorridor, at s: Double, side: Double,
                                  style: CourseArt.LampStyle) {
        let st = corridor.station(at: s)
        let lat = side * (st.halfWidth + (style == .curvedGrey ? 0.7 : style == .postLantern ? 1.4 : 0.4))
        let p = st.point(lateral: lat)
        let ground = Float(corridor.terrain.height(east: p.east, north: p.north))
        let base = SIMD3<Float>(Float(p.east), ground - 0.2, Float(-p.north))
        let toRoad = SIMD3<Float>(Float(-side * st.rightE), 0, Float(side * st.rightN))
        switch style {
        case .curvedBlack:
            let top = base + SIMD3(0, 5.2, 0)
            var m = MeshBuffer(parts: 2)
            TreeArchetype.tube(&m, base, top, 0.075, 0.05, sides: 7, height: 100)
            // The curved arm over the road, in short straight pieces.
            var prevP = top
            for k in 1...5 {
                let a = Float(k) / 5 * 1.4
                let q = top + toRoad * (sin(a) * 0.8) + SIMD3(0, (1 - cos(a)) * -0.05 + sin(a) * 0.35, 0)
                TreeArchetype.tube(&m, prevP, q, 0.045, 0.04, sides: 5, height: 100)
                prevP = q
            }
            // Lantern: a short dark cone over a pale glass.
            TreeArchetype.tube(&m, prevP + SIMD3(0, 0.05, 0), prevP - SIMD3(0, 0.28, 0), 0.06, 0.22, sides: 8, height: 100)
            appendParts(&out.props, m, map: [0: PropPart.darkMetal.rawValue])
            var g = MeshBuffer(parts: 1)
            TreeArchetype.tube(&g, prevP - SIMD3(0, 0.26, 0), prevP - SIMD3(0, 0.36, 0), 0.17, 0.12, sides: 8, height: 100)
            appendParts(&out.props, g, map: [0: PropPart.lampGlass.rawValue])
        case .curvedGrey:
            // A tall tapered post bending over into a long arm, a slim head.
            let top = base + SIMD3(0, 7.4, 0)
            var m = MeshBuffer(parts: 1)
            TreeArchetype.tube(&m, base, top, 0.09, 0.055, sides: 7, height: 100)
            var prevP = top
            for k in 1...6 {
                let a = Float(k) / 6 * 1.45
                let q = top + toRoad * ((1 - cos(a)) * 1.25) + SIMD3(0, sin(a) * 0.55, 0)
                TreeArchetype.tube(&m, prevP, q, 0.05, 0.045, sides: 5, height: 100)
                prevP = q
            }
            let tip = prevP + toRoad * 0.55
            TreeArchetype.tube(&m, prevP, tip, 0.07, 0.05, sides: 6, height: 100)
            appendParts(&out.props, m, map: [0: PropPart.greyMetal.rawValue])
            var g = MeshBuffer(parts: 1)
            TreeArchetype.tube(&g, prevP + toRoad * 0.1 - SIMD3(0, 0.05, 0), tip - SIMD3(0, 0.05, 0), 0.05, 0.04,
                               sides: 6, height: 100)
            appendParts(&out.props, g, map: [0: PropPart.lampGlass.rawValue])
        case .ledBlack:
            // A slim black post, a short straight arm and a flat LED head.
            let top = base + SIMD3(0, 5.6, 0)
            var m = MeshBuffer(parts: 1)
            TreeArchetype.tube(&m, base, top, 0.07, 0.05, sides: 6, height: 100)
            let armEnd = top + toRoad * 0.45 + SIMD3(0, 0.08, 0)
            TreeArchetype.tube(&m, top - SIMD3(0, 0.05, 0), armEnd, 0.035, 0.035, sides: 5, height: 100)
            let along = SIMD3<Float>(Float(st.dirE), 0, Float(-st.dirN))
            let headC = armEnd + toRoad * 0.3
            emitPropBox(&m, centre: headC, x: toRoad, z: along, half: SIMD3(0.32, 0.04, 0.13))
            appendParts(&out.props, m, map: [0: PropPart.darkMetal.rawValue])
            var g = MeshBuffer(parts: 1)
            emitPropBox(&g, centre: headC - SIMD3(0, 0.045, 0), x: toRoad, z: along, half: SIMD3(0.26, 0.008, 0.09))
            appendParts(&out.props, g, map: [0: PropPart.lampGlass.rawValue])
        case .postLantern:
            // A black post with a collar near its foot, and on top a
            // four-sided lantern: base plate, corner bars round the glass
            // and a pyramid cap.
            let top = base + SIMD3(0, 3.7, 0)
            let along = SIMD3<Float>(Float(st.dirE), 0, Float(-st.dirN))
            var m = MeshBuffer(parts: 1)
            TreeArchetype.tube(&m, base, top, 0.08, 0.05, sides: 8, height: 100)
            TreeArchetype.tube(&m, base + SIMD3(0, 0.2, 0), base + SIMD3(0, 0.8, 0), 0.11, 0.09, sides: 8, height: 100)
            emitPropBox(&m, centre: top + SIMD3(0, 0.03, 0), x: toRoad, z: along, half: SIMD3(0.16, 0.03, 0.16))
            for (a, b) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
                emitPropBox(&m, centre: top + toRoad * (a * 0.15) + along * (b * 0.15) + SIMD3(0, 0.31, 0),
                            x: toRoad, z: along, half: SIMD3(0.016, 0.26, 0.016))
            }
            TreeArchetype.tube(&m, top + SIMD3(0, 0.56, 0), top + SIMD3(0, 0.84, 0), 0.25, 0.03, sides: 4, height: 100)
            appendParts(&out.props, m, map: [0: PropPart.darkMetal.rawValue])
            var g = MeshBuffer(parts: 1)
            emitPropBox(&g, centre: top + SIMD3(0, 0.31, 0), x: toRoad, z: along, half: SIMD3(0.13, 0.25, 0.13))
            appendParts(&out.props, g, map: [0: PropPart.lampGlass.rawValue])
        }
    }

    /// An axis-aligned box in the frame (x, up, z) for small props; `half`
    /// is its half-size along each.
    static func emitPropBox(_ m: inout MeshBuffer, centre c: SIMD3<Float>, x: SIMD3<Float>, z: SIMD3<Float>,
                            half h: SIMD3<Float>) {
        let y = SIMD3<Float>(0, 1, 0)
        let axes: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, Float, Float, Float)] = [
            (x, y, z, h.x, h.y, h.z), (-x, z, y, h.x, h.z, h.y), (y, z, x, h.y, h.z, h.x),
            (-y, x, z, h.y, h.x, h.z), (z, x, y, h.z, h.x, h.y), (-z, y, x, h.z, h.y, h.x),
        ]
        for (n, u, v, hn, hu, hv) in axes {
            let f = c + n * hn
            let first = UInt32(m.vertexCount)
            for (a, b) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
                let q = f + u * (a * hu) + v * (b * hv)
                m.vertex(q.x, q.y, q.z, n.x, n.y, n.z, a * hu, b * hv)
            }
            // Wind so the face looks along n.
            if simd_dot(simd_cross(u, v), n) > 0 {
                m.quad(first, first + 1, first + 2, first + 3)
            } else {
                m.quad(first, first + 3, first + 2, first + 1)
            }
        }
    }

    /// Wooden posts and two strands of wire along the open, upper climb and
    /// the summit plateau.
    static func buildFences(_ out: inout Output, corridor: RoadCorridor, sideRoads: RoadBuilder.SideRoadMask? = nil) {
        for run in corridor.art.fences {
            let s0 = run.span.lowerBound, s1 = run.span.upperBound, side = run.side
            var prevTop: [SIMD3<Float>] = []
            var s = s0
            var r = WorldRandom(seed: UInt64(s0))
            while s <= s1 {
                let st = corridor.station(at: s)
                let verge = side > 0 ? st.vergeRight : st.vergeLeft
                let o = min(1.6, max(verge - 0.5, 0.4))
                let p = RoadBuilder.vergePoint(corridor, st, side: side, offset: o)
                if sideRoads?.covers(east: p.east, north: p.north, margin: 0.5) == true {
                    prevTop = []
                    s += Double(r.range(2.6, 3.2))
                    continue
                }
                let base = SIMD3<Float>(Float(p.east), Float(p.y) - 0.15, Float(-p.north))
                let lean = SIMD3<Float>(r.range(-0.04, 0.04), 1, r.range(-0.04, 0.04))
                let top = base + lean * 1.35
                var m = MeshBuffer(parts: 1)
                TreeArchetype.tube(&m, base, top, 0.055, 0.05, sides: 4, height: 100)
                appendParts(&out.props, m, map: [0: PropPart.wood.rawValue])
                let wires = [base + lean * 0.75, base + lean * 1.2]
                if prevTop.count == 2 {
                    for k in 0..<2 {
                        var w = MeshBuffer(parts: 1)
                        TreeArchetype.tube(&w, prevTop[k], wires[k] + SIMD3(0, -0.01, 0), 0.006, 0.006, sides: 3, height: 100)
                        appendParts(&out.props, w, map: [0: PropPart.wire.rawValue])
                    }
                }
                prevTop = wires
                s += Double(r.range(2.6, 3.2))
            }
        }
    }

    /// Post-and-rail paddock fences: square posts about 2.8 m apart and two
    /// rails (the Paterberg's dark-stained paddock fence along its upper
    /// ramp carries an electric wire on white insulators above them, as in
    /// the 2011 and 2014 photos).
    static func buildRails(_ out: inout Output, corridor: RoadCorridor, sideRoads: RoadBuilder.SideRoadMask? = nil) {
        for run in corridor.art.rails {
            let s0 = run.span.lowerBound, s1 = run.span.upperBound, side = run.side
            let part: PropPart, railHeights: [Float]
            switch run.paint {
            case .darkStain: part = .darkWood; railHeights = [0.5, 0.95]
            case .white: part = .whitePaint; railHeights = [0.45, 0.9]
            case .paleTimber: part = .wood; railHeights = [0.55, 1.05]
            }
            let electric = run.paint == .darkStain
            let wireY: Float = 1.25
            var prev: (base: SIMD3<Float>, s: Double)?
            var prevInsulator: SIMD3<Float>?
            var s = s0
            var r = WorldRandom(seed: UInt64(s0 * 7 + 3))
            while s <= s1 + 0.01 {
                let st = corridor.station(at: s)
                let verge = side > 0 ? st.vergeRight : st.vergeLeft
                let o = min(1.4, max(verge - 0.5, 0.5))
                let p = RoadBuilder.vergePoint(corridor, st, side: side, offset: o)
                if sideRoads?.covers(east: p.east, north: p.north, margin: 0.5) == true {
                    prev = nil
                    prevInsulator = nil
                    s += Double(r.range(2.6, 3.0))
                    continue
                }
                let base = SIMD3<Float>(Float(p.east), Float(p.y) - 0.15, Float(-p.north))
                let along = SIMD3<Float>(Float(st.dirE), 0, Float(-st.dirN))
                let across = SIMD3<Float>(Float(st.rightE), 0, Float(-st.rightN))
                let top = electric ? wireY + 0.08 : railHeights.last! + 0.12
                var m = MeshBuffer(parts: 1)
                emitPropBox(&m, centre: base + SIMD3(0, (top + 0.15) / 2, 0), x: along, z: across,
                            half: SIMD3(0.06, (top + 0.15) / 2, 0.06))
                if electric {
                    // A white insulator on the field side of each post, the
                    // wire running through them.
                    let q = base + SIMD3(0, wireY + 0.15, 0) + across * (0.085 * Float(side))
                    var ins = MeshBuffer(parts: 1)
                    TreeArchetype.tube(&ins, q - SIMD3(0, 0.035, 0), q + SIMD3(0, 0.035, 0), 0.022, 0.016, sides: 6, height: 100)
                    appendParts(&out.props, ins, map: [0: PropPart.whitePaint.rawValue])
                    if let a = prevInsulator {
                        var w = MeshBuffer(parts: 1)
                        TreeArchetype.tube(&w, a, q - SIMD3(0, 0.004, 0), 0.0035, 0.0035, sides: 3, height: 100)
                        appendParts(&out.props, w, map: [0: PropPart.wire.rawValue])
                    }
                    prevInsulator = q
                }
                if let prev {
                    for h in railHeights {
                        let a = prev.base + SIMD3(0, h + 0.15, 0), b = base + SIMD3(0, h + 0.15, 0)
                        let d = b - a, len = simd_length(d)
                        guard len > 0.1 else { continue }
                        let dir = d / len
                        let side3 = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), dir))
                        // Rails sit on the road side of the posts.
                        // `side3` points left of travel.
                        emitPropBox(&m, centre: (a + b) / 2 + side3 * 0.07 * Float(side), x: dir, z: side3,
                                    half: SIMD3(len / 2 + 0.05, 0.05, 0.018))
                    }
                }
                appendParts(&out.props, m, map: [0: part.rawValue])
                prev = (base, s)
                s += Double(r.range(2.6, 3.0))
            }
        }
    }

    /// Utility poles beside the road with three wires sagging between them
    /// (the Paterberg's low-voltage line on concrete poles, wooden ones on
    /// the Kwaremont).
    static func buildPoles(_ out: inout Output, corridor: RoadCorridor) {
        for run in corridor.art.poles {
            let side = run.side
            let poleH: Float = run.kind == .concrete ? 8.5 : 7.5
            var prevTops: [SIMD3<Float>] = []
            var s = run.span.lowerBound
            var r = WorldRandom(seed: UInt64(run.span.lowerBound * 13 + 5))
            while s <= run.span.upperBound + 0.01 {
                let st = corridor.station(at: s)
                let verge = side > 0 ? st.vergeRight : st.vergeLeft
                let o = min(2.2, max(verge - 0.6, 0.9))
                let p = RoadBuilder.vergePoint(corridor, st, side: side, offset: o)
                let base = SIMD3<Float>(Float(p.east), Float(p.y) - 0.3, Float(-p.north))
                let lean = SIMD3<Float>(r.range(-0.012, 0.012), 1, r.range(-0.012, 0.012))
                let top = base + lean * (poleH + 0.3)
                var m = MeshBuffer(parts: 1)
                if run.kind == .concrete {
                    // Tapered, square-ish: a four-sided tube.
                    TreeArchetype.tube(&m, base, top, 0.14, 0.08, sides: 4, height: 100)
                } else {
                    TreeArchetype.tube(&m, base, top, 0.12, 0.1, sides: 7, height: 100)
                }
                // A cross-arm with three insulators.
                let across = SIMD3<Float>(Float(st.rightE), 0, Float(-st.rightN))
                let armY = top - SIMD3(0, 0.35, 0)
                TreeArchetype.tube(&m, armY - across * 0.55, armY + across * 0.55, 0.035, 0.035, sides: 4, height: 100)
                appendParts(&out.props, m, map: [0: run.kind == .concrete ? PropPart.concrete.rawValue : PropPart.darkWood.rawValue])
                let tops = [-0.45, 0.0, 0.45].map { armY + across * Float($0) + SIMD3(0, 0.12, 0) }
                var ins = MeshBuffer(parts: 1)
                for q in tops { TreeArchetype.tube(&ins, q - SIMD3(0, 0.12, 0), q, 0.03, 0.025, sides: 5, height: 100) }
                appendParts(&out.props, ins, map: [0: PropPart.lampGlass.rawValue])
                if prevTops.count == tops.count {
                    for k in tops.indices {
                        var w = MeshBuffer(parts: 1)
                        // Sagging wire in a few straight pieces.
                        let a = prevTops[k], b = tops[k]
                        let sag = 0.012 * simd_length(b - a)
                        var last = a
                        for j in 1...6 {
                            let f = Float(j) / 6
                            let q = a + (b - a) * f - SIMD3(0, 4 * sag * f * (1 - f), 0)
                            TreeArchetype.tube(&w, last, q, 0.008, 0.008, sides: 3, height: 100)
                            last = q
                        }
                        appendParts(&out.props, w, map: [0: PropPart.wire.rawValue])
                    }
                }
                prevTops = tops
                s += run.spacing * Double(r.range(0.92, 1.08))
            }
        }
    }

    static func appendParts(_ dst: inout MeshBuffer, _ src: MeshBuffer, map: [Int: Int]) {
        var moved = MeshBuffer(parts: dst.parts.count)
        moved.positions = src.positions; moved.normals = src.normals; moved.uvs = src.uvs
        for (from, to) in map where from < src.parts.count { moved.parts[to] = src.parts[from] }
        dst.append(moved, sx: 1, sy: 1, sz: 1, yaw: 0, tx: 0, ty: 0, tz: 0)
    }

    // MARK: - Signs, grates and street furniture

    /// A cell of the sign atlas (cj_signs_map.json, baked with cj_signs.png
    /// by scripts/courses/textures/bake_signs.py).
    struct SignCell: Decodable, Sendable {
        let key: String
        /// "rect", "tri", "triDown" or "disc": the outline the face is cut to.
        let shape: String
        /// Width and height, metres.
        let w: Double
        let h: Double
        /// (u0, v0, u1, v1), v down.
        let uv: [Float]

        /// The middle of the cell: a plain paint cell's colour.
        var centre: (Float, Float) { ((uv[0] + uv[2]) / 2, (uv[1] + uv[3]) / 2) }
    }

    /// The atlas's cells by key, read once; empty without the map (no signs
    /// are built then).
    static let signCells: [String: SignCell] = {
        guard let url = Bundle.main.url(forResource: "cj_signs_map", withExtension: "json")
                ?? Bundle.main.url(forResource: "cj_signs_map", withExtension: "json", subdirectory: "CourseTextures"),
              let data = try? Data(contentsOf: url),
              let cells = try? JSONDecoder().decode([SignCell].self, from: data) else { return [:] }
        return Dictionary(cells.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }()

    /// Plates on galvanised poles (or a bracket on a wall), facing riders
    /// coming up (or, `facesDownhill`, those coming down) and turned a
    /// little towards the road; backs and poles galvanised. Each face is cut
    /// to its plate's outline, so the atlas needs no alpha test. Plates hang
    /// from 2 m up, over the broadcast camera's moto; on a wall from 2.6 m
    /// (lower where the eaves would cut them), `wallBracket` out from the
    /// footprint wall `wallMount` finds, or on a pole where it finds none,
    /// so no plate hangs in the air. Built after the roofs.
    static func buildSigns(_ out: inout Output, corridor: RoadCorridor, scenery: SceneryFile?,
                           cells: [String: SignCell] = signCells) {
        for post in corridor.art.signs {
            let plates = post.plates.compactMap { cells[$0] }
            guard !plates.isEmpty else { continue }
            let st = corridor.station(at: post.s)
            let n = signNormal(post, at: st)
            let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), n))
            let gap: Float = 0.04
            let stack = plates.reduce(Float(0)) { $0 + Float($1.h) } + gap * Float(plates.count - 1)
            var face = MeshBuffer(parts: 1), metal = MeshBuffer(parts: 1)
            let base: SIMD3<Float>
            var top: Float
            // Plates stand a little in front of a pole, centred on a bracket.
            var proud: Float = 0.05
            if post.mount == .wall, let wall = wallMount(post, corridor: corridor, scenery: scenery) {
                let ground = Float(corridor.terrain.height(east: wall.foot.x, north: wall.foot.y))
                let c = wall.foot + wall.out * wallBracket
                base = SIMD3(Float(c.x), ground, Float(-c.y))
                top = ground + 2.6 + stack
                // Below the eaves (soffit, fascia, barge boards) where they
                // reach over the plates, across their width.
                let reach = Double(plates.map(\.w).max() ?? 0) / 2
                for k in [-1.0, 0, 1] {
                    let q = c + SIMD2(Double(right.x), Double(-right.z)) * (k * reach)
                    if let roof = roofHeight(out.roofs, over: q) { top = min(top, roof - 0.12) }
                }
                let y = top - stack / 2
                TreeArchetype.tube(&metal, SIMD3(Float(wall.foot.x), y, Float(-wall.foot.y)),
                                   SIMD3(base.x, y, base.z) - n * 0.012, 0.025, 0.025, sides: 5, height: 100)
                proud = 0
            } else {
                let p = RoadBuilder.vergePoint(corridor, st, side: post.side, offset: post.offset)
                base = SIMD3(Float(p.east), Float(p.y) - 0.3, Float(-p.north))
                top = Float(p.y) + 2.0 + stack
                TreeArchetype.tube(&metal, base, SIMD3(base.x, top + 0.03, base.z), 0.038, 0.038, sides: 8, height: 100)
            }
            for cell in plates {
                let c = SIMD3<Float>(base.x, top - Float(cell.h) / 2, base.z) + n * proud
                plate(&face, &metal, cell: cell, centre: c, right: right, normal: n)
                top -= Float(cell.h) + gap
            }
            appendParts(&out.props, face, map: [0: PropPart.signFace.rawValue])
            appendParts(&out.props, metal, map: [0: PropPart.greyMetal.rawValue])
        }
    }

    /// How far a wall-mounted plate's centre stands out from its wall.
    static let wallBracket = 0.35

    /// The way a post's plates face: riders coming up (or, `facesDownhill`,
    /// those coming down), turned `turn` towards the road.
    static func signNormal(_ post: CourseArt.SignPost, at st: RoadCorridor.Station) -> SIMD3<Float> {
        let along = SIMD3<Float>(Float(st.dirE), 0, Float(-st.dirN))
        let toRoad = SIMD3<Float>(Float(-post.side * st.rightE), 0, Float(post.side * st.rightN))
        let turn = Float(post.turn * .pi / 180)
        return simd_normalize((post.facesDownhill ? along : -along) * cos(turn) + toRoad * sin(turn))
    }

    /// Where a wall-mounted plate's bracket meets its wall, in plan: the
    /// nearest point within 4 m of the post's place on a footprint wall that
    /// faces it, kept 0.4 m from the wall's corners, and the wall's outward
    /// normal. Nil when no wall is that close.
    static func wallMount(_ post: CourseArt.SignPost, corridor: RoadCorridor,
                          scenery: SceneryFile?) -> (foot: SIMD2<Double>, out: SIMD2<Double>)? {
        let q = RoadBuilder.vergePoint(corridor, corridor.station(at: post.s), side: post.side, offset: post.offset)
        let p = SIMD2(q.east, q.north)
        var best: (foot: SIMD2<Double>, out: SIMD2<Double>, d: Double)?
        for b in scenery?.buildings ?? [] {
            var ring = cleaned(b.ring.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil })
            guard ring.count >= 3, distanceToRing(p, ring) < 4 else { continue }
            if signedArea(ring) < 0 { ring.reverse() }
            for i in ring.indices {
                let a = ring[i], c = ring[(i + 1) % ring.count]
                let len = simd_distance(a, c)
                guard len > 1, let o = outward(a, c) else { continue }
                let t = min(max(simd_dot(p - a, c - a) / (len * len), 0.4 / len), 1 - 0.4 / len)
                let foot = a + (c - a) * t
                let d = simd_distance(p, foot)
                guard d < 4, simd_dot(p - foot, o) > 0, d < (best?.d ?? .infinity) else { continue }
                best = (foot, o, d)
            }
        }
        return best.map { ($0.foot, $0.out) }
    }

    /// The lowest roof surface over a point in plan (eaves, soffits and
    /// boards included), from the built roofs; nil where none covers it.
    static func roofHeight(_ roofs: MeshBuffer, over p: SIMD2<Double>) -> Float? {
        let x = Float(p.x), z = Float(-p.y)
        let v = roofs.positions
        var low: Float?
        for part in roofs.parts {
            for t in stride(from: 0, to: part.count - 2, by: 3) {
                let i0 = Int(part[t]) * 3, i1 = Int(part[t + 1]) * 3, i2 = Int(part[t + 2]) * 3
                let ax = v[i0], az = v[i0 + 2], bx = v[i1], bz = v[i1 + 2], cx = v[i2], cz = v[i2 + 2]
                guard x >= min(ax, bx, cx), x <= max(ax, bx, cx), z >= min(az, bz, cz), z <= max(az, bz, cz) else { continue }
                // Barycentric in plan; walls and boards' faces seen edge-on drop out.
                let d = (bz - cz) * (ax - cx) + (cx - bx) * (az - cz)
                guard abs(d) > 1e-6 else { continue }
                let l0 = ((bz - cz) * (x - cx) + (cx - bx) * (z - cz)) / d
                let l1 = ((cz - az) * (x - cx) + (ax - cx) * (z - cz)) / d
                guard l0 >= 0, l1 >= 0, l0 + l1 <= 1 else { continue }
                let y = l0 * v[i0 + 1] + l1 * v[i1 + 1] + (1 - l0 - l1) * v[i2 + 1]
                low = min(low ?? y, y)
            }
        }
        return low
    }

    /// One plate: its outline as a fan mapped onto its atlas cell, and a
    /// galvanised back 12 mm behind it, wound the other way.
    private static func plate(_ face: inout MeshBuffer, _ back: inout MeshBuffer, cell: SignCell,
                              centre c: SIMD3<Float>, right r: SIMD3<Float>, normal n: SIMD3<Float>) {
        let up = simd_cross(n, r)
        let hw = Float(cell.w) / 2, hh = Float(cell.h) / 2
        let f0 = UInt32(face.vertexCount), b0 = UInt32(back.vertexCount)
        let outline = Self.outline(cell.shape)
        for q in outline {
            let p = c + r * (q.x * hw) + up * (q.y * hh)
            let u = cell.uv[0] + (cell.uv[2] - cell.uv[0]) * (q.x * 0.5 + 0.5)
            let v = cell.uv[1] + (cell.uv[3] - cell.uv[1]) * (0.5 - q.y * 0.5)
            face.vertex(p.x, p.y, p.z, n.x, n.y, n.z, u, v)
            let pb = p - n * 0.012
            back.vertex(pb.x, pb.y, pb.z, -n.x, -n.y, -n.z, 0, 0)
        }
        for k in 1..<UInt32(outline.count - 1) {
            face.tri(f0, f0 + k, f0 + k + 1)
            back.tri(b0, b0 + k + 1, b0 + k)
        }
    }

    /// A plate shape's outline in -1...1, anticlockwise seen from the front.
    private static func outline(_ shape: String) -> [SIMD2<Float>] {
        switch shape {
        case "tri": return [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(0, 1)]
        case "triDown": return [SIMD2(-1, 1), SIMD2(0, -1), SIMD2(1, 1)]
        case "disc": return (0..<24).map { k in let a = Float(k) / 24 * 2 * .pi; return SIMD2(cos(a), sin(a)) }
        default: return [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1)]
        }
    }

    /// Cast-iron gully grates a few millimetres over the paving: round ones
    /// down a village street (`CourseArt.streetGrates`), rectangular ones
    /// in the gutters about every `gutterGrateSpacing` metres.
    static func buildGrates(_ out: inout Output, corridor: RoadCorridor, cells: [String: SignCell] = signCells) {
        var m = MeshBuffer(parts: 1)
        /// A flat plate on the road at `lateral`, `length` along it.
        func lay(_ cell: SignCell, at s: Double, lateral: Double, lift: Double) {
            let st = corridor.station(at: s)
            let p = st.point(lateral: lateral)
            let c = SIMD3<Float>(Float(p.east), Float(corridor.roadHeight(st, lateral: lateral) + lift), Float(-p.north))
            let along = SIMD3<Float>(Float(st.dirE), 0, Float(-st.dirN))
            // Seen from above, with the cell's width down the road.
            let n = SIMD3<Float>(0, 1, 0)
            plateFlat(&m, cell: cell, centre: c, right: along, normal: n)
        }
        if let cell = cells["grate.round"] {
            for (span, lateral, spacing) in corridor.art.streetGrates {
                var r = WorldRandom(seed: UInt64(span.lowerBound * 17 + 1))
                var s = span.lowerBound + spacing * 0.3
                while s <= span.upperBound {
                    lay(cell, at: s, lateral: lateral + Double(r.range(-0.08, 0.08)), lift: 0.006)
                    s += spacing * Double(r.range(0.8, 1.2))
                }
            }
        }
        let spacing = corridor.art.gutterGrateSpacing
        if let cell = cells["grate.rect"], spacing > 0 {
            for (span, side) in corridor.art.gutters {
                var r = WorldRandom(seed: UInt64(span.lowerBound * 11 + 3))
                var s = span.lowerBound + spacing * 0.6
                while s < span.upperBound - 2 {
                    let st = corridor.station(at: s)
                    // Over the gutter's dished middle (its lift there is 6-10 mm).
                    lay(cell, at: s, lateral: side * (st.halfWidth - 0.3), lift: 0.013)
                    s += spacing * Double(r.range(0.85, 1.15))
                }
            }
        }
        appendParts(&out.props, m, map: [0: PropPart.signFace.rawValue])
    }

    /// A one-sided plate (no back): `right` runs along the cell's width.
    private static func plateFlat(_ m: inout MeshBuffer, cell: SignCell, centre c: SIMD3<Float>,
                                  right r: SIMD3<Float>, normal n: SIMD3<Float>) {
        var unused = MeshBuffer(parts: 1)
        plate(&m, &unused, cell: cell, centre: c, right: r, normal: n)
    }

    /// Benches, tables, posts and cabinets from the climb's description,
    /// each at its route distance and offset, facing the road (turned by
    /// `turn`); and the chapel's blue door on the wall of its footprint
    /// that faces the road.
    static func buildFurniture(_ out: inout Output, corridor: RoadCorridor, scenery: SceneryFile?,
                               cells: [String: SignCell] = signCells) {
        let up = SIMD3<Float>(0, 1, 0)
        func paint(_ key: String, _ m: inout MeshBuffer) {
            guard let cell = cells[key] else { return }
            let (u, v) = cell.centre
            for i in 0..<m.vertexCount { m.uvs[2 * i] = u; m.uvs[2 * i + 1] = v }
        }
        for item in corridor.art.furniture {
            let st = corridor.station(at: item.s)
            let p = RoadBuilder.vergePoint(corridor, st, side: item.side, offset: item.offset)
            let g = SIMD3<Float>(Float(p.east), Float(p.y), Float(-p.north))
            let along = SIMD3<Float>(Float(st.dirE), 0, Float(-st.dirN))
            let toRoad = SIMD3<Float>(Float(-item.side * st.rightE), 0, Float(item.side * st.rightN))
            let t = Float(item.turn * .pi / 180)
            // Its front, and its length to the right of it.
            let fwd = simd_normalize(toRoad * cos(t) + along * sin(t) * Float(item.side))
            let x = simd_cross(fwd, up)
            func box(_ m: inout MeshBuffer, _ c: SIMD3<Float>, _ half: SIMD3<Float>) {
                emitPropBox(&m, centre: g + x * c.x + up * c.y + fwd * c.z, x: x, z: fwd, half: half)
            }
            switch item.kind {
            case .bench(let wood):
                var seat = MeshBuffer(parts: 1), legs = MeshBuffer(parts: 1)
                for z in [-0.09, 0.09] as [Float] { box(&seat, SIMD3(0, 0.44, z), SIMD3(0.9, 0.02, 0.08)) }
                for y in [0.62, 0.8] as [Float] { box(&seat, SIMD3(0, y, -0.22), SIMD3(0.9, 0.06, 0.02)) }
                for sx in [-0.75, 0.75] as [Float] {
                    box(&legs, SIMD3(sx, 0.2, 0), SIMD3(0.03, 0.24, 0.2))
                    box(&legs, SIMD3(sx, 0.62, -0.24), SIMD3(0.03, 0.2, 0.025))
                }
                appendParts(&out.props, seat, map: [0: (wood ? PropPart.wood : .darkWood).rawValue])
                appendParts(&out.props, legs, map: [0: PropPart.darkMetal.rawValue])
            case .picnicTable:
                var m = MeshBuffer(parts: 1)
                box(&m, SIMD3(0, 0.74, 0), SIMD3(0.9, 0.025, 0.36))
                for z in [-0.6, 0.6] as [Float] { box(&m, SIMD3(0, 0.44, z), SIMD3(0.9, 0.025, 0.13)) }
                for sx in [-0.65, 0.65] as [Float] {
                    box(&m, SIMD3(sx, 0.37, 0), SIMD3(0.04, 0.37, 0.05))
                    box(&m, SIMD3(sx, 0.2, 0), SIMD3(0.04, 0.03, 0.72))
                }
                appendParts(&out.props, m, map: [0: PropPart.wood.rawValue])
            case .bikeStands(let count):
                var m = MeshBuffer(parts: 1)
                for k in 0..<count {
                    let c = g + x * (Float(k) - Float(count - 1) / 2) * 0.8
                    let a = c - fwd * 0.3 - up * 0.1, b = c + fwd * 0.3 - up * 0.1
                    let a1 = a + up * 0.85, b1 = b + up * 0.85
                    TreeArchetype.tube(&m, a, a1, 0.024, 0.024, sides: 6, height: 100)
                    TreeArchetype.tube(&m, a1, a1 + fwd * 0.08 + up * 0.08, 0.024, 0.024, sides: 6, height: 100)
                    TreeArchetype.tube(&m, a1 + fwd * 0.08 + up * 0.08, b1 - fwd * 0.08 + up * 0.08, 0.024, 0.024, sides: 6, height: 100)
                    TreeArchetype.tube(&m, b1 - fwd * 0.08 + up * 0.08, b1, 0.024, 0.024, sides: 6, height: 100)
                    TreeArchetype.tube(&m, b1, b, 0.024, 0.024, sides: 6, height: 100)
                }
                appendParts(&out.props, m, map: [0: PropPart.greyMetal.rawValue])
            case .electricityKiosk:
                // A steel cabinet 1.0 x 0.6 m on a dark concrete plinth 4 cm
                // proud of it, walls to 1.56 m, a drip edge to the eaves at
                // 1.6 m and a low pyramid roof. The walls and roof take the
                // atlas's kiosk cells: double doors to the road (and at the
                // back), vents on the ends, rain streaks and splash grime.
                // Plain kiosk green without them.
                let plinth: Float = 0.12, wallTop: Float = 1.56
                let half = SIMD2<Float>(0.5, 0.3)   // along `x`, along `fwd`
                var base = MeshBuffer(parts: 1)
                box(&base, SIMD3(0, (plinth - 0.3) / 2, 0), SIMD3(half.x + 0.04, (plinth + 0.3) / 2, half.y + 0.04))
                paint(cells["paint.plinth"] == nil ? "paint.green" : "paint.plinth", &base)
                appendParts(&out.props, base, map: [0: PropPart.signFace.rawValue])
                var rim = MeshBuffer(parts: 1)
                box(&rim, SIMD3(0, 1.58, 0), SIMD3(0.56, 0.02, 0.36))
                paint("paint.green", &rim)
                appendParts(&out.props, rim, map: [0: PropPart.signFace.rawValue])
                var m = MeshBuffer(parts: 1)
                let green = cells["paint.green"]?.centre ?? (0, 0)
                // `poly` (anticlockwise seen from outside) at fractions of the
                // cell `key` (x right, y up).
                func face(_ key: String, _ poly: [SIMD3<Float>], _ at: [SIMD2<Float>], _ n: SIMD3<Float>) {
                    let first = UInt32(m.vertexCount)
                    for (q, f) in zip(poly, at) {
                        var (u, v) = green
                        if let c = cells[key] {
                            u = c.uv[0] + (c.uv[2] - c.uv[0]) * f.x
                            v = c.uv[3] + (c.uv[1] - c.uv[3]) * f.y
                        }
                        m.vertex(q.x, q.y, q.z, n.x, n.y, n.z, u, v)
                    }
                    for k in 1..<UInt32(poly.count - 1) { m.tri(first, first + k, first + k + 1) }
                }
                let walls = [(fwd, half.y, half.x, "kiosk.front"), (-fwd, half.y, half.x, "kiosk.front"),
                             (x, half.x, half.y, "kiosk.end"), (-x, half.x, half.y, "kiosk.end")]
                for (n, depth, width, key) in walls {
                    let c = g + n * depth, r = simd_cross(up, n) * width
                    face(key, [c - r + up * plinth, c + r + up * plinth, c + r + up * wallTop, c - r + up * wallTop],
                         [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)], n)
                }
                let apex: SIMD3<Float> = g + up * 1.9
                let eaves: SIMD3<Float> = g + up * 1.6
                let corners: [SIMD3<Float>] = [SIMD2<Float>(-0.56, -0.36), SIMD2(0.56, -0.36), SIMD2(0.56, 0.36), SIMD2(-0.56, 0.36)]
                    .map { (c: SIMD2<Float>) -> SIMD3<Float> in eaves + x * c.x + fwd * c.y }
                for k in 0..<4 {
                    let a = corners[k], b = corners[(k + 1) % 4]
                    let nrm = simd_normalize(simd_cross(b - a, apex - a))
                    if simd_dot(nrm, (a + b) / 2 - eaves) > 0 {
                        face("kiosk.roof", [a, b, apex], [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0.5, 1)], nrm)
                    } else {
                        face("kiosk.roof", [b, a, apex], [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0.5, 1)], -nrm)
                    }
                }
                appendParts(&out.props, m, map: [0: PropPart.signFace.rawValue])
            case .granitePost:
                var m = MeshBuffer(parts: 1)
                box(&m, SIMD3(0, 0.55, 0), SIMD3(0.13, 0.75, 0.12))
                appendParts(&out.props, m, map: [0: PropPart.concrete.rawValue])
            case .wasteBasket:
                var post = MeshBuffer(parts: 1), bin = MeshBuffer(parts: 1)
                box(&post, SIMD3(0, 0.45, -0.2), SIMD3(0.03, 0.55, 0.03))
                box(&bin, SIMD3(0, 0.6, -0.02), SIMD3(0.17, 0.25, 0.15))
                appendParts(&out.props, post, map: [0: PropPart.greyMetal.rawValue])
                appendParts(&out.props, bin, map: [0: PropPart.darkMetal.rawValue])
            case .waysideCross:
                var m = MeshBuffer(parts: 1)
                box(&m, SIMD3(0, 0.95, 0), SIMD3(0.05, 1.25, 0.05))
                box(&m, SIMD3(0, 1.65, 0), SIMD3(0.36, 0.045, 0.045))
                appendParts(&out.props, m, map: [0: PropPart.darkWood.rawValue])
            case .markerPost:
                var m = MeshBuffer(parts: 1)
                box(&m, SIMD3(0, 0.5, 0), SIMD3(0.05, 0.7, 0.05))
                paint("paint.yellow", &m)
                appendParts(&out.props, m, map: [0: PropPart.signFace.rawValue])
            case .gatePillar(let whiteCap):
                let centre = SIMD2<Double>(p.east, p.north)
                emitBox(&out.walls, centre: centre, along: SIMD2(st.dirE, st.dirN), halfA: 0.23, halfB: 0.23,
                        y0: p.y - 0.3, y1: p.y + 1.45, style: Style(row: .redBrick, pantile: false, pitchDeg: 0, shed: true),
                        ground: { Double(corridor.terrain.height(east: $0.x, north: $0.y)) })
                var cap = MeshBuffer(parts: 1)
                box(&cap, SIMD3(0, 1.5, 0), SIMD3(0.28, 0.05, 0.28))
                appendParts(&out.props, cap, map: [0: (whiteCap ? PropPart.whitePaint : .concrete).rawValue])
            case .cabinet:
                var m = MeshBuffer(parts: 1)
                box(&m, SIMD3(0, 0.5, 0), SIMD3(0.32, 0.6, 0.18))
                paint("paint.cabinet", &m)
                appendParts(&out.props, m, map: [0: PropPart.signFace.rawValue])
            case .chapelFront:
                chapelFront(&out, corridor: corridor, scenery: scenery, near: SIMD2(p.east, p.north), paint: paint)
            case .domedChapel:
                if let site = domedChapelSites(corridor: corridor, scenery: scenery).first(where: { $0.s == item.s }) {
                    domedChapel(&out, corridor: corridor, site: site, paint: paint)
                }
            case .calvary:
                // A timber cross 5.6 m tall on a stepped stone base, the
                // pale corpus on the side facing the road.
                var stone = MeshBuffer(parts: 1)
                box(&stone, SIMD3(0, 0.1, 0), SIMD3(0.7, 0.3, 0.7))
                box(&stone, SIMD3(0, 0.5, 0), SIMD3(0.42, 0.15, 0.42))
                appendParts(&out.props, stone, map: [0: PropPart.concrete.rawValue])
                var cross = MeshBuffer(parts: 1)
                box(&cross, SIMD3(0, 3.4, 0), SIMD3(0.11, 2.8, 0.11))
                box(&cross, SIMD3(0, 4.75, 0), SIMD3(1.15, 0.1, 0.1))
                appendParts(&out.props, cross, map: [0: PropPart.darkWood.rawValue])
                var body = MeshBuffer(parts: 1)
                box(&body, SIMD3(0, 4.05, 0.16), SIMD3(0.13, 0.6, 0.05))
                box(&body, SIMD3(0, 4.68, 0.16), SIMD3(0.8, 0.05, 0.04))
                box(&body, SIMD3(0, 4.82, 0.17), SIMD3(0.08, 0.1, 0.07))
                appendParts(&out.props, body, map: [0: PropPart.whitePaint.rawValue])
            }
        }
    }

    /// Least-squares circle through the points (Kåsa's fit): centre and
    /// radius; nil for fewer than three points or a degenerate fit.
    static func fitCircle(_ pts: [SIMD2<Double>]) -> (centre: SIMD2<Double>, radius: Double)? {
        guard pts.count >= 3 else { return nil }
        let o = pts.reduce(SIMD2<Double>.zero, +) / Double(pts.count)
        var a = simd_double3x3(), b = SIMD3<Double>()
        for p in pts {
            let q = p - o
            let v = SIMD3(q.x, q.y, 1)
            a = a + simd_double3x3(rows: [v * v.x, v * v.y, v])
            b -= v * simd_length_squared(q)
        }
        guard abs(a.determinant) > 1e-9 else { return nil }
        let x = a.inverse * b
        let c = SIMD2(-x.x / 2, -x.y / 2)
        let r2 = simd_length_squared(c) - x.z
        return r2 > 0 ? (o + c, r2.squareRoot()) : nil
    }

    /// Where each `.domedChapel` stands: the furniture's route distance, and
    /// the chapel footprint nearest its verge point (within 15 m) with its
    /// index among the scenery's buildings. `build` leaves those footprints
    /// out and `buildFurniture` builds the chapel on them.
    static func domedChapelSites(corridor: RoadCorridor, scenery: SceneryFile?)
        -> [(s: Double, index: Int, ring: [SIMD2<Double>], heightM: Double)] {
        let buildings = scenery?.buildings ?? []
        var out: [(s: Double, index: Int, ring: [SIMD2<Double>], heightM: Double)] = []
        for item in corridor.art.furniture {
            guard case .domedChapel = item.kind else { continue }
            let st = corridor.station(at: item.s)
            let p = RoadBuilder.vergePoint(corridor, st, side: item.side, offset: item.offset)
            let near = SIMD2(p.east, p.north)
            var best: (index: Int, ring: [SIMD2<Double>], d: Double)?
            for (k, b) in buildings.enumerated() where b.kind == "chapel" {
                var ring = cleaned(b.ring.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil })
                guard ring.count >= 3 else { continue }
                if signedArea(ring) < 0 { ring.reverse() }
                let d = distanceToRing(near, ring)
                if d < 15, d < (best?.d ?? .infinity) { best = (k, ring, d) }
            }
            if let best { out.append((item.s, best.index, best.ring, buildings[best.index].heightM)) }
        }
        return out
    }

    /// The Oudenberg chapel on its footprint (photos 2007-2022): an
    /// octagonal red-brick drum with stone quoins under a stone cornice, a
    /// faceted slate dome, a white lantern with its own little dome and the
    /// gilt statue of Our Lady; low brick wings round the drum under lean-to
    /// slates; and the porch the footprint pushes out (the vertices well
    /// beyond the circle fitted to the rest) as a brick front with stone
    /// pilasters, a gable over the roof line, a cross on it and a timber
    /// door, kept low enough that the dome shows over it from the road, as
    /// in the photos. Sized from the footprint, its heights scaled to the
    /// LiDAR height (12.1 m here).
    private static func domedChapel(_ out: inout Output, corridor: RoadCorridor,
                                    site: (s: Double, index: Int, ring: [SIMD2<Double>], heightM: Double),
                                    paint: (String, inout MeshBuffer) -> Void) {
        let ring = site.ring
        func P(_ p: SIMD2<Double>, _ y: Double) -> SIMD3<Float> { SIMD3(Float(p.x), Float(y), Float(-p.y)) }
        func ground(_ p: SIMD2<Double>) -> Double { Double(corridor.terrain.height(east: p.x, north: p.y)) }
        let mean = ring.reduce(SIMD2<Double>.zero, +) / Double(ring.count)
        // The porch: the vertices well beyond the rest (over 1.25 times the
        // median distance from the middle); the body: a circle fitted to the
        // others, so the porch doesn't pull it off centre.
        let dists = ring.map { simd_distance($0, mean) }.sorted()
        let median = dists[dists.count / 2]
        let body = ring.filter { simd_distance($0, mean) <= 1.25 * median }
        let (centre, fitted) = fitCircle(body) ?? (mean, median)
        var porch = ring.filter { simd_distance($0, mean) > 1.25 * median }
        if porch.isEmpty { porch = [ring.max { simd_distance($0, centre) < simd_distance($1, centre) }!] }
        let front = simd_normalize(porch.reduce(SIMD2<Double>.zero, +) / Double(porch.count) - centre)
        let outer = min(max(fitted, 4.5), 9)
        let drumR = outer - 1.5
        let k = min(max(site.heightM / 12.1, 0.85), 1.2)
        let porchReach = porch.map { simd_dot($0 - centre, front) }.max()!
        let floorY = ground(centre + front * porchReach) + 0.15
        let baseY = (ring.map(ground).min() ?? floorY) - 0.4
        let sd: Float = 0.37
        var brick = Style(row: .redBrick, pantile: false, pitchDeg: 0, shed: false)
        brick.plinth = .stonePlinth
        brick.plinthHeight = 0.5
        brick.seed = sd
        var stone = Style(row: .cream, pantile: false, pitchDeg: 0, shed: false)
        stone.seed = sd
        var white = Style(row: .painted, pantile: false, pitchDeg: 0, shed: false)
        white.seed = sd
        let slate = RoofCover.slate.rawValue, board = RoofTrim.whiteBoard.rawValue

        // An octagon of radius r turned so a face looks along `front`.
        let a0 = atan2(front.y, front.x) + .pi / 8
        func octagon(_ r: Double) -> [SIMD2<Double>] {
            (0..<8).map { i in
                let a = a0 + Double(i) * .pi / 4
                return centre + SIMD2(cos(a), sin(a)) * r
            }
        }
        func walls(_ poly: [SIMD2<Double>], top: Double, style: Style) {
            for i in poly.indices {
                let p = poly[i], q = poly[(i + 1) % poly.count]
                let len = simd_distance(p, q)
                let w = WallFrame(a: p, dir: (q - p) / len, len: len, top0: top, top1: top, floorY: floorY,
                                  baseY: baseY, ground: groundSamples(p, q, ground))
                emitWall(&out.walls, w, style: style, openings: [])
            }
        }
        // A faceted dome over an octagon from radius r0 at y0 to r1 at y1,
        // the profile a quarter ellipse.
        func dome(r0: Double, y0: Double, r1: Double, y1: Double, rings: Int) {
            let phiTop = acos(min(r1 / r0, 1))
            var prev: [SIMD3<Float>] = []
            var prevUp = 0.0
            for j in 0...rings {
                let phi = phiTop * Double(j) / Double(rings)
                let r = r0 * cos(phi), y = y0 + (y1 - y0) * sin(phi) / max(sin(phiTop), 1e-6)
                let cur = octagon(r).map { P($0, y) }
                let up = prevUp + (j == 0 ? 0 : Double(simd_distance(cur[0], prev[0])))
                if j > 0 {
                    for i in 0..<8 {
                        let a = prev[i], b = prev[(i + 1) % 8], c = cur[(i + 1) % 8], d = cur[i]
                        let mid = (a + b) / 2 - P(centre, y0)
                        let n = simd_normalize(SIMD3(mid.x, 0, mid.z)) + SIMD3(0, 0.3, 0)
                        let wb = simd_distance(a, b), wt = simd_distance(c, d)
                        let h = Float(up - prevUp)
                        roofQuad(&out.roofs, [a, b, c, d], facing: n,
                                 uv: [(0, h), (wb, h), ((wb + wt) / 2, 0), ((wb - wt) / 2, 0)],
                                 id: slate, seed: sd, up: Float(prevUp), part: 1)
                    }
                }
                prev = cur
                prevUp = up
            }
        }

        // The wings round the drum, under lean-to slates rising to it.
        let wingTop = floorY + 4.2 * k
        let wing = octagon(outer)
        walls(wing, top: wingTop, style: brick)
        let eave = octagon(outer + 0.3).map { P($0, wingTop - 0.05) }
        let foot = octagon(drumR).map { P($0, wingTop + 1.2 * k) }
        for i in 0..<8 {
            let a = eave[i], b = eave[(i + 1) % 8], c = foot[(i + 1) % 8], d = foot[i]
            let mid = (a + b) / 2 - P(centre, wingTop)
            let wb = simd_distance(a, b), wt = simd_distance(c, d), h = simd_distance((a + b) / 2, (c + d) / 2)
            roofQuad(&out.roofs, [a, b, c, d], facing: simd_normalize(SIMD3(mid.x, 0, mid.z)) + SIMD3(0, 1, 0),
                     uv: [(0, h), (wb, h), ((wb + wt) / 2, 0), ((wb - wt) / 2, 0)], id: slate, seed: sd, up: 0, part: 1)
            emitBoard(&out.roofs, octagon(outer + 0.3)[i], octagon(outer + 0.3)[(i + 1) % 8], ya: wingTop - 0.05,
                      yb: wingTop - 0.05, out: simd_normalize((octagon(outer)[i] + octagon(outer)[(i + 1) % 8]) / 2 - centre),
                      depth: 0.22, id: board, seed: sd, part: 1)
        }
        // The drum, its stone quoins and cornice, and the dome.
        let cornice = floorY + 7.6 * k
        let drum = octagon(drumR)
        walls(drum, top: cornice, style: brick)
        for p in drum {
            let out2 = simd_normalize(p - centre)
            emitBox(&out.walls, centre: p + out2 * 0.05, along: SIMD2(out2.y, -out2.x), halfA: 0.3, halfB: 0.12,
                    y0: wingTop, y1: cornice, style: stone, eaves: true, ground: ground)
        }
        for i in 0..<8 {
            let a = octagon(drumR + 0.25)[i], c = octagon(drumR + 0.25)[(i + 1) % 8]
            emitBoard(&out.roofs, a, c, ya: cornice + 0.1, yb: cornice + 0.1,
                      out: simd_normalize((a + c) / 2 - centre), depth: 0.45, lip: 0.08, id: board, seed: sd, part: 1)
        }
        let lanternR = 1.05
        let domeTop = cornice + 3.9 * k
        dome(r0: drumR + 0.25, y0: cornice + 0.1, r1: lanternR + 0.1, y1: domeTop, rings: 6)
        // The lantern, its dome and the statue.
        let lantern = octagon(lanternR)
        let lanternTop = domeTop + 1.6 * k
        for i in lantern.indices {
            let p = lantern[i], q = lantern[(i + 1) % 8]
            let len = simd_distance(p, q)
            let w = WallFrame(a: p, dir: (q - p) / len, len: len, top0: lanternTop, top1: lanternTop, floorY: domeTop - 0.2,
                              baseY: domeTop - 0.4, ground: [domeTop - 0.2, domeTop - 0.2])
            emitWall(&out.walls, w, style: white, openings: [])
        }
        var openings = MeshBuffer(parts: 1)
        for i in 0..<8 {
            let mid = (lantern[i] + lantern[(i + 1) % 8]) / 2
            let n = simd_normalize(mid - centre)
            let c = P(mid + n * 0.01, domeTop + 0.75 * k)
            emitPropBox(&openings, centre: c, x: SIMD3(Float(-n.y), 0, Float(-n.x)), z: SIMD3(Float(n.x), 0, Float(-n.y)),
                        half: SIMD3(0.18, Float(0.45 * k), 0.01))
        }
        appendParts(&out.props, openings, map: [0: PropPart.darkMetal.rawValue])
        for i in 0..<8 {
            let a = octagon(lanternR + 0.15)[i], c = octagon(lanternR + 0.15)[(i + 1) % 8]
            emitBoard(&out.roofs, a, c, ya: lanternTop + 0.05, yb: lanternTop + 0.05,
                      out: simd_normalize((a + c) / 2 - centre), depth: 0.2, id: board, seed: sd, part: 1)
        }
        dome(r0: lanternR + 0.15, y0: lanternTop + 0.05, r1: 0.12, y1: lanternTop + 0.7 * k, rings: 3)
        let statueFoot = P(centre, lanternTop + 0.7 * k)
        var gilt = MeshBuffer(parts: 1)
        TreeArchetype.tube(&gilt, statueFoot, statueFoot + SIMD3(0, 1.15, 0), 0.24, 0.12, sides: 8, height: 100)
        TreeArchetype.tube(&gilt, statueFoot + SIMD3(0, 1.15, 0), statueFoot + SIMD3(0, 1.45, 0), 0.1, 0.07, sides: 8, height: 100)
        paint("paint.gold", &gilt)
        appendParts(&out.props, gilt, map: [0: PropPart.signFace.rawValue])

        // The porch: brick walls out to the footprint's front, a slate
        // gable roof back to the drum, and the front wall standing above it
        // as a gable with stone pilasters, a cross and the door.
        let side = SIMD2(front.y, -front.x)
        let halfW = min(max((porch.map { abs(simd_dot($0 - centre, side)) }.max() ?? 2.8), 2.2), 3.2)
        let back = drumR - 0.6, ahead = min(max(porchReach, drumR + 2.5), drumR + 6.5)
        let wallTop = floorY + 5.2 * k, gableTop = floorY + 7.6 * k
        let fl = centre + front * ahead + side * halfW, fr = centre + front * ahead - side * halfW
        let bl = centre + front * back + side * halfW, br = centre + front * back - side * halfW
        for (p, q) in [(bl, fl), (fr, br)] {
            let len = simd_distance(p, q)
            let w = WallFrame(a: p, dir: (q - p) / len, len: len, top0: wallTop, top1: wallTop, floorY: floorY,
                              baseY: baseY, ground: groundSamples(p, q, ground))
            emitWall(&out.walls, w, style: brick, openings: [])
        }
        let frontLen = simd_distance(fl, fr)
        var face = WallFrame(a: fl, dir: (fr - fl) / frontLen, len: frontLen, top0: wallTop, top1: wallTop, floorY: floorY,
                             baseY: baseY, ground: groundSamples(fl, fr, ground))
        face.uRidge = frontLen / 2
        face.topRidge = gableTop
        let door = Opening(cut: .door, u0: frontLen / 2 - 0.8, u1: frontLen / 2 + 0.8, y0: floorY, y1: floorY + 3.0,
                           painted: .timberDoor)
        emitWall(&out.walls, face, style: brick, openings: [door])
        for p in [fl, fr] {
            emitBox(&out.walls, centre: p + front * 0.08 - (p - centre - front * ahead) * 0.06, along: side, halfA: 0.32,
                    halfB: 0.14, y0: baseY, y1: wallTop + 0.4, style: stone, eaves: true, ground: ground)
        }
        let apex = centre + front * (ahead + 0.1)
        for (p, q) in [(fl, apex), (apex, fr)] {
            let pa = p + front * 0.1
            emitBoard(&out.roofs, pa, q, ya: p == fl ? wallTop + 0.1 : gableTop + 0.1, yb: q == fr ? wallTop + 0.1 : gableTop + 0.1,
                      out: front, depth: 0.35, lip: 0.08, id: board, seed: sd, part: 1)
        }
        var cross = MeshBuffer(parts: 1)
        let cb = P(apex + front * 0.05, gableTop + 0.15)
        let fx = SIMD3<Float>(Float(side.x), 0, Float(-side.y)), fz = SIMD3<Float>(Float(front.x), 0, Float(-front.y))
        emitPropBox(&cross, centre: cb + SIMD3(0, 0.55, 0), x: fx, z: fz, half: SIMD3(0.05, 0.55, 0.05))
        emitPropBox(&cross, centre: cb + SIMD3(0, 0.75, 0), x: fx, z: fz, half: SIMD3(0.3, 0.05, 0.05))
        appendParts(&out.props, cross, map: [0: PropPart.darkMetal.rawValue])
        let ridgeY = floorY + 7.0 * k
        for sgn in [-1.0, 1.0] {
            let e0 = centre + front * back + side * (sgn * (halfW + 0.25))
            let e1 = centre + front * (ahead - 0.15) + side * (sgn * (halfW + 0.25))
            let r0 = centre + front * back, r1 = centre + front * (ahead - 0.15)
            let slope = Float(simd_length(SIMD2(halfW + 0.25, ridgeY - wallTop)))
            let len = Float(simd_distance(e0, e1))
            roofQuad(&out.roofs, [P(e0, wallTop - 0.05), P(e1, wallTop - 0.05), P(r1, ridgeY), P(r0, ridgeY)],
                     facing: SIMD3(Float(side.x * sgn), 1, Float(-side.y * sgn)), uv: [(0, slope), (len, slope), (len, 0), (0, 0)],
                     id: slate, seed: sd, up: 0, part: 1)
        }
    }

    /// The blue door, centred on the wall of the chapel nearest `near` that
    /// faces the road, 2 cm proud, and a small iron cross above it.
    private static func chapelFront(_ out: inout Output, corridor: RoadCorridor, scenery: SceneryFile?, near: SIMD2<Double>,
                                    paint: (String, inout MeshBuffer) -> Void) {
        let chapels = (scenery?.buildings ?? []).filter { $0.kind == "chapel" }.map {
            cleaned($0.ring.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil })
        }
        guard var ring = chapels.min(by: { distanceToRing(near, $0) < distanceToRing(near, $1) }),
              ring.count >= 3, distanceToRing(near, ring) < 8 else { return }
        if signedArea(ring) < 0 { ring.reverse() }
        // The edge whose outward side looks most at the road.
        var best: (a: SIMD2<Double>, c: SIMD2<Double>, out: SIMD2<Double>, score: Double)?
        for i in ring.indices {
            let a = ring[i], c = ring[(i + 1) % ring.count]
            guard let o = outward(a, c), simd_distance(a, c) > 1.4 else { continue }
            let mid = (a + c) / 2
            let q = corridor.coarse.query(east: mid.x, north: mid.y)
            let st = corridor.station(at: q.s)
            let toRoad = simd_normalize(SIMD2(st.east, st.north) - mid)
            let score = simd_dot(o, toRoad)
            if score > (best?.score ?? -2) { best = (a, c, o, score) }
        }
        guard let wall = best else { return }
        let mid = (wall.a + wall.c) / 2 + wall.out * 0.02
        let ground = Float(corridor.terrain.height(east: mid.x, north: mid.y))
        let dir = simd_normalize(wall.c - wall.a)
        let x = SIMD3<Float>(Float(dir.x), 0, Float(-dir.y))
        let n = SIMD3<Float>(Float(wall.out.x), 0, Float(-wall.out.y))
        let c = SIMD3<Float>(Float(mid.x), ground, Float(-mid.y))
        var door = MeshBuffer(parts: 1)
        emitPropBox(&door, centre: c + SIMD3(0, 0.92, 0), x: x, z: n, half: SIMD3(0.46, 1.0, 0.02))
        paint("paint.blue", &door)
        appendParts(&out.props, door, map: [0: PropPart.signFace.rawValue])
        var cross = MeshBuffer(parts: 1)
        emitPropBox(&cross, centre: c + SIMD3(0, 2.45, 0) + n * 0.03, x: x, z: n, half: SIMD3(0.025, 0.24, 0.02))
        emitPropBox(&cross, centre: c + SIMD3(0, 2.55, 0) + n * 0.03, x: x, z: n, half: SIMD3(0.14, 0.025, 0.02))
        appendParts(&out.props, cross, map: [0: PropPart.darkMetal.rawValue])
    }

    // MARK: - Water

    /// How open a stream is to the sky at a point: 1 in the open, falling to
    /// 0 under vegetation over 1.5 m tall within about 2 m.
    static func openSky(_ canopy: HeightRaster?, east: Double, north: Double) -> Float {
        guard let canopy else { return 1 }
        var tallest: Float = 0
        for dn in stride(from: -2.0, through: 2.0, by: 1.0) {
            for de in stride(from: -2.0, through: 2.0, by: 1.0) where de * de + dn * dn <= 4.5 {
                let v = canopy.sample(east: east + de, north: north + dn)
                if !v.isNaN { tallest = max(tallest, v) }
            }
        }
        return 1 - smoothstepF(0.4, 1.6, tallest)
    }

    static func buildWater(_ out: inout Output, scenery: SceneryFile?, terrain: TerrainSampler, canopy: HeightRaster?) {
        for w in scenery?.water ?? [] {
            let pts = w.points.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }
            guard pts.count >= 2 else { continue }
            if w.closed == true || w.kind == "pond" {
                var ring = cleaned(pts)
                guard ring.count >= 3 else { continue }
                if signedArea(ring) < 0 { ring.reverse() }
                let rim = ring.map { Double(terrain.height(east: $0.x, north: $0.y)) }.min() ?? 0
                emitPolygon(&out.water, ring, y: { _ in rim - 0.15 }, uv: { p in (Float(p.x), Float(p.y)) }, part: 0)
            } else {
                // A narrow ribbon a little above the stream bed, every 2 m so
                // it follows the bed and the cover over it.
                var pts2: [SIMD2<Double>] = []
                for i in 0..<(pts.count - 1) {
                    let a = pts[i], b = pts[i + 1]
                    let n = max(Int((simd_distance(a, b) / 2).rounded(.up)), 1)
                    for k in 0..<n { pts2.append(a + (b - a) * (Double(k) / Double(n))) }
                }
                pts2.append(pts[pts.count - 1])
                let pts = pts2
                var prev: (UInt32, UInt32)?
                for i in pts.indices {
                    let a = pts[max(i - 1, 0)], c = pts[min(i + 1, pts.count - 1)]
                    var d = c - a
                    let l = simd_length(d)
                    guard l > 1e-6 else { continue }
                    d /= l
                    let side = SIMD2(d.y, -d.x) * 0.55
                    let bed = min(Double(terrain.height(east: pts[i].x, north: pts[i].y)),
                                  Double(terrain.height(east: pts[i].x + side.x, north: pts[i].y + side.y)),
                                  Double(terrain.height(east: pts[i].x - side.x, north: pts[i].y - side.y)))
                    let y = Float(bed + 0.12)
                    let l0 = pts[i] - side, r0 = pts[i] + side
                    let sky = openSky(canopy, east: pts[i].x, north: pts[i].y)
                    let iL = out.streams.vertex(Float(l0.x), y, Float(-l0.y), 0, 1, 0, 0, 0)
                    out.streams.texcoord2(sky, 0)
                    let iR = out.streams.vertex(Float(r0.x), y, Float(-r0.y), 0, 1, 0, 1, 0)
                    out.streams.texcoord2(sky, 0)
                    if let (pl, pr) = prev {
                        out.streams.tri(pl, pr, iR)
                        out.streams.tri(pl, iR, iL)
                    }
                    prev = (iL, iR)
                }
            }
        }
    }

    // MARK: - Geometry

    /// Splits an irregular footprint into near-rectangular pieces, each
    /// roofed on its own: a cut along one of the footprint's box axes
    /// through an inner (reflex) corner, the one that leaves the pieces
    /// best filling their own boxes, repeated up to three times. Without
    /// it an L-shaped farmhouse gets one gable spanning its whole box, so
    /// from the road it reads as a tall, roofless brick block.
    static func roofPieces(_ ring: [SIMD2<Double>], depth: Int = 0) -> [[SIMD2<Double>]] {
        func fill(_ r: [SIMD2<Double>], _ area: Double) -> Double {
            let o = orientedBox(r)
            return area / max(4 * o.halfLong * o.halfShort, 1e-6)
        }
        let area = signedArea(ring)
        let own = fill(ring, area)
        guard own < 0.8, depth < 3, ring.count >= 5, area > 40 else { return [ring] }
        let obb = orientedBox(ring)
        var best: (score: Double, a: [SIMD2<Double>], b: [SIMD2<Double>])?
        let n = ring.count
        for i in 0..<n {
            let p0 = ring[(i + n - 1) % n], p1 = ring[i], p2 = ring[(i + 1) % n]
            // Reflex in a counter-clockwise ring.
            guard (p1.x - p0.x) * (p2.y - p1.y) - (p1.y - p0.y) * (p2.x - p1.x) < 0 else { continue }
            for axis in [obb.long, obb.short] {
                let normal = SIMD2(-axis.y, axis.x)
                let a = clipHalfPlane(ring, normal: normal, origin: p1)
                let b = clipHalfPlane(ring, normal: -normal, origin: p1)
                guard a.count >= 3, b.count >= 3 else { continue }
                let aa = signedArea(a), ab = signedArea(b)
                guard aa > 12, ab > 12 else { continue }
                let score = (fill(a, aa) * aa + fill(b, ab) * ab) / (aa + ab)
                if score > (best?.score ?? own + 0.08) { best = (score, a, b) }
            }
        }
        guard let best else { return [ring] }
        return roofPieces(best.a, depth: depth + 1) + roofPieces(best.b, depth: depth + 1)
    }

    static func cleaned(_ ring: [SIMD2<Double>]) -> [SIMD2<Double>] {
        var out: [SIMD2<Double>] = []
        for p in ring where out.last.map({ simd_distance($0, p) > 0.05 }) ?? true { out.append(p) }
        if out.count > 1, simd_distance(out[0], out[out.count - 1]) < 0.05 { out.removeLast() }
        return out
    }

    static func signedArea(_ r: [SIMD2<Double>]) -> Double {
        var a = 0.0
        for i in r.indices {
            let p = r[i], q = r[(i + 1) % r.count]
            a += p.x * q.y - q.x * p.y
        }
        return a / 2
    }

    struct Box {
        var centre: SIMD2<Double>
        var long: SIMD2<Double>
        var short: SIMD2<Double>
        var halfLong: Double
        var halfShort: Double
    }

    /// Minimum-area rectangle aligned with one of the polygon's edges.
    static func orientedBox(_ ring: [SIMD2<Double>]) -> Box {
        var best = Box(centre: .zero, long: SIMD2(1, 0), short: SIMD2(0, 1), halfLong: 1, halfShort: 1)
        var bestArea = Double.infinity
        for i in ring.indices {
            let e = ring[(i + 1) % ring.count] - ring[i]
            let l = simd_length(e)
            guard l > 1e-6 else { continue }
            let u = e / l, v = SIMD2(-u.y, u.x)
            var minU = Double.infinity, maxU = -Double.infinity, minV = Double.infinity, maxV = -Double.infinity
            for p in ring {
                let a = simd_dot(p, u), b = simd_dot(p, v)
                minU = min(minU, a); maxU = max(maxU, a); minV = min(minV, b); maxV = max(maxV, b)
            }
            let area = (maxU - minU) * (maxV - minV)
            if area < bestArea {
                bestArea = area
                let c = u * ((minU + maxU) / 2) + v * ((minV + maxV) / 2)
                let hu = (maxU - minU) / 2, hv = (maxV - minV) / 2
                best = hu >= hv
                    ? Box(centre: c, long: u, short: v, halfLong: hu, halfShort: hv)
                    : Box(centre: c, long: v, short: u, halfLong: hv, halfShort: hu)
            }
        }
        return best
    }

    /// Keeps the part of the polygon where dot(p - origin, normal) >= 0.
    static func clipHalfPlane(_ poly: [SIMD2<Double>], normal: SIMD2<Double>, origin: SIMD2<Double>) -> [SIMD2<Double>] {
        var out: [SIMD2<Double>] = []
        for i in poly.indices {
            let p = poly[i], q = poly[(i + 1) % poly.count]
            let dp = simd_dot(p - origin, normal), dq = simd_dot(q - origin, normal)
            if dp >= 0 { out.append(p) }
            if (dp >= 0) != (dq >= 0) {
                out.append(p + (q - p) * (dp / (dp - dq)))
            }
        }
        return cleaned(out)
    }

    /// Ear clipping for a simple counter-clockwise polygon.
    static func earClip(_ poly: [SIMD2<Double>]) -> [(Int, Int, Int)] {
        let n = poly.count
        guard n >= 3 else { return [] }
        var idx = Array(0..<n)
        var tris: [(Int, Int, Int)] = []
        func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        var guardCount = 0
        while idx.count > 3, guardCount < n * n {
            guardCount += 1
            var clipped = false
            for k in 0..<idx.count {
                let i0 = idx[(k + idx.count - 1) % idx.count], i1 = idx[k], i2 = idx[(k + 1) % idx.count]
                let a = poly[i0], b = poly[i1], c = poly[i2]
                if cross(a, b, c) <= 1e-12 { continue }
                var inside = false
                for j in idx where j != i0 && j != i1 && j != i2 {
                    let p = poly[j]
                    if cross(a, b, p) >= 0, cross(b, c, p) >= 0, cross(c, a, p) >= 0 { inside = true; break }
                }
                if inside { continue }
                tris.append((i0, i1, i2))
                idx.remove(at: k)
                clipped = true
                break
            }
            if !clipped { break }
        }
        if idx.count == 3 { tris.append((idx[0], idx[1], idx[2])) }
        return tris
    }
}
