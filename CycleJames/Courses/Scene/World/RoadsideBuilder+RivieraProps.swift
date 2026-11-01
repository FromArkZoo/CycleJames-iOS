import Foundation
import simd

/// The Riviera's street furniture, lamps and overhead lines
/// (`CourseArt.RivieraProp`, `LampStyle.galvanisedLED` and `.castIron`,
/// `PoleKind.woodBundle` and `.concreteBundle`), from the photos in the
/// look bible (look.md sections 5-6) and the 2026 piazza photos.
extension BuildingBuilder {
    /// The sign atlas's cells for a region (`WorldLook.signAtlas`): the
    /// Flemish `signCells`, or the Riviera's cj_signs_it_map.json.
    static func signCells(for look: WorldLook) -> [String: SignCell] {
        look.isRiviera ? signCellsIT : signCells
    }

    static let signCellsIT: [String: SignCell] = {
        guard let url = Bundle.main.url(forResource: "cj_signs_it_map", withExtension: "json")
                ?? Bundle.main.url(forResource: "cj_signs_it_map", withExtension: "json", subdirectory: "CourseTextures"),
              let data = try? Data(contentsOf: url),
              let cells = try? JSONDecoder().decode([SignCell].self, from: data) else { return [:] }
        return Dictionary(cells.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }()

    /// The Riviera wall standing at the edge on `side` at `s`, if any.
    static func edgeMasonry(_ corridor: RoadCorridor, s: Double, side: Double) -> CourseArt.Masonry? {
        corridor.art.masonry.first { $0.side * side > 0 && $0.span.contains(s) }
    }

    // MARK: - Lamps and poles

    /// A tall galvanised post with one straight arm and a flat LED head
    /// (8.5 m), or a dark-grey cast-iron post with a lantern (3.8 m). In
    /// front of a retaining wall at the edge it stands at the wall's foot
    /// (the start ramp); elsewhere a metre beyond the edge, behind the
    /// guardrail.
    static func rivieraLamp(_ out: inout Output, corridor: RoadCorridor, at s: Double, side: Double,
                            style: CourseArt.LampStyle) {
        let st = corridor.station(at: s)
        let reach = st.reach(side)
        let wall = edgeMasonry(corridor, s: s, side: side)
        let beyond = wall.map { $0.retains ? max($0.offset - 0.12, 0.02) : $0.offset + $0.thickness + 0.25 } ?? 1.0
        let p = RoadBuilder.vergePoint(corridor, st, side: side, offset: reach - st.halfWidth + beyond)
        let road = corridor.roadHeight(st, lateral: side * reach)
        let foot = Float(min(p.y, road + 0.02)) - 0.25
        let base = SIMD3<Float>(Float(p.east), foot, Float(-p.north))
        let toRoad = SIMD3<Float>(Float(-side * st.rightE), 0, Float(side * st.rightN))
        let along = SIMD3<Float>(Float(st.dirE), 0, Float(-st.dirN))
        let up = SIMD3<Float>(0, 1, 0)
        var metal = MeshBuffer(parts: 1), glass = MeshBuffer(parts: 1)
        switch style {
        case .castIron:
            castIronLamp(&metal, &glass, base: base, toRoad: toRoad, along: along)
            appendParts(&out.props, metal, map: [0: PropPart.darkMetal.rawValue])
        default:
            let top = base + up * 8.6
            TreeArchetype.tube(&metal, base, top, 0.085, 0.05, sides: 8, height: 100)
            TreeArchetype.tube(&metal, base, base + up * 0.6, 0.11, 0.1, sides: 8, height: 100)
            // The arm, rising 5° over the road, and the head on its end.
            let armEnd = top + toRoad * 1.5 + up * 0.13
            TreeArchetype.tube(&metal, top - up * 0.08, armEnd, 0.04, 0.035, sides: 6, height: 100)
            let head = armEnd + toRoad * 0.3 + up * 0.02
            emitPropBox(&metal, centre: head, x: toRoad, z: along, half: SIMD3(0.34, 0.045, 0.14))
            emitPropBox(&glass, centre: head - up * 0.05, x: toRoad, z: along, half: SIMD3(0.27, 0.008, 0.1))
            appendParts(&out.props, metal, map: [0: PropPart.galvanised.rawValue])
        }
        appendParts(&out.props, glass, map: [0: PropPart.lampGlass.rawValue])
    }

    /// A dark-grey cast-iron post, 3.8 m, its base swelling to a collar,
    /// and a four-sided lantern under a pointed cap (Piazza della Libertà,
    /// 2026 photos), into `metal` and `glass`.
    static func castIronLamp(_ metal: inout MeshBuffer, _ glass: inout MeshBuffer, base: SIMD3<Float>, toRoad: SIMD3<Float>,
                             along: SIMD3<Float>) {
        let up = SIMD3<Float>(0, 1, 0)
        let top = base + up * 3.8
        TreeArchetype.tube(&metal, base, top, 0.085, 0.045, sides: 8, height: 100)
        TreeArchetype.tube(&metal, base + up * 0.25, base + up * 0.9, 0.12, 0.09, sides: 8, height: 100)
        emitPropBox(&metal, centre: top + up * 0.02, x: toRoad, z: along, half: SIMD3(0.14, 0.025, 0.14))
        for (a, b) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
            emitPropBox(&metal, centre: top + toRoad * (a * 0.13) + along * (b * 0.13) + up * 0.28, x: toRoad, z: along,
                        half: SIMD3(0.014, 0.24, 0.014))
        }
        TreeArchetype.tube(&metal, top + up * 0.52, top + up * 0.78, 0.22, 0.02, sides: 4, height: 100)
        emitPropBox(&glass, centre: top + up * 0.28, x: toRoad, z: along, half: SIMD3(0.12, 0.23, 0.12))
    }

    /// The Riviera's overhead lines: timber or round concrete poles with a
    /// short bracket, no cross-arm, carrying a black twisted low-voltage
    /// bundle and a thin telephone line below it, both sagging well. On
    /// the uphill side they stand on the bank behind a retaining wall,
    /// elsewhere a little over a metre beyond the edge.
    static func buildBundlePoles(_ out: inout Output, corridor: RoadCorridor,
                                 run: (span: CourseArt.Span, spacing: Double, side: Double, kind: CourseArt.PoleKind)) {
        let side = run.side
        let concrete = run.kind == .concreteBundle
        var poles = MeshBuffer(parts: 1), wires = MeshBuffer(parts: 1), metal = MeshBuffer(parts: 1)
        var prev: [SIMD3<Float>]?
        var r = WorldRandom(seed: UInt64(run.span.lowerBound * 19 + 7))
        var s = run.span.lowerBound
        while s <= run.span.upperBound + 0.01 {
            let st = corridor.station(at: s)
            let reach = st.reach(side)
            let wall = edgeMasonry(corridor, s: s, side: side)
            let beyond = wall.map { $0.retains ? $0.offset + $0.thickness + 0.4 : $0.offset + $0.thickness + 0.6 } ?? 1.3
            let p = RoadBuilder.vergePoint(corridor, st, side: side, offset: reach - st.halfWidth + beyond)
            let ground = Double(corridor.terrain.height(east: p.east, north: p.north))
            let road = corridor.roadHeight(st, lateral: side * reach)
            // On a wall's bank the ground there; on the verge the verge.
            let footY = wall?.retains == true ? max(ground, road) : p.y
            let base = SIMD3<Float>(Float(p.east), Float(footY) - 0.3, Float(-p.north))
            let h: Float = (concrete ? 9.0 : 8.0) + r.range(-0.4, 0.4)
            let lean = SIMD3<Float>(r.range(-0.015, 0.015), 1, r.range(-0.015, 0.015))
            let top = base + lean * (h + 0.3)
            if concrete {
                TreeArchetype.tube(&poles, base, top, 0.15, 0.09, sides: 8, height: 100)
            } else {
                TreeArchetype.tube(&poles, base, top, 0.13, 0.1, sides: 7, height: 100)
            }
            let toRoad = SIMD3<Float>(Float(-side * st.rightE), 0, Float(side * st.rightN))
            let bracket = top - SIMD3(0, 0.45, 0)
            TreeArchetype.tube(&metal, bracket, bracket + toRoad * 0.3, 0.025, 0.025, sides: 4, height: 100)
            let hangs = [bracket + toRoad * 0.3 - SIMD3(0, 0.05, 0), top - SIMD3(0, 1.4, 0) - toRoad * 0.12]
            if let prev {
                for (k, radius) in [(0, Float(0.016)), (1, Float(0.005))] {
                    let a = prev[k], b = hangs[k]
                    let sag = (k == 0 ? 0.03 : 0.022) * simd_length(b - a)
                    var last = a
                    for j in 1...8 {
                        let f = Float(j) / 8
                        let q = a + (b - a) * f - SIMD3(0, 4 * sag * f * (1 - f), 0)
                        TreeArchetype.tube(&wires, last, q, radius, radius, sides: 4, height: 100)
                        last = q
                    }
                }
            }
            prev = hangs
            s += run.spacing * Double(r.range(0.9, 1.1))
        }
        appendParts(&out.props, poles, map: [0: (concrete ? PropPart.concrete : .darkWood).rawValue])
        appendParts(&out.props, metal, map: [0: PropPart.galvanised.rawValue])
        appendParts(&out.props, wires, map: [0: PropPart.wire.rawValue])
    }

    // MARK: - Furniture

    /// One `CourseArt.RivieraProp` at its route distance and offset, facing
    /// the road (turned by `turn`).
    static func rivieraProp(_ prop: CourseArt.RivieraProp, item: CourseArt.Furniture, corridor: RoadCorridor,
                            kit: inout RoadsideKit) {
        let st = corridor.station(at: item.s)
        let p = RoadBuilder.vergePoint(corridor, st, side: item.side, offset: st.reach(item.side) - st.halfWidth + item.offset)
        let g = SIMD3<Float>(Float(p.east), Float(p.y), Float(-p.north))
        let along = SIMD3<Float>(Float(st.dirE), 0, Float(-st.dirN))
        let toRoad = SIMD3<Float>(Float(-item.side * st.rightE), 0, Float(item.side * st.rightN))
        let t = Float(item.turn * .pi / 180)
        let fwd = simd_normalize(toRoad * cos(t) + along * sin(t) * Float(item.side))
        rivieraProp(prop, at: g, fwd: fwd, along: along, corridor: corridor, kit: &kit)
    }

    /// One `CourseArt.placed` prop on the ground at its map position; a row
    /// (blocks, bollards) and a piazza's length run to its right.
    static func placedProp(_ item: (prop: CourseArt.RivieraProp, east: Double, north: Double, facing: Double),
                           corridor: RoadCorridor, kit: inout RoadsideKit) {
        let h = item.facing * .pi / 180
        let fwd = SIMD3<Float>(Float(sin(h)), 0, Float(-cos(h)))
        let g = SIMD3<Float>(Float(item.east), Float(corridor.terrain.height(east: item.east, north: item.north)),
                             Float(-item.north))
        rivieraProp(item.prop, at: g, fwd: fwd, along: simd_cross(fwd, SIMD3(0, 1, 0)), corridor: corridor, kit: &kit)
    }

    /// A prop standing on `g`, its front `fwd`; rows and a piazza's length
    /// run along `along` (the road's direction for furniture by the road).
    static func rivieraProp(_ prop: CourseArt.RivieraProp, at g: SIMD3<Float>, fwd: SIMD3<Float>, along: SIMD3<Float>,
                            corridor: RoadCorridor, kit: inout RoadsideKit) {
        let up = SIMD3<Float>(0, 1, 0)
        // Its length to the right of its front.
        let x = simd_cross(fwd, up)
        func at(_ c: SIMD3<Float>) -> SIMD3<Float> { g + x * c.x + up * c.y + fwd * c.z }
        func box(_ m: inout MeshBuffer, _ c: SIMD3<Float>, _ half: SIMD3<Float>) {
            emitPropBox(&m, centre: at(c), x: x, z: fwd, half: half)
        }
        switch prop {
        case .jerseyBlocks(let n):
            // Along the road, 2 m blocks, white and red in turn.
            for i in 0..<n {
                var m = MeshBuffer(parts: 1)
                let c = g + along * ((Float(i) - Float(n - 1) / 2) * 2.04)
                let across = simd_cross(up, along)
                for (y, hy, hz) in [(Float(0.04), Float(0.05), Float(0.3)), (0.22, 0.13, 0.2), (0.57, 0.23, 0.09)] {
                    emitPropBox(&m, centre: c + up * y, x: along, z: across, half: SIMD3(0.99, hy, hz))
                }
                kit.paint(m, i % 2 == 0 ? "paint.white" : "paint.red")
            }
        case .van:
            // The growers' white vans on the shoulder (2024 frames at
            // 2135-2152 m), the summit's parked-car model (RoadsideBuilder+
            // Cars.swift: a Ducato-sized van standing on the plane through
            // its wheels, cab glass, dark underside; the old box van on four
            // bare wheels read as a box on stilts). Its length on `x`. On the
            // gravel shoulder at about the verge's height: the 1 m terrain
            // there falls to the sea and tipped it over 20 degrees.
            let shoulder = Double(g.y)
            parkedCar(.van, paint: .white, centre: SIMD2(Double(g.x), Double(-g.z)),
                      facing: SIMD2(Double(x.x), Double(-x.z)),
                      ground: { min(max(Double(corridor.terrain.height(east: $0.x, north: $0.y)), shoulder - 0.15),
                                    shoulder + 0.15) }, kit: &kit)
        case .planter:
            // A brick box on a white concrete base, a concrete rim.
            kit.stoneBox(at(SIMD3(0, 0.12, 0)), along: x, half: SIMD3(0.8, 0.24, 0.8), stone: .whiteRender)
            kit.stoneBox(at(SIMD3(0, 0.62, 0)), along: x, half: SIMD3(0.62, 0.26, 0.62), stone: .brick)
            kit.stoneBox(at(SIMD3(0, 0.91, 0)), along: x, half: SIMD3(0.66, 0.04, 0.66), stone: .coping,
                         footY: at(SIMD3(0, -0.12, 0)).y)
        case .riderSculpture:
            riderSculpture(at: g, x: x, fwd: fwd, kit: &kit)
        case .piazza(let width, let depth):
            piazza(centre: SIMD2(Double(g.x), Double(-g.z)), along: simd_normalize(SIMD2(Double(along.x), Double(-along.z))),
                   width: width, depth: depth, corridor: corridor, kit: &kit)
        case .bench:
            for sx in [-0.65, 0.65] as [Float] {
                kit.stoneBox(at(SIMD3(sx, 0.2, 0)), along: x, half: SIMD3(0.2, 0.24, 0.22), stone: .whiteRender)
            }
            var seat = MeshBuffer(parts: 1)
            box(&seat, SIMD3(0, 0.47, 0), SIMD3(0.95, 0.035, 0.24))
            kit.paint(seat, "paint.timber")
        case .bollards(let n):
            for i in 0..<n {
                let c = g + along * ((Float(i) - Float(n - 1) / 2) * 1.2)
                let foot = c - up * 0.2
                TreeArchetype.tube(&kit.concrete, foot, foot + up * 0.68, 0.12, 0.12, sides: 10, height: 100)
                TreeArchetype.tube(&kit.concrete, foot + up * 0.68, foot + up * 0.74, 0.12, 0.05, sides: 10, height: 100)
            }
        case .phoneBox:
            #if DEBUG
            guard ProcessInfo.processInfo.arguments.contains("-poggioPhoneBox") else { return }
            phoneBox(at: g, x: x, fwd: fwd, kit: &kit)
            #else
            return
            #endif
        case .wheelieBins:
            for (i, key) in ["paint.bin.green", "paint.bin.brown", "paint.bin.blue"].enumerated() {
                var m = MeshBuffer(parts: 1)
                let cx = Float(i - 1) * 0.68
                box(&m, SIMD3(cx, 0.5, 0), SIMD3(0.29, 0.5, 0.36))
                box(&m, SIMD3(cx, 1.03, -0.02), SIMD3(0.31, 0.03, 0.39))
                kit.paint(m, key)
            }
        case .cctvPole:
            let foot = g - up * 0.3
            TreeArchetype.tube(&kit.galvanised, foot, foot + up * 6.3, 0.07, 0.05, sides: 8, height: 100)
            var m = MeshBuffer(parts: 1)
            emitPropBox(&m, centre: foot + up * 5.9 + fwd * 0.2, x: x, z: fwd, half: SIMD3(0.07, 0.07, 0.17))
            TreeArchetype.tube(&m, foot + up * 6.3, foot + up * 6.3 + fwd * 0.35 - up * 0.05, 0.05, 0.16, sides: 8, height: 100)
            kit.paint(m, "paint.white")
        case .gatePillars(let gap):
            let half = Float(gap / 2) + 0.22
            for sx in [-half, half] {
                kit.stoneBox(at(SIMD3(sx, 0.8, 0)), along: x, half: SIMD3(0.22, 1.1, 0.22), stone: .whiteRender)
                kit.stoneBox(at(SIMD3(sx, 1.95, 0)), along: x, half: SIMD3(0.28, 0.05, 0.28), stone: .coping,
                             footY: at(SIMD3(sx, -0.3, 0)).y)
            }
            // The gate: black bars and spears between the pillars.
            var m = MeshBuffer(parts: 1)
            let bars = Int(gap / 0.12)
            for k in 0...bars {
                let bx = -Float(gap / 2) + Float(k) * Float(gap) / Float(bars)
                emitPropBox(&m, centre: at(SIMD3(bx, 0.82, 0)), x: x, z: fwd, half: SIMD3(0.008, 0.78, 0.008))
                TreeArchetype.tube(&m, at(SIMD3(bx, 1.6, 0)), at(SIMD3(bx, 1.7, 0)), 0.02, 0, sides: 4, height: 100)
            }
            for y in [0.15, 1.45] as [Float] { box(&m, SIMD3(0, y, 0), SIMD3(Float(gap / 2), 0.02, 0.012)) }
            kit.dark.append(m, sx: 1, sy: 1, sz: 1, yaw: 0, tx: 0, ty: 0, tz: 0)
        case .castIronLamp:
            castIronLamp(&kit.dark, &kit.glass, base: g - up * 0.25, toRoad: fwd, along: x)
        }
    }

    /// The 2026 sculpture on Piazza della Libertà (photos of August 2026):
    /// a white rendered wedge 2.6 m long and 0.55 m thick, rising from
    /// 0.7 to 1.05 m, a corten plate along its sloping top, and on it three
    /// stylised riders cut from corten bar, each two wheel rings, a zigzag
    /// body and a disc head, smaller up the slope. The navy inscriptions on
    /// its long faces.
    static func riderSculpture(at g: SIMD3<Float>, x: SIMD3<Float>, fwd: SIMD3<Float>, kit: inout RoadsideKit) {
        let up = SIMD3<Float>(0, 1, 0)
        let half: Float = 1.3, h0: Float = 0.7, h1: Float = 1.05, depth: Float = 0.275
        func y(_ u: Float) -> Float { h0 + (h1 - h0) * (u + half) / (2 * half) }
        let foot = g.y - 0.2
        func P(_ u: Float, _ yy: Float, _ d: Float) -> SIMD3<Float> { SIMD3(g.x, foot, g.z) + x * u + up * yy + fwd * d }
        let fy = Array(repeating: foot, count: 4)
        // Faces: front, back, ends, the sloping top.
        kit.stoneQuad([P(-half, 0, depth), P(half, 0, depth), P(half, y(half) + 0.2, depth), P(-half, y(-half) + 0.2, depth)],
                      normals: Array(repeating: fwd, count: 4), along: [0, 2.6, 2.6, 0], foot: fy, stone: .whiteRender)
        kit.stoneQuad([P(half, 0, -depth), P(-half, 0, -depth), P(-half, y(-half) + 0.2, -depth), P(half, y(half) + 0.2, -depth)],
                      normals: Array(repeating: -fwd, count: 4), along: [0, 2.6, 2.6, 0], foot: fy, stone: .whiteRender)
        kit.stoneQuad([P(half, 0, depth), P(half, 0, -depth), P(half, y(half) + 0.2, -depth), P(half, y(half) + 0.2, depth)],
                      normals: Array(repeating: x, count: 4), along: [0, 0.55, 0.55, 0], foot: fy, stone: .whiteRender)
        kit.stoneQuad([P(-half, 0, -depth), P(-half, 0, depth), P(-half, y(-half) + 0.2, depth), P(-half, y(-half) + 0.2, -depth)],
                      normals: Array(repeating: -x, count: 4), along: [0, 0.55, 0.55, 0], foot: fy, stone: .whiteRender)
        let slope = simd_normalize(x * (2 * half) + up * (h1 - h0))
        let topN = simd_normalize(simd_cross(slope, fwd))
        let n = simd_dot(topN, up) > 0 ? topN : -topN
        kit.stoneQuad([P(-half, y(-half) + 0.2, depth), P(half, y(half) + 0.2, depth), P(half, y(half) + 0.2, -depth),
                       P(-half, y(-half) + 0.2, -depth)], normals: [n, n, n, n], along: [0, 2.6, 2.6, 0], foot: fy,
                      stone: .whiteRender)
        // The inscriptions, 2 mm proud of the long faces.
        var unused = MeshBuffer(parts: 1)
        for (key, nn, r) in [("it.inscription.classicissima", fwd, x), ("it.inscription.sanremo", -fwd, -x)] {
            guard let cell = kit.cells[key] else { continue }
            let c = P(0, 0.2 + 0.42, 0) + nn * (depth + 0.002)
            plate(&kit.sign, &unused, cell: cell, centre: c, right: r, normal: nn)
        }
        // The corten plate on top and the riders on it.
        var corten = MeshBuffer(parts: 1)
        for k in 0..<10 {
            let u0 = -half - 0.05 + Float(k) * (2 * half + 0.1) / 10, u1 = u0 + (2 * half + 0.1) / 10
            let a = P(u0, y(u0) + 0.2 + 0.015, 0), b = P(u1, y(u1) + 0.2 + 0.015, 0)
            TreeArchetype.tube(&corten, a, b, 0.02, 0.02, sides: 4, height: 100)
        }
        for (u, k) in [(Float(-0.82), Float(1.0)), (-0.05, 0.86), (0.7, 0.72)] {
            let base = P(u, y(u) + 0.2 + 0.035, 0)
            let r = 0.27 * k
            let rear = base + x * (-0.34 * k) + up * r, front = base + x * (0.34 * k) + up * r
            for c in [rear, front] {
                var last = c + x * r
                for j in 1...16 {
                    let a = Float(j) / 16 * 2 * .pi
                    let q = c + x * (r * cos(a)) + up * (r * sin(a))
                    TreeArchetype.tube(&corten, last, q, 0.016, 0.016, sides: 4, height: 100)
                    last = q
                }
            }
            // Hip, shoulder, hands, down to the front hub: a zigzag.
            func body(_ bx: Float, _ by: Float) -> SIMD3<Float> {
                let dx: SIMD3<Float> = x * (bx * k)
                let dy: SIMD3<Float> = up * (by * k)
                return base + dx + dy
            }
            let pts: [SIMD3<Float>] = [rear, body(-0.12, 0.8), body(0.22, 0.68), body(0.02, 0.5), front]
            for j in 1..<pts.count { TreeArchetype.tube(&corten, pts[j - 1], pts[j], 0.018, 0.018, sides: 4, height: 100) }
            let head = base + x * (0.08 * k) + up * (1.02 * k)
            TreeArchetype.tube(&corten, head - fwd * 0.012, head + fwd * 0.012, 0.13 * k, 0.13 * k, sides: 14, height: 100)
        }
        kit.paint(corten, "paint.corten")
    }

    /// A paved piazza: grey gneiss slabs over the ground in a grid, edged
    /// by a white marble kerb 25 cm wide and 6 cm proud, `width` along the
    /// road's direction and `depth` across it, centred on `centre`.
    static func piazza(centre: SIMD2<Double>, along: SIMD2<Double>, width: Double, depth: Double, corridor: RoadCorridor,
                       kit: inout RoadsideKit) {
        let across = SIMD2(along.y, -along.x)
        func ground(_ p: SIMD2<Double>) -> Double {
            // Clear of the carriageway it meets.
            if let d = corridor.mainRoadDistance(east: p.x, north: p.y), d.dist < d.halfWidth + 0.3 { return -.infinity }
            return Double(corridor.terrain.height(east: p.x, north: p.y))
        }
        func P(_ p: SIMD2<Double>, _ y: Double) -> SIMD3<Float> { SIMD3(Float(p.x), Float(y), Float(-p.y)) }
        let up = SIMD3<Float>(0, 1, 0)
        let nu = max(2, Int(width / 2)), nv = max(2, Int(depth / 2))
        func corner(_ i: Int, _ j: Int) -> SIMD2<Double> {
            centre + along * (width * (Double(i) / Double(nu) - 0.5)) + across * (depth * (Double(j) / Double(nv) - 0.5))
        }
        for i in 0..<nu {
            for j in 0..<nv {
                let c = [corner(i, j), corner(i + 1, j), corner(i + 1, j + 1), corner(i, j + 1)]
                let ys = c.map(ground)
                guard ys.allSatisfy({ $0.isFinite }) else { continue }
                let lift = 0.05
                kit.stoneQuad(zip(c, ys).map { P($0, $1 + lift) }, normals: [up, up, up, up], along: [0, 2, 2, 0],
                              foot: ys.map { Float($0) }, stone: .gneiss)
            }
        }
        // The marble edging.
        let ring = [corner(0, 0), corner(nu, 0), corner(nu, nv), corner(0, nv)]
        for k in 0..<4 {
            let a = ring[k], b = ring[(k + 1) % 4]
            let len = simd_distance(a, b)
            let steps = max(1, Int(len / 2))
            for j in 0..<steps {
                let p0 = a + (b - a) * (Double(j) / Double(steps)), p1 = a + (b - a) * (Double(j + 1) / Double(steps))
                let mid = (p0 + p1) / 2
                let y = ground(mid)
                guard y.isFinite else { continue }
                let d = simd_normalize(p1 - p0)
                kit.stoneBox(P(mid, y + 0.03), along: SIMD3(Float(d.x), 0, Float(-d.y)),
                             half: SIMD3(Float(simd_distance(p0, p1) / 2), 0.08, 0.125), stone: .whiteRender)
            }
        }
    }

    /// The red and silver Telecom phone box (2018 photo): silver aluminium
    /// corner posts, glazing above red lower panels, a red band under the
    /// roof, and on a mast over it the white disc with the red handset.
    static func phoneBox(at g: SIMD3<Float>, x: SIMD3<Float>, fwd: SIMD3<Float>, kit: inout RoadsideKit) {
        let up = SIMD3<Float>(0, 1, 0)
        func at(_ c: SIMD3<Float>) -> SIMD3<Float> { g + x * c.x + up * c.y + fwd * c.z }
        var silver = MeshBuffer(parts: 1), red = MeshBuffer(parts: 1), glass = MeshBuffer(parts: 1)
        for (cx, cz) in [(-0.46, -0.46), (0.46, -0.46), (0.46, 0.46), (-0.46, 0.46)] as [(Float, Float)] {
            emitPropBox(&silver, centre: at(SIMD3(cx, 1.15, cz)), x: x, z: fwd, half: SIMD3(0.035, 1.15, 0.035))
        }
        emitPropBox(&silver, centre: at(SIMD3(0, 2.33, 0)), x: x, z: fwd, half: SIMD3(0.5, 0.04, 0.5))
        emitPropBox(&silver, centre: at(SIMD3(0, 0.05, 0)), x: x, z: fwd, half: SIMD3(0.5, 0.05, 0.5))
        for (n, r) in [(fwd, x), (-fwd, -x), (x, -fwd), (-x, fwd)] {
            let c = g + n * 0.46
            emitPropBox(&red, centre: c + up * 2.18, x: r, z: n, half: SIMD3(0.43, 0.09, 0.012))
            if simd_dot(n, fwd) < 0.5 {
                emitPropBox(&red, centre: c + up * 0.58, x: r, z: n, half: SIMD3(0.43, 0.45, 0.012))
                emitPropBox(&glass, centre: c + up * 1.55, x: r, z: n, half: SIMD3(0.42, 0.5, 0.006))
            } else {
                emitPropBox(&glass, centre: c + up * 1.1, x: r, z: n, half: SIMD3(0.42, 0.95, 0.006))
            }
        }
        TreeArchetype.tube(&silver, at(SIMD3(0, 2.36, 0)), at(SIMD3(0, 2.95, 0)), 0.025, 0.025, sides: 6, height: 100)
        kit.paint(silver, "paint.silver")
        kit.paint(red, "paint.red")
        kit.paint(glass, "paint.glass")
        if let cell = kit.cells["it.phone"] {
            var back = MeshBuffer(parts: 1)
            plate(&kit.sign, &back, cell: cell, centre: at(SIMD3(0, 3.15, 0.03)), right: x, normal: fwd)
            kit.paint(back, "paint.silver")
        }
    }
}
