import XCTest
import simd
@testable import CycleJames

/// The village buildings: every vertex carries the channels its shader
/// reads (SceneKit silently draws the plain diffuse when one is missing),
/// a ground floor on a slope keeps its scale, with a plinth below it, and
/// every point of a wall is drawn exactly once, however its openings stack,
/// with no cracks between its pieces; no wall the road sees is left blank,
/// and the height above the ground the shader reads follows the ground.
final class BuildingBuilderTests: XCTestCase {
    private typealias BB = BuildingBuilder

    private func bundle(_ id: String) throws -> CourseBundle {
        do {
            return try CourseBundle.load(id: id)
        } catch {
            throw XCTSkip("\(id) data not in the test host bundle: \(error)")
        }
    }

    /// Wall vertices need texcoords 0-2 (`WorldShaders.wallSurface`), roof
    /// vertices 0-1 (`roofSurface`), with codes the shaders know.
    private func assertChannels(_ out: BB.Output, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let w = out.walls, r = out.roofs
        XCTAssertEqual(w.uvs.count, w.vertexCount * 2, "\(label): wall texcoord 0", file: file, line: line)
        XCTAssertEqual(w.uv2.count, w.vertexCount * 2, "\(label): wall texcoord 1", file: file, line: line)
        XCTAssertEqual(w.uv3.count, w.vertexCount * 2, "\(label): wall texcoord 2", file: file, line: line)
        XCTAssertEqual(r.uvs.count, r.vertexCount * 2, "\(label): roof texcoord 0", file: file, line: line)
        XCTAssertEqual(r.uv2.count, r.vertexCount * 2, "\(label): roof texcoord 1", file: file, line: line)
        for i in stride(from: 0, to: w.uv3.count, by: 2) {
            let code = Int(w.uv3[i].rounded())
            XCTAssertTrue((0...BB.WallKind.dryStone.rawValue).contains(code / 8), "\(label): wall code \(code)",
                          file: file, line: line)
            XCTAssertTrue((0..<1).contains(w.uv3[i + 1]), "\(label): wall seed", file: file, line: line)
        }
        for i in stride(from: 0, to: r.uv2.count, by: 2) {
            let id = r.uv2[i].rounded(.down)
            XCTAssertTrue((0...Float(BB.RoofTrim.darkRidge.rawValue)).contains(id), "\(label): roof id \(id)",
                          file: file, line: line)
        }
        // The geometry SceneKit gets has every channel too.
        for (mesh, sources) in [(w, 5), (r, 4)] where mesh.vertexCount > 0 {
            let g = mesh.geometry(materials: [])
            XCTAssertEqual(g?.sources.count, sources, "\(label): geometry sources", file: file, line: line)
        }
    }

    func test_everyCourseBuildingCarriesTheShaderChannels() throws {
        for id in CourseCatalog.courseIDs {
            let b = try bundle(id)
            let corridor = RoadCorridor(bundle: b, vergeWidth: 12)
            let out = BB.build(corridor: corridor, scenery: b.scenery)
            XCTAssertGreaterThan(out.walls.triangleCount, 1000, id)
            XCTAssertGreaterThan(out.roofs.triangleCount, 100, id)
            assertChannels(out, id)
        }
    }

    /// Each roof writer on its own: a gabled house, an L-shaped one (cut
    /// into pieces, with overhangs on the outer edges only), a flat roof, a
    /// barn and a church with its tower and spire. The barn shows the road
    /// its big door; the church's slate roof has the plain dark ridge.
    func test_everyRoofWriterEmitsItsChannels() throws {
        let b = try bundle("koppenberg")
        let corridor = RoadCorridor(bundle: b, vergeWidth: 12)
        let o = b.route.planar(at: 300) + SIMD2(25, 0)
        func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [[Double]] {
            [[o.x + x0, o.y + y0], [o.x + x1, o.y + y0], [o.x + x1, o.y + y1], [o.x + x0, o.y + y1]]
        }
        let ell: [[Double]] = [[0, 0], [14, 0], [14, 5], [5, 5], [5, 12], [0, 12]].map { [o.x + $0[0], o.y + $0[1]] }
        let cases: [(String, SceneryFile.Building)] = [
            ("gabled", .init(ring: rect(0, 0, 10, 6), heightM: 8, roofShape: "gabled", kind: "house", groundElevM: nil)),
            ("L-shaped", .init(ring: ell, heightM: 7.5, roofShape: "gabled", kind: "house", groundElevM: nil)),
            ("flat", .init(ring: rect(0, 0, 6, 6), heightM: 3.5, roofShape: "flat", kind: "house", groundElevM: nil)),
            ("barn", .init(ring: rect(0, 0, 14, 8), heightM: 7, roofShape: "gabled", kind: "barn", groundElevM: nil)),
            ("church", .init(ring: rect(0, 0, 24, 9), heightM: 28, roofShape: "gabled", kind: "church", groundElevM: nil)),
        ]
        for (label, building) in cases {
            let scenery = SceneryFile(schemaVersion: 1, buildings: [building], trees: nil, shrubs: nil, landuse: nil,
                                      roads: nil, fences: nil, water: nil)
            let out = BB.build(corridor: corridor, scenery: scenery)
            XCTAssertEqual(out.count, 1, label)
            XCTAssertGreaterThan(out.roofs.triangleCount, 2, label)
            assertChannels(out, label)
            let kinds = Set(stride(from: 0, to: out.walls.uv3.count, by: 2).map { Int(out.walls.uv3[$0].rounded()) / 8 })
            let ids = Set(stride(from: 0, to: out.roofs.uv2.count, by: 2).map { Int(out.roofs.uv2[$0].rounded(.down)) })
            if label == "barn" {
                XCTAssertFalse(kinds.isDisjoint(with: [BB.WallKind.timberDoor.rawValue, BB.WallKind.steelDoor.rawValue]),
                               "barn by the road has no door")
            }
            if label == "church" {
                XCTAssertTrue(ids.contains(BB.RoofTrim.darkRidge.rawValue), "slate roof without its ridge")
            }
        }
    }

    /// A ground floor on a 2 m slope: the floor is at the top of the slope,
    /// the wall starts 0.4 m under the lowest ground. Every part of the
    /// facade keeps the atlas's scale (3 m of wall to a cell, up and
    /// across), and everything below the floor is plinth.
    func test_groundFloorKeepsItsScaleOnASlope() {
        let ground = (0...9).map { 10.0 - 2.0 * Double($0) / 9 }
        let w = BB.WallFrame(a: .zero, dir: SIMD2(1, 0), len: 9, top0: 15.6, top1: 15.6, floorY: 10, baseY: 7.6, ground: ground)
        var style = BB.Style(row: .painted, pantile: false, pitchDeg: 40, shed: false)
        style.plinth = .tarPlinth
        style.plinthHeight = 0.6
        style.bayPitch = 2.8
        style.windowChance = 1
        var rnd = WorldRandom(seed: 5)
        let openings = BB.layoutOpenings(w, style: style, eaveY: 15.6, door: 4.5, front: true, rnd: &rnd)
        XCTAssertTrue(openings.contains { $0.cut == .door })
        XCTAssertGreaterThanOrEqual(openings.count, 4)
        for (i, a) in openings.enumerated() {
            XCTAssertGreaterThan(a.u0, 0.2)
            XCTAssertLessThan(a.u1, w.len - 0.2)
            XCTAssertLessThan(a.y1, 15.6)
            for b in openings[(i + 1)...] {
                XCTAssertFalse(a.u0 < b.u1 && b.u0 < a.u1 && a.y0 < b.y1 && b.y0 < a.y1, "openings overlap")
            }
        }
        var detailed = MeshBuffer(), bays = MeshBuffer()
        BB.emitWall(&detailed, w, style: style, openings: openings)
        BB.emitBayWall(&bays, w, style: style, windows: true, rnd: &rnd)
        let cases: [(MeshBuffer, ClosedRange<Float>)] = [(detailed, 0.9...1.1), (bays, 0.6...1.4)]
        for (m, across) in cases {
            assertUnstretched(m, floorY: 10, across: across)
        }
        assertDrawnOnce(detailed, w, "slope wall")
        assertDrawnOnce(bays, w, "slope bay wall")
        assertWatertight(detailed, w, "slope wall")
        assertWatertight(bays, w, "slope bay wall")
    }

    /// Atlas cells take 1 / 12 of the atlas (less its inset) per wall metre,
    /// v falling up the wall; the blank wall, which the shader wraps, a
    /// third of a cell per metre both ways (`BuildingBuilder.Paint`).
    private func assertUnstretched(_ m: MeshBuffer, floorY: Float, across: ClosedRange<Float>,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(m.uv2.count, m.vertexCount * 2, file: file, line: line)
        XCTAssertEqual(m.uv3.count, m.vertexCount * 2, file: file, line: line)
        XCTAssertGreaterThan(m.triangleCount, 10, file: file, line: line)
        let perM = Float((1 - 2 * 0.006) / 12)
        let tris = m.parts[0]
        var blank = 0
        for t in stride(from: 0, to: tris.count, by: 3) {
            let v = (0..<3).map { Int(tris[t + $0]) }
            let wrapped = m.uvs[2 * v[0]] > 1.5
            if wrapped { blank += 1 }
            for (i, j) in [(0, 1), (1, 2), (0, 2)] {
                let (a, b) = (v[i], v[j])
                XCTAssertEqual(m.uvs[2 * a] > 1.5, wrapped, "a triangle both blank and cut", file: file, line: line)
                let dy = m.positions[3 * a + 1] - m.positions[3 * b + 1]
                if abs(dy) > 0.05 {
                    XCTAssertEqual((m.uvs[2 * a + 1] - m.uvs[2 * b + 1]) / dy, wrapped ? 1.0 / 3 : -perM,
                                   accuracy: wrapped ? 1e-3 : perM * 1e-3, "texture stretched up the wall", file: file, line: line)
                }
                let dx = m.positions[3 * a] - m.positions[3 * b]
                if abs(dx) > 0.05 {
                    let s = (m.uvs[2 * a] - m.uvs[2 * b]) / dx
                    if wrapped {
                        XCTAssertEqual(s, 1.0 / 3, accuracy: 1e-3, "blank wall stretched across", file: file, line: line)
                    } else {
                        XCTAssertTrue(across.contains(s / perM), "texture stretched across the wall: \(s / perM)",
                                      file: file, line: line)
                    }
                }
            }
        }
        XCTAssertGreaterThan(blank, 0, file: file, line: line)
        for i in 0..<m.vertexCount where m.positions[3 * i + 1] < floorY - 0.01 {
            XCTAssertEqual(Int(m.uv3[2 * i].rounded()) / 8, BB.WallKind.tarPlinth.rawValue,
                           "not plinth below the floor", file: file, line: line)
        }
    }

    /// Every point of the face of `w` (which runs along +x from the origin),
    /// from its foot to its top, lies in exactly one triangle of `m`: no
    /// blank wall over a window or door (they z-fight), nothing left open.
    /// Points within 10 µm of a triangle's edge are skipped.
    private func assertDrawnOnce(_ m: MeshBuffer, _ w: BB.WallFrame, _ label: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        typealias P = SIMD2<Double>
        struct Tri { var a: P, b: P, c: P, lo: Double, hi: Double }
        var tris: [Tri] = []
        let idx = m.parts[0]
        for t in stride(from: 0, to: idx.count, by: 3) {
            let p = (0..<3).map { k -> P in
                let i = Int(idx[t + k])
                XCTAssertEqual(m.positions[3 * i + 2], 0, accuracy: 1e-5, "\(label): off the wall plane", file: file, line: line)
                return P(Double(m.positions[3 * i]), Double(m.positions[3 * i + 1]))
            }
            tris.append(Tri(a: p[0], b: p[1], c: p[2], lo: p.map(\.x).min()!, hi: p.map(\.x).max()!))
        }
        // Signed distance from the edge line a -> b.
        func side(_ a: P, _ b: P, _ q: P) -> Double {
            let e = b - a, l = simd_length(e)
            return l > 1e-9 ? (e.x * (q.y - a.y) - e.y * (q.x - a.x)) / l : 0
        }
        var bad: [String] = [], points = 0
        var u = 0.0137
        while u < w.len - 1e-3 {
            let column = tris.filter { $0.lo <= u && u <= $0.hi }
            var y = w.baseY + 0.0093
            let top = w.top(u)
            while y < top - 1e-3 {
                let q = P(u, y)
                var n = 0, onEdge = false
                for t in column {
                    let s0 = side(t.a, t.b, q), s1 = side(t.b, t.c, q), s2 = side(t.c, t.a, q)
                    let hi = max(s0, s1, s2), lo = min(s0, s1, s2)
                    if lo > 1e-5 || hi < -1e-5 {
                        n += 1
                    } else if !(hi > 1e-5 && lo < -1e-5) {
                        onEdge = true
                    }
                }
                if !onEdge {
                    points += 1
                    if n != 1, bad.count < 400 { bad.append(String(format: "(%.2f, %.2f) x%d", u, y - w.floorY, n)) }
                }
                y += 0.067
            }
            u += 0.0911
        }
        XCTAssertGreaterThan(points, 100, label, file: file, line: line)
        XCTAssertTrue(bad.isEmpty, "\(label): \(bad.count) of \(points) points not drawn once (u, y above floor): "
                      + bad.prefix(8).joined(separator: " "), file: file, line: line)
    }

    /// No T-junctions: every edge of a triangle of `m` inside the face of
    /// `w` (which runs along +x from the origin) is an edge of another
    /// triangle too, or a pixel crack of background can show along it; only
    /// edges on the outline stand alone.
    private func assertWatertight(_ m: MeshBuffer, _ w: BB.WallFrame, _ label: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        struct Edge: Hashable { var a: SIMD2<Int>, b: SIMD2<Int> }
        func key(_ i: Int) -> SIMD2<Int> {
            SIMD2(Int((m.positions[3 * i] * 1e4).rounded()), Int((m.positions[3 * i + 1] * 1e4).rounded()))
        }
        var count: [Edge: Int] = [:]
        let idx = m.parts[0]
        for t in stride(from: 0, to: idx.count, by: 3) {
            let v = (0..<3).map { Int(idx[t + $0]) }
            let p = v.map { SIMD2(Double(m.positions[3 * $0]), Double(m.positions[3 * $0 + 1])) }
            let area = (p[1].x - p[0].x) * (p[2].y - p[0].y) - (p[1].y - p[0].y) * (p[2].x - p[0].x)
            guard abs(area) > 1e-10 else { continue }
            for (i, j) in [(0, 1), (1, 2), (2, 0)] {
                let a = key(v[i]), b = key(v[j])
                guard a != b else { continue }
                count[(a.x, a.y) < (b.x, b.y) ? Edge(a: a, b: b) : Edge(a: b, b: a), default: 0] += 1
            }
        }
        var open: [String] = []
        for (e, n) in count where n == 1 {
            let pa = SIMD2(Double(e.a.x), Double(e.a.y)) / 1e4, pb = SIMD2(Double(e.b.x), Double(e.b.y)) / 1e4
            func both(_ f: (SIMD2<Double>) -> Bool) -> Bool { f(pa) && f(pb) }
            let outline = both { abs($0.x) < 2e-3 } || both { abs($0.x - w.len) < 2e-3 } || both { abs($0.y - w.baseY) < 2e-3 }
                || both { abs($0.y - w.top($0.x)) < 2e-3 }
            if !outline, open.count < 400 {
                open.append(String(format: "(%.3f, %.3f)-(%.3f, %.3f)", pa.x, pa.y - w.floorY, pb.x, pb.y - w.floorY))
            }
        }
        XCTAssertTrue(open.isEmpty, "\(label): \(open.count) inner edges with one triangle (T-junctions): "
                      + open.prefix(6).joined(separator: " "), file: file, line: line)
    }

    /// Two- and three-storey walls, flat-topped and gabled, with doors,
    /// windows stacked over them and gable windows: no blank wall is drawn
    /// over any of them (they used to z-fight, and a ground floor vanished),
    /// and no T-junction leaves a crack.
    func test_everyPointOfAWallIsDrawnOnce() {
        var rnd = WorldRandom(seed: 11)
        var stacked = 0
        for k in 0..<40 {
            let len = Double(rnd.range(4, 16))
            let floorY = 10.0
            let eave = floorY + Double(rnd.range(2.3, 6.8))
            var w = BB.WallFrame(a: .zero, dir: SIMD2(1, 0), len: len, top0: eave, top1: eave, floorY: floorY,
                                 baseY: floorY - 1.4, ground: [floorY - 0.6, floorY - 1.0])
            if k % 2 == 0 {
                w.uRidge = len * Double(rnd.range(0.4, 0.6))
                w.topRidge = eave + Double(rnd.range(2.7, 5))
            }
            var style = BB.Style(row: BB.WallRow(rawValue: k % 4)!, pantile: false, pitchDeg: 40, shed: false)
            BB.dress(&style, kind: "house", index: k)
            var lr = WorldRandom(seed: UInt64(k) + 1)
            let openings = BB.layoutOpenings(w, style: style, eaveY: eave, door: k % 3 == 0 ? len / 2 : nil, front: k % 4 != 1,
                                             seen: true, rnd: &lr)
            for (i, a) in openings.enumerated() {
                stacked += openings[(i + 1)...].filter { a.u0 < $0.u1 && $0.u0 < a.u1 }.count
            }
            var m = MeshBuffer()
            BB.emitWall(&m, w, style: style, openings: openings)
            assertDrawnOnce(m, w, "wall \(k) (\(openings.count) openings)")
            assertWatertight(m, w, "wall \(k) (\(openings.count) openings)")
        }
        XCTAssertGreaterThan(stacked, 20, "the walls should stack openings")
    }

    /// A barn's wall nearest the road: a big painted door, whole decimetres,
    /// on the floor and under the eave; along it small windows clear of the
    /// door, just under the eave (not mid-wall, like a house's); every point
    /// drawn once.
    func test_aBarnShowsTheRoadADoor() {
        for (k, len) in [14.0, 7, 4, 2.2].enumerated() {
            let w = BB.WallFrame(a: .zero, dir: SIMD2(1, 0), len: len, top0: 13.2, top1: 13.2, floorY: 10, baseY: 9.4,
                                 ground: [9.8, 9.8])
            var style = BB.Style(row: .redBrick, pantile: false, pitchDeg: 40, shed: true)
            BB.dress(&style, kind: "barn", index: k)
            var rnd = WorldRandom(seed: UInt64(k) + 3)
            let openings = BB.layoutShedOpenings(w, style: style, door: true, seen: true, rnd: &rnd)
            let doors = openings.filter { $0.painted != nil }
            XCTAssertEqual(doors.count, 1, "\(len) m wall")
            for d in doors {
                XCTAssertEqual(d.y0, 10, accuracy: 1e-9)
                XCTAssertLessThanOrEqual(d.y1, 13.2 - 0.3 + 1e-9)
                XCTAssertGreaterThan(d.u0, 0.3)
                XCTAssertLessThan(d.u1, len - 0.3)
                for size in [d.u1 - d.u0, d.y1 - d.y0] {
                    XCTAssertEqual(size * 10, (size * 10).rounded(), accuracy: 1e-6, "door size not whole decimetres")
                }
                XCTAssertGreaterThanOrEqual(d.u1 - d.u0, len >= 6 ? 2.6 : 0.8)
            }
            if len >= 14 { XCTAssertGreaterThan(openings.count, 1, "\(len) m barn wall with no windows") }
            for o in openings where o.painted == nil {
                XCTAssertLessThanOrEqual(o.y1, 13.2 - 0.1 + 1e-9, "barn window into the eave")
                XCTAssertGreaterThan(o.y1, 13.2 - 0.1 - BB.brickCourse, "barn window not under the eave")
                XCTAssertEqual((o.y0 - 10 - BB.OpeningCut.narrow.v.0) / BB.brickCourse,
                               ((o.y0 - 10 - BB.OpeningCut.narrow.v.0) / BB.brickCourse).rounded(), accuracy: 1e-6,
                               "barn window off the brick courses")
            }
            var m = MeshBuffer()
            BB.emitWall(&m, w, style: style, openings: openings)
            assertDrawnOnce(m, w, "barn wall \(len) m")
            assertWatertight(m, w, "barn wall \(len) m")
            let painted = stride(from: 0, to: m.uv3.count, by: 2).filter { Int(m.uv3[$0].rounded()) / 8 >= 6 }
            XCTAssertFalse(painted.isEmpty)
        }
    }

    /// Every wall the road sees shows it a window or door on its ground
    /// floor, however short (a single bay) or low its eave; a tall gable the
    /// road sees has a window under its ridge wherever one fits. Walls the
    /// road doesn't see may still be left blank.
    func test_aSeenWallIsNeverBlank() {
        var rnd = WorldRandom(seed: 23)
        var unseenBlank = 0, gables = 0
        for k in 0..<80 {
            let len = Double(rnd.range(1.8, 12))
            let floorY = 10.0
            let eave = floorY + Double(rnd.range(2.3, 6.5))
            var w = BB.WallFrame(a: .zero, dir: SIMD2(1, 0), len: len, top0: eave, top1: eave, floorY: floorY,
                                 baseY: floorY - 1, ground: [floorY - 0.5, floorY - 0.5])
            if k % 2 == 0 {
                w.uRidge = len * Double(rnd.range(0.4, 0.6))
                w.topRidge = eave + Double(rnd.range(2.7, 5))
            }
            var style = BB.Style(row: BB.WallRow(rawValue: k % 4)!, pantile: false, pitchDeg: 40, shed: false)
            BB.dress(&style, kind: "house", index: k)
            if eave - floorY < 2.9 { style.plinthHeight = min(style.plinthHeight, 0.42) }
            for seen in [true, false] {
                var lr = WorldRandom(seed: UInt64(k) + 1)
                let openings = BB.layoutOpenings(w, style: style, eaveY: eave, door: nil, front: false, seen: seen, rnd: &lr)
                let ground = openings.contains { $0.y0 < floorY + 2 }
                guard seen else {
                    if !ground { unseenBlank += 1 }
                    continue
                }
                XCTAssertTrue(ground, String(format: "seen wall %d (%.1f m, eave %.1f m): blank ground floor", k, len, eave - floorY))
                // A narrow window fits under the ridge on some upper floor.
                let storeys = Int(((w.maxTop - floorY) / 3 - 1e-6).rounded(.up))
                guard let r = w.uRidge, storeys > 1, (1..<storeys).contains(where: {
                    BB.fit(.narrow, w, style: style, centre: r, base: floorY + Double($0) * 3, drop: 6, clear: []) != nil
                }) else { continue }
                gables += 1
                XCTAssertTrue(openings.contains { $0.y0 > floorY + 2.5 && $0.u0 < r + 1 && r - 1 < $0.u1 },
                              String(format: "seen gable %d (%.1f m): no window under its ridge", k, len))
            }
        }
        XCTAssertGreaterThan(gables, 10)
        XCTAssertGreaterThan(unseenBlank, 5, "walls the road doesn't see should still be left blank at times")
    }

    /// Over a sag and a hump, the height above the ground the wall shader
    /// reads (texcoord 1 x, for the damp foot and the contact shade) is
    /// right to within a few centimetres all along the foot, not only at
    /// the wall's ends and openings; a wall on even ground gets no extra cut.
    func test_theFootFollowsTheGround() {
        let len = 14.0
        let ground = (0...14).map { k -> Double in
            let u = Double(k)
            return 10 - 0.8 * exp(-pow((u - 4.5) / 1.8, 2)) + 0.5 * exp(-pow((u - 10.5) / 1.5, 2))
        }
        let w = BB.WallFrame(a: .zero, dir: SIMD2(1, 0), len: len, top0: 15.5, top1: 15.5, floorY: 10.5, baseY: 8.8,
                             ground: ground)
        var style = BB.Style(row: .painted, pantile: false, pitchDeg: 40, shed: false)
        style.plinth = .tarPlinth
        style.plinthHeight = 0.6
        let door = BB.Opening(cut: .door, u0: 7, u1: 8.07, y0: 10.5, y1: 12.81)
        for openings in [[], [door]] {
            var m = MeshBuffer()
            BB.emitWall(&m, w, style: style, openings: openings)
            let label = "\(openings.count) openings"
            var worst = 0.0
            for u in stride(from: 0.05, to: len - 0.05, by: 0.1) {
                let h = 0.15
                guard let v = groundChannel(m, at: SIMD2(u, w.groundAt(u) + h)) else {
                    XCTFail("\(label): nothing drawn at \(u)")
                    continue
                }
                worst = max(worst, abs(Double(v) - h))
            }
            XCTAssertLessThan(worst, 2 * BB.groundTolerance, "\(label): the foot strays from the ground")
            assertDrawnOnce(m, w, label)
            assertWatertight(m, w, label)
        }
        let even = BB.WallFrame(a: .zero, dir: SIMD2(1, 0), len: 9, top0: 15.6, top1: 15.6, floorY: 10, baseY: 7.6,
                                ground: (0...9).map { 10.0 - 2.0 * Double($0) / 9 })
        XCTAssertTrue(BB.groundBreaks(even, tolerance: BB.groundTolerance).isEmpty)
    }

    /// Texcoord 1 x of `m` at the point `q` of its face (which runs along
    /// +x from the origin), interpolated in the triangle that holds it.
    private func groundChannel(_ m: MeshBuffer, at q: SIMD2<Double>) -> Float? {
        let idx = m.parts[0]
        for t in stride(from: 0, to: idx.count, by: 3) {
            let v = (0..<3).map { Int(idx[t + $0]) }
            let p = v.map { SIMD2(Double(m.positions[3 * $0]), Double(m.positions[3 * $0 + 1])) }
            let d = (p[1].x - p[0].x) * (p[2].y - p[0].y) - (p[2].x - p[0].x) * (p[1].y - p[0].y)
            guard abs(d) > 1e-12 else { continue }
            let b1 = ((q.x - p[0].x) * (p[2].y - p[0].y) - (p[2].x - p[0].x) * (q.y - p[0].y)) / d
            let b2 = ((p[1].x - p[0].x) * (q.y - p[0].y) - (q.x - p[0].x) * (p[1].y - p[0].y)) / d
            guard b1 >= -1e-9, b2 >= -1e-9, b1 + b2 <= 1 + 1e-9 else { continue }
            let h = v.map { Double(m.uv2[2 * $0]) }
            return Float(h[0] + (h[1] - h[0]) * b1 + (h[2] - h[0]) * b2)
        }
        return nil
    }

    /// The walls take the light raster: its arguments (no comment in the
    /// block), one fetch, then one apply, before the diffuse is written.
    func test_wallsTakeTheLightRaster() throws {
        let src = WorldShaders.wallSurface
        let args = src.components(separatedBy: "#pragma arguments")[1].components(separatedBy: "#pragma")[0]
        XCTAssertTrue(args.contains(WorldShaders.lightArgs))
        XCTAssertFalse(args.contains("//"), "a comment in the arguments block")
        XCTAssertEqual(src.components(separatedBy: WorldShaders.lightFetch).count, 2)
        XCTAssertEqual(src.components(separatedBy: WorldShaders.lightApply).count, 2)
        let f = try XCTUnwrap(src.range(of: WorldShaders.lightFetch)).lowerBound
        let a = try XCTUnwrap(src.range(of: WorldShaders.lightApply)).lowerBound
        let d = try XCTUnwrap(src.range(of: "_surface.diffuse = float4(alb, 1.0);")).lowerBound
        XCTAssertTrue(f < a && a < d)
    }

    /// Chimneys and garden walls have no eaves: no eave shade on their
    /// tops. The church tower, under its spire, keeps it.
    func test_boxesHaveNoEaves() {
        let style = BB.Style(row: .redBrick, pantile: false, pitchDeg: 40, shed: true)
        for eaves in [false, true] {
            var m = MeshBuffer()
            BB.emitBox(&m, centre: .zero, along: SIMD2(1, 0), halfA: 0.28, halfB: 0.28, y0: 10, y1: 12, style: style,
                       kind: .stack, eaves: eaves, ground: { _ in 10.6 })
            let below = stride(from: 1, to: m.uv2.count, by: 2).map { m.uv2[$0] }
            XCTAssertFalse(below.isEmpty)
            if eaves {
                XCTAssertTrue(below.contains { $0 < 1 })
            } else {
                XCTAssertTrue(below.allSatisfy { $0 == BB.noEaves })
            }
        }
    }

    /// Only the edges on the footprint overhang; the cut a neighbouring
    /// piece shares stays where it is, with a step where it meets an outer
    /// edge in line with it.
    func test_overhangMovesOnlyTheFootprintEdges() throws {
        let footprint: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(14, 0), SIMD2(14, 5), SIMD2(5, 5), SIMD2(5, 12), SIMD2(0, 12)]
        // The piece below a cut along y = 5 through the inner corner.
        let piece: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(14, 0), SIMD2(14, 5), SIMD2(5, 5), SIMD2(0, 5)]
        let out = try XCTUnwrap(BB.overhang(piece, footprint: footprint, d: 0.3))
        let expected: [SIMD2<Double>] = [SIMD2(-0.3, -0.3), SIMD2(14.3, -0.3), SIMD2(14.3, 5.3), SIMD2(5, 5.3),
                                         SIMD2(5, 5), SIMD2(-0.3, 5)]
        XCTAssertEqual(out.count, expected.count)
        for (p, q) in zip(out, expected) {
            XCTAssertEqual(p.x, q.x, accuracy: 1e-9)
            XCTAssertEqual(p.y, q.y, accuracy: 1e-9)
        }
    }

    /// Every wall-mounted sign finds its wall: its bracket ends on a
    /// footprint edge, its plates look out of the wall, their rims clear of
    /// it, and the plates and bracket stay under the eaves, well off the
    /// ground.
    func test_wallSignsHangFromAWall() throws {
        var mounted = 0
        for id in CourseCatalog.courseIDs {
            let b = try bundle(id)
            let corridor = RoadCorridor(bundle: b, vergeWidth: 12)
            guard corridor.art.signs.contains(where: { $0.mount == .wall }) else { continue }
            let rings = (b.scenery?.buildings ?? []).map { BB.cleaned($0.ring.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }) }
            let built = BB.build(corridor: corridor, scenery: b.scenery)
            for post in corridor.art.signs where post.mount == .wall {
                let label = "\(id): sign at \(post.s)"
                let wall = try XCTUnwrap(BB.wallMount(post, corridor: corridor, scenery: b.scenery), "\(label) has no wall")
                let onWall = rings.filter { $0.count >= 3 }.map { BB.distanceToRing(wall.foot, $0) }.min() ?? .infinity
                XCTAssertLessThan(onWall, 0.01, "\(label): bracket ends \(onWall) m off a wall")
                let n = BB.signNormal(post, at: corridor.station(at: post.s))
                let facing = Double(n.x) * wall.out.x - Double(n.z) * wall.out.y
                XCTAssertGreaterThan(facing, 0.3, "\(label) faces into its wall")
                for key in post.plates {
                    let cell = try XCTUnwrap(BB.signCells[key], key)
                    let reach = max(cell.w, cell.h) / 2 * (1 - facing * facing).squareRoot()
                    XCTAssertGreaterThan(BB.wallBracket - reach, 0.05, "\(label): \(key) cuts its wall")
                }
                // The built plates and bracket: the props' vertices within
                // their reach of the bracket, over head height.
                let c = wall.foot + wall.out * BB.wallBracket
                let ground = Float(corridor.terrain.height(east: wall.foot.x, north: wall.foot.y))
                var lowest = Float.infinity, seen = 0
                let p = built.props.positions
                for i in stride(from: 0, to: p.count, by: 3) where p[i + 1] > ground + 1 {
                    let q = SIMD2(Double(p[i]), Double(-p[i + 2]))
                    guard simd_distance(q, c) < 0.45 else { continue }
                    seen += 1
                    lowest = min(lowest, p[i + 1])
                    if let roof = BB.roofHeight(built.roofs, over: q) {
                        XCTAssertLessThan(p[i + 1], roof - 0.05, "\(label): into the eaves at \(q)")
                    }
                }
                XCTAssertGreaterThan(seen, 20, "\(label): no plate built")
                XCTAssertGreaterThan(lowest - ground, 1.8, "\(label): the plates hang \(lowest - ground) m up")
                mounted += 1
            }
        }
        XCTAssertGreaterThan(mounted, 0)
    }

    /// The domed chapel's body is a circle fitted to its footprint, clear of
    /// the porch that pushes out of it.
    func test_circleFitFindsTheBody() throws {
        let pts = (0..<10).map { k -> SIMD2<Double> in
            let a = Double(k) / 10 * 2 * .pi
            return SIMD2(358.9, 51.8) + SIMD2(cos(a), sin(a)) * 7.5
        }
        let fit = try XCTUnwrap(BB.fitCircle(pts))
        XCTAssertEqual(fit.centre.x, 358.9, accuracy: 1e-6)
        XCTAssertEqual(fit.centre.y, 51.8, accuracy: 1e-6)
        XCTAssertEqual(fit.radius, 7.5, accuracy: 1e-6)
        XCTAssertNil(BB.fitCircle([SIMD2(0, 0), SIMD2(1, 1), SIMD2(2, 2)]))
    }
}
