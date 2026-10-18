import Foundation
import simd

/// Flemish village buildings from the footprints, plus the roadside props
/// from the climb's description (street lamps, fences and paddock rails,
/// utility poles and their wires, brick walls) and water.
///
/// Walls are cut into 3 m facade bays mapped onto cj_facade.jpg (rows:
/// white-painted brick, red-brown brick, cream render, dark brick; columns:
/// upper window, ground window, door, blank). Gabled roofs split the
/// footprint along the ridge of its best-fit rectangle, so L-shaped and
/// irregular plans still get closed, sloping roofs.
enum BuildingBuilder {
    struct Output {
        var walls = MeshBuffer()
        /// Part 0 pantile, part 1 slate / dark tile.
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

    /// Material slots of `Output.props`, in `WorldMaterials.props` order.
    enum PropPart: Int, CaseIterable {
        case darkMetal = 0, lampGlass, wood, wire, whitePaint, concrete, darkWood, greyMetal
    }

    struct Style {
        var row: WallRow
        var pantile: Bool
        var pitchDeg: Double
        var shed: Bool
    }

    /// `canopy` is the LiDAR vegetation height above the ground, for the
    /// streams under the roadside bushes. Returns early, partly built, when
    /// the task is cancelled.
    static func build(corridor: RoadCorridor, scenery: SceneryFile?, canopy: HeightRaster? = nil) -> Output {
        var out = Output()
        let terrain = corridor.terrain
        for (index, b) in (scenery?.buildings ?? []).enumerated() {
            if Task.isCancelled { return out }
            var ring = b.ring.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }
            ring = cleaned(ring)
            guard ring.count >= 3 else { continue }
            if signedArea(ring) < 0 { ring.reverse() }
            let area = signedArea(ring)
            guard area > 4 else { continue }
            let style = chooseStyle(b, area: area, look: lookPlace(ring, corridor: corridor).map {
                corridor.art.houseLook(s: $0.s, routeDistance: $0.dist, side: $0.side, kind: b.kind)
            } ?? nil, index: index)
            // L-, T- and U-shaped plans are roofed piece by piece (churches
            // whole, for their single tower).
            let pieces = b.kind == "church" || b.roofShape == "flat" ? [ring] : roofPieces(ring)
            for (k, piece) in pieces.enumerated() {
                emitBuilding(&out, ring: piece, area: signedArea(piece), building: b, style: style, terrain: terrain,
                             corridor: corridor, seed: UInt64(index + 1) &+ UInt64(k) &* 7919)
            }
            out.count += 1
        }
        buildSummitWall(&out, corridor: corridor)
        buildLamps(&out, corridor: corridor)
        // Fences stop at the mouths of the side roads they would cross.
        let sideRoads = RoadBuilder.SideRoadMask(scenery: scenery)
        buildFences(&out, corridor: corridor, sideRoads: sideRoads)
        buildRails(&out, corridor: corridor, sideRoads: sideRoads)
        buildPoles(&out, corridor: corridor)
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

    // MARK: - Building

    static func emitBuilding(_ out: inout Output, ring: [SIMD2<Double>], area: Double, building b: SceneryFile.Building,
                             style: Style, terrain: TerrainSampler, corridor: RoadCorridor, seed: UInt64) {
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

        func roofY(_ p: SIMD2<Double>) -> Double {
            if flat { return ridgeY }
            let dn = abs(simd_dot(p - obb.centre, obb.short))
            return eaveY + rise * (1 - dn / max(hw, 0.01))
        }

        // Front door on the wall that faces the route.
        var doorEdge = -1
        if !style.shed {
            var best = Double.infinity
            for i in ring.indices {
                let a = ring[i], c = ring[(i + 1) % ring.count]
                guard simd_length(c - a) >= 3 else { continue }
                let mid = (a + c) / 2
                let d = corridor.coarse.query(east: mid.x, north: mid.y).dist
                if d < best { best = d; doorEdge = i }
            }
        }

        // Walls, split where the ridge line crosses an edge.
        for i in ring.indices {
            let a = ring[i], c = ring[(i + 1) % ring.count]
            var pts = [a]
            if !flat {
                let fa = simd_dot(a - obb.centre, obb.short), fc = simd_dot(c - obb.centre, obb.short)
                if fa * fc < 0 {
                    let t = fa / (fa - fc)
                    pts.append(a + (c - a) * t)
                }
            }
            pts.append(c)
            let total = simd_length(c - a)
            var along = 0.0
            for k in 0..<(pts.count - 1) {
                let p0 = pts[k], p1 = pts[k + 1]
                let len = simd_length(p1 - p0)
                emitWall(&out.walls, from: p0, to: p1, top0: roofY(p0), top1: roofY(p1), baseY: baseY, floorY: floorY,
                         eaveY: eaveY, style: style, door: i == doorEdge ? (total / 2 - along) : nil)
                along += len
            }
        }

        // Roof.
        let part = style.pantile ? 0 : 1
        let rectangular = area / (4 * obb.halfLong * obb.halfShort) > 0.86
        if flat {
            emitPolygon(&out.roofs, ring, y: { _ in ridgeY + 0.02 }, uv: { p in (Float(p.x), Float(p.y)) }, part: 1)
        } else if rectangular {
            let hl = obb.halfLong + 0.25, hs = hw + 0.35
            let slope = rise / max(hw, 0.01)
            let cosP = 1 / sqrt(1 + slope * slope)
            for side in [-1.0, 1.0] {
                let corners: [(Double, Double)] = side > 0 ? [(-hl, 0), (hl, 0), (hl, hs), (-hl, hs)] : [(hl, 0), (-hl, 0), (-hl, -hs), (hl, -hs)]
                let first = UInt32(out.roofs.vertexCount)
                for (t, n) in corners {
                    let p = obb.centre + obb.long * t + obb.short * n
                    let y = eaveY + rise * (1 - abs(n) / hw) + 0.03
                    out.roofs.vertex(Float(p.x), Float(y), Float(-p.y), 0, 1, 0, Float(t), Float(abs(n) / cosP))
                }
                out.roofs.tri(first, first + 1, first + 2, part: part)
                out.roofs.tri(first, first + 2, first + 3, part: part)
            }
        } else {
            let slope = rise / max(hw, 0.01)
            let cosP = 1 / sqrt(1 + slope * slope)
            for side in [-1.0, 1.0] {
                let half = clipHalfPlane(ring, normal: obb.short * side, origin: obb.centre)
                guard half.count >= 3 else { continue }
                emitPolygon(&out.roofs, half, y: { roofY($0) + 0.03 }, uv: { p in
                    let d = p - obb.centre
                    return (Float(simd_dot(d, obb.long)), Float(abs(simd_dot(d, obb.short)) / cosP))
                }, part: part)
            }
        }

        // A church gets its west tower and spire (Melden's Sint-Martinus is
        // seen from the upper climb); the LiDAR height is the spire tip.
        if b.kind == "church" {
            let ts = min(obb.halfShort * 2 * 0.8, 6.5)
            let west = obb.long.x > 0 ? -1.0 : 1.0
            let c = obb.centre + obb.long * (west * (obb.halfLong - ts / 2))
            let towerTop = floorY + height * 0.68
            emitBox(&out.walls, centre: c, along: obb.long, halfA: ts / 2, halfB: ts / 2, y0: baseY, y1: towerTop,
                    cell: (3, WallRow.darkBrick.rawValue))
            let side = SIMD2(obb.long.y, -obb.long.x)
            let h2 = ts / 2 + 0.2
            let along: SIMD2<Double> = obb.long * h2
            let across: SIMD2<Double> = side * h2
            let corners: [SIMD2<Double>] = [c - along - across, c + along - across,
                                            c + along + across, c - along + across]
            let apex = SIMD3<Float>(Float(c.x), Float(floorY + height), Float(-c.y))
            for k in 0..<4 {
                let p0 = corners[k], p1 = corners[(k + 1) % 4]
                let first = UInt32(out.roofs.vertexCount)
                out.roofs.vertex(Float(p0.x), Float(towerTop), Float(-p0.y), 0, 1, 0, 0, 0)
                out.roofs.vertex(Float(p1.x), Float(towerTop), Float(-p1.y), 0, 1, 0, Float(ts), 0)
                out.roofs.vertex(apex.x, apex.y, apex.z, 0, 1, 0, Float(ts / 2), Float(height * 0.32))
                out.roofs.tri(first, first + 1, first + 2, part: 1)
            }
        }

        // A chimney on most houses.
        if !flat, !style.shed, rnd.unit() < 0.6 {
            let t = Double(rnd.range(-0.6, 0.6)) * obb.halfLong
            let c = obb.centre + obb.long * t + obb.short * (hw * 0.25)
            let y0 = roofY(c) - 0.6
            emitBox(&out.walls, centre: c, along: obb.long, halfA: 0.28, halfB: 0.28, y0: y0, y1: ridgeY + 0.6,
                    cell: (3, WallRow.redBrick.rawValue))
        }
    }

    /// One wall run with a linear top, cut into facade bays and storeys.
    static func emitWall(_ m: inout MeshBuffer, from a: SIMD2<Double>, to c: SIMD2<Double>, top0: Double, top1: Double,
                         baseY: Double, floorY: Double, eaveY: Double, style: Style, door: Double?) {
        let len = simd_length(c - a)
        guard len > 0.05 else { return }
        let dir = (c - a) / len
        let nrm = SIMD2(dir.y, -dir.x)  // outward for counter-clockwise rings
        let bays = max(1, Int((len / 3.0).rounded()))
        let bw = len / Double(bays)
        let maxTop = max(top0, top1)
        let storeys = max(1, Int(ceil((maxTop - floorY) / 3.0)))
        let doorBay = door.map { min(max(Int($0 / bw), 0), bays - 1) }
        for bay in 0..<bays {
            let u0 = Double(bay) * bw, u1 = u0 + bw
            for k in 0..<storeys {
                let y0 = k == 0 ? baseY : floorY + Double(k) * 3
                let y1 = floorY + Double(k + 1) * 3
                let cellBase = floorY + Double(k) * 3
                // Clip the cell to the wall top.
                var poly: [(Double, Double)] = [(u0, y0), (u1, y0), (u1, y1), (u0, y1)]
                poly = clipTop(poly, len: len, top0: top0, top1: top1)
                guard poly.count >= 3 else { continue }
                let col: Int
                if style.shed || bw < 1.6 {
                    col = 3
                } else if k == 0 {
                    col = (doorBay == bay) ? 2 : 1
                } else {
                    let topAtCell = min(top0 + (top1 - top0) * u0 / len, top0 + (top1 - top0) * u1 / len)
                    col = (y1 <= eaveY + 0.35 && topAtCell >= y1 - 0.05) ? 0 : 3
                }
                let first = UInt32(m.vertexCount)
                for (u, y) in poly {
                    let p = a + dir * u
                    let fu = (u - u0) / bw
                    let fv = min(max((y - cellBase) / 3.0, 0), 1)
                    let uv = atlasUV(col: col, row: style.row.rawValue, fu: fu, fv: fv)
                    m.vertex(Float(p.x), Float(y), Float(-p.y), Float(nrm.x), 0, Float(-nrm.y), uv.0, uv.1)
                }
                for t in 1..<(poly.count - 1) {
                    m.tri(first, first + UInt32(t), first + UInt32(t + 1))
                }
            }
        }
    }

    @inline(__always)
    static func atlasUV(col: Int, row: Int, fu: Double, fv: Double) -> (Float, Float) {
        let inset = 0.006
        let u = (Double(col) + inset + fu * (1 - 2 * inset)) / 4
        let v = (Double(row) + inset + (1 - fv) * (1 - 2 * inset)) / 4
        return (Float(u), Float(v))
    }

    /// Clips a wall-space polygon (u, y) to y <= the linear wall top.
    static func clipTop(_ poly: [(Double, Double)], len: Double, top0: Double, top1: Double) -> [(Double, Double)] {
        func g(_ p: (Double, Double)) -> Double { top0 + (top1 - top0) * p.0 / len - p.1 }
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

    /// Closed box (walls and top) with facade-atlas texturing.
    static func emitBox(_ m: inout MeshBuffer, centre: SIMD2<Double>, along: SIMD2<Double>, halfA: Double, halfB: Double,
                        y0: Double, y1: Double, cell: (Int, Int)) {
        let side = SIMD2<Double>(along.y, -along.x)
        let a: SIMD2<Double> = along * halfA
        let b: SIMD2<Double> = side * halfB
        let c0: SIMD2<Double> = centre - a - b
        let c1: SIMD2<Double> = centre + a - b
        let c2: SIMD2<Double> = centre + a + b
        let c3: SIMD2<Double> = centre - a + b
        var ring: [SIMD2<Double>] = [c0, c1, c2, c3]
        if signedArea(ring) < 0 { ring.reverse() }
        let style = Style(row: WallRow(rawValue: cell.1) ?? .redBrick, pantile: false, pitchDeg: 0, shed: true)
        for i in 0..<4 {
            emitWall(&m, from: ring[i], to: ring[(i + 1) % 4], top0: y1, top1: y1, baseY: y0, floorY: y0,
                     eaveY: y1, style: style, door: nil)
        }
        let tris = earClip(ring)
        let first = UInt32(m.vertexCount)
        for p in ring {
            let uv = atlasUV(col: cell.0, row: cell.1, fu: 0.5, fv: 0.5)
            m.vertex(Float(p.x), Float(y1), Float(-p.y), 0, 1, 0, uv.0, uv.1)
        }
        for (a, b, c) in tris { m.tri(first + UInt32(a), first + UInt32(b), first + UInt32(c)) }
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
                        y1: max(ga, ground) + 1.7, cell: (3, WallRow.redBrick.rawValue))
            }
            prev = (here, ground)
            s += 3
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
        let lat = side * (st.halfWidth + (style == .curvedGrey ? 0.7 : 0.4))
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

    /// Post-and-rail paddock fences: square posts about 2.8 m apart and
    /// three rails (the dark-stained one along the Paterberg's upper ramp,
    /// white horse-paddock rails on the lower Kwaremont).
    static func buildRails(_ out: inout Output, corridor: RoadCorridor, sideRoads: RoadBuilder.SideRoadMask? = nil) {
        for run in corridor.art.rails {
            let s0 = run.span.lowerBound, s1 = run.span.upperBound, side = run.side
            let part: PropPart, railHeights: [Float]
            switch run.paint {
            case .darkStain: part = .darkWood; railHeights = [0.42, 0.78, 1.12]
            case .white: part = .whitePaint; railHeights = [0.55, 0.95, 1.3]
            case .paleTimber: part = .wood; railHeights = [0.55, 1.05]
            }
            var prev: (base: SIMD3<Float>, s: Double)?
            var s = s0
            var r = WorldRandom(seed: UInt64(s0 * 7 + 3))
            while s <= s1 + 0.01 {
                let st = corridor.station(at: s)
                let verge = side > 0 ? st.vergeRight : st.vergeLeft
                let o = min(1.4, max(verge - 0.5, 0.5))
                let p = RoadBuilder.vergePoint(corridor, st, side: side, offset: o)
                if sideRoads?.covers(east: p.east, north: p.north, margin: 0.5) == true {
                    prev = nil
                    s += Double(r.range(2.6, 3.0))
                    continue
                }
                let base = SIMD3<Float>(Float(p.east), Float(p.y) - 0.15, Float(-p.north))
                let along = SIMD3<Float>(Float(st.dirE), 0, Float(-st.dirN))
                let across = SIMD3<Float>(Float(st.rightE), 0, Float(-st.rightN))
                let top = railHeights.last! + 0.12
                var m = MeshBuffer(parts: 1)
                emitPropBox(&m, centre: base + SIMD3(0, (top + 0.15) / 2, 0), x: along, z: across,
                            half: SIMD3(0.06, (top + 0.15) / 2, 0.06))
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
