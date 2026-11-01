import XCTest
import simd
@testable import CycleJames

/// The Riviera's roadside (`BuildingBuilder.buildRivieraRoadside`): the
/// Flemish climbs carry none of it and build none of it; the Poggio's
/// hand-placed walls, rails, plates and furniture lie on its route with
/// sane sizes, its plates are on the Italian atlas, and every masonry
/// vertex carries a stone code the shader knows.
final class RoadsideRivieraTests: XCTestCase {
    private typealias BB = BuildingBuilder

    private func bundle(_ id: String) throws -> CourseBundle {
        do {
            return try CourseBundle.load(id: id)
        } catch {
            throw XCTSkip("\(id) data not in the test host bundle: \(error)")
        }
    }

    private let roadsideParts: [BB.PropPart] = [.masonry, .galvanised, .chainLink, .shadeNet]

    func test_flemishClimbsBuildNoneOfIt() throws {
        for id in CourseCatalog.courseIDs where id != "poggio" {
            let b = try bundle(id)
            let art = CourseArt.make(bundle: b)
            XCTAssertEqual(art.look, .flanders, id)
            XCTAssertFalse(art.hasRivieraRoadside, id)
            XCTAssertEqual(art.masonryWidth(b.climb.startS + 10, side: 1), 0, id)
            let corridor = RoadCorridor(bundle: b, vergeWidth: 13)
            let out = BB.build(corridor: corridor, scenery: b.scenery)
            for part in roadsideParts {
                XCTAssertTrue(out.props.parts[part.rawValue].isEmpty, "\(id): \(part) not empty")
            }
        }
    }

    func test_poggioRoadsideLiesOnTheRoute() throws {
        let b = try bundle("poggio")
        let art = CourseArt.make(bundle: b)
        let length = b.route.length
        XCTAssertTrue(art.look.isRiviera)
        XCTAssertTrue(art.hasRivieraRoadside)
        var spans: [(String, ClosedRange<Double>, Double)] = art.masonry.map { ("masonry", $0.span, $0.side) }
        spans += art.guardrails.map { ("guardrail", $0.span, $0.side) } + art.railings.map { ("railing", $0.span, $0.side) }
        for (kind, span, side) in spans {
            XCTAssertGreaterThanOrEqual(span.lowerBound, 0, "\(kind) \(span)")
            XCTAssertLessThanOrEqual(span.upperBound, length, "\(kind) \(span)")
            XCTAssertLessThan(span.lowerBound, span.upperBound, "\(kind) \(span)")
            XCTAssertEqual(abs(side), 1, "\(kind) \(span)")
        }
        for m in art.masonry {
            // The SP55's walls: up to 6 m on the start ramp (look.md), a
            // parapet's height a fixed one.
            XCTAssert((0.1...6.5).contains(m.height.lowerBound) && m.height.upperBound <= 6.5, "masonry \(m.span) \(m.height)")
            XCTAssert((0...3).contains(m.offset), "masonry \(m.span) offset \(m.offset)")
            if !m.retains { XCTAssertLessThanOrEqual(m.height.upperBound, 1.3, "parapet \(m.span)") }
        }
        // No two walls on one spot.
        for side in [-1.0, 1.0] {
            let runs = art.masonry.filter { $0.side == side }.map(\.span).sorted { $0.lowerBound < $1.lowerBound }
            for (a, c) in zip(runs, runs.dropFirst()) {
                XCTAssertLessThanOrEqual(a.upperBound, c.lowerBound + 0.01, "walls \(a) and \(c) overlap")
            }
        }
        for g in art.guardrails { XCTAssert((0.2...2).contains(g.offset), "guardrail \(g.span)") }
        for word in art.paintedWords {
            XCTAssertNotNil(art.masonry.first { $0.side == word.side && $0.span.contains(word.s) }, "\(word.text) on no wall")
        }
        let cells = BB.signCells(for: art.look)
        for c in art.chevrons {
            XCTAssert((0...length).contains(c.s))
            XCTAssertNotNil(cells[c.pointsLeft ? "it.chevron.left" : "it.chevron.right"])
        }
        for span in art.trolleyWires { XCTAssertLessThanOrEqual(span.upperBound, b.climb.startS) }
        // The piazza's pieces stand on the near terrain, within 80 m of the
        // summit corner and clear of the carriageway.
        let corridor = RoadCorridor(bundle: b, vergeWidth: 13)
        let apex = corridor.station(at: b.climb.endS)
        for item in art.placed {
            XCTAssertTrue(b.terrainNear.contains(east: item.east, north: item.north), "\(item.prop) off the terrain")
            XCTAssertLessThan(hypot(item.east - apex.east, item.north - apex.north), 80, "\(item.prop) far from the summit")
            if let d = corridor.mainRoadDistance(east: item.east, north: item.north) {
                XCTAssertGreaterThan(d.dist, d.halfWidth + 1, "\(item.prop) on the road")
            }
        }
    }

    /// Every Flemish paint and grate is on the Italian atlas too, so a prop
    /// painted from the atlas keeps its colour on the Riviera.
    func test_italianAtlasCarriesThePaints() {
        let it = BB.signCells(for: .riviera)
        XCTAssertFalse(it.isEmpty, "cj_signs_it_map.json not in the bundle")
        for key in BB.signCells.keys where key.hasPrefix("paint.") || key.hasPrefix("grate.") {
            XCTAssertNotNil(it[key], key)
        }
        for key in ["it.chevron.left", "it.mirror", "it.dir.sp55.poggio", "it.place.poggio", "paint.corten", "paint.white"] {
            XCTAssertNotNil(it[key], key)
        }
        XCTAssertEqual(it["it.dir.sp55.poggio"]?.shape, "arrowR")
    }

    /// The CTR's walls (scenery `walls`): a retaining wall along the edge is
    /// taken as the edge wall with its surveyed crest under the hand-placed
    /// look, a wall holding the road up faces the drop, and a terrace off
    /// the road is built where it stands.
    func test_mapWallsAtTheEdgeKeepTheirCrest() throws {
        let b = try bundle("poggio")
        let corridor = RoadCorridor(bundle: b, vergeWidth: 13)
        func road(_ s: Double, _ side: Double) -> Double {
            let st = corridor.station(at: s)
            return corridor.roadHeight(st, lateral: side * st.reach(side))
        }
        func line(_ s: StrideThrough<Double>, side: Double, beyond: Double, crest: (Double, SIMD2<Double>) -> Double)
            -> [[Double]] {
            s.map { s in
                let st = corridor.station(at: s)
                let p = st.point(lateral: side * (st.reach(side) + beyond))
                return [p.east, p.north, crest(s, SIMD2(p.east, p.north))]
            }
        }
        // A 4 m sandstone wall up the left (hand-placed span D, look s
        // 490-960), one holding the road up on the right where nothing is
        // hand-placed (look s 760-795), and a terrace 30 m up the bank.
        let walls = [
            SceneryFile.Wall(kind: "retaining", points: line(stride(from: 1000, through: 1040, by: 2), side: -1, beyond: 0.3)
                { s, _ in road(s, -1) + 4 }, heightM: 4),
            SceneryFile.Wall(kind: "retaining", points: line(stride(from: 1060, through: 1092, by: 2), side: 1, beyond: 0.4)
                { s, _ in road(s, 1) - 0.6 }, heightM: 2),
            SceneryFile.Wall(kind: "terrace", points: line(stride(from: 1300, through: 1330, by: 3), side: -1, beyond: 30)
                { _, p in Double(corridor.terrain.height(east: p.x, north: p.y)) + 1.2 }, heightM: 1.2),
        ]
        let edges = BB.EdgeWalls(corridor: corridor, walls: walls, sideRoads: RoadBuilder.SideRoadMask(scenery: nil))
        // Slots by route distance on a side (a side road's mouth may split a run).
        func slots(_ side: Double, _ range: ClosedRange<Double>) -> [(s: Double, slot: BB.EdgeWalls.Slot)] {
            edges.runs.filter { $0.side == side }.flatMap { run in
                run.slots.enumerated().map { (s: run.s0 + Double($0.offset) + 0.5, slot: $0.element) }
            }.filter { range.contains($0.s) }
        }
        let left = slots(-1, 1008...1032)
        XCTAssertGreaterThan(left.count, 15)
        for (s, slot) in left {
            XCTAssertEqual(slot.stone, .honeyRubble, "stone at \(s)")
            let crest = try XCTUnwrap(slot.crest, "no crest at \(s)")
            XCTAssertEqual(crest, road(s, -1) + 4, accuracy: 0.4, "crest at \(s)")
        }
        let right = slots(1, 1066...1086)
        XCTAssertGreaterThan(right.count, 10)
        XCTAssertTrue(right.allSatisfy { $0.slot.holdsRoad })
        XCTAssertNotNil(edges.consumed[0])
        XCTAssertNotNil(edges.consumed[1])
        XCTAssertNil(edges.consumed[2], "a terrace is no edge wall")

        // Built: the CTR's walls add masonry to the hand-placed roadside.
        func masonry(_ scenery: SceneryFile?) -> Int {
            var out = BB.Output()
            BB.buildRivieraRoadside(&out, corridor: corridor, scenery: scenery)
            return out.props.parts[BB.PropPart.masonry.rawValue].count
        }
        let scenery = SceneryFile(schemaVersion: 1, buildings: nil, trees: nil, shrubs: nil, landuse: nil, roads: nil,
                                  fences: nil, water: nil, walls: walls)
        XCTAssertGreaterThan(masonry(scenery), masonry(nil))
    }

    func test_poggioBuildsItsRoadside() throws {
        let b = try bundle("poggio")
        let corridor = RoadCorridor(bundle: b, vergeWidth: 13)
        var out = BB.Output()
        BB.buildRivieraRoadside(&out, corridor: corridor, scenery: b.scenery)
        let props = out.props
        XCTAssertFalse(props.parts[BB.PropPart.masonry.rawValue].isEmpty, "no walls")
        XCTAssertFalse(props.parts[BB.PropPart.galvanised.rawValue].isEmpty, "no guardrail")
        XCTAssertFalse(props.parts[BB.PropPart.whitePaint.rawValue].isEmpty, "no painted letters")
        XCTAssertEqual(props.uvs.count, props.vertexCount * 2)
        // Masonry vertices: a stone code the shader knows, metres along under
        // 1024, nothing NaN.
        var used = Set<Int>()
        for idx in props.parts[BB.PropPart.masonry.rawValue] {
            let i = Int(idx)
            let u = props.uvs[2 * i]
            let code = Int((u / 1024).rounded(.down))
            used.insert(code)
            XCTAssertTrue((0..<CourseArt.Stone.allCases.count).contains(code), "stone code \(code)")
            XCTAssertLessThan(u - Float(code) * 1024, 1024)
            XCTAssertFalse(props.positions[3 * i + 1].isNaN)
        }
        XCTAssertTrue(used.contains(CourseArt.Stone.honeyRubble.rawValue))
        XCTAssertTrue(used.contains(CourseArt.Stone.coping.rawValue))
    }

    /// The roadside's share of the Poggio's props mesh, piece by piece (the
    /// props are one node for the whole course, drawn without culling), held
    /// under a budget. With `CJ_ROADSIDE_STATS` set (TEST_RUNNER_ prefix on
    /// the xcodebuild command line) the breakdown is written to that path.
    func test_poggioRoadsideTriangles() throws {
        let b = try bundle("poggio")
        let corridor = RoadCorridor(bundle: b, vergeWidth: 13)
        let art = corridor.art
        let scenery = b.scenery
        let walls = scenery?.walls ?? []
        let sideRoads = RoadBuilder.SideRoadMask(scenery: scenery)
        var rows: [(String, Int)] = []
        func kitTris(_ build: (inout BB.RoadsideKit) -> Void) -> Int {
            var kit = BB.RoadsideKit(cells: BB.signCells(for: art.look))
            build(&kit)
            var out = BB.Output()
            kit.append(to: &out)
            return out.props.triangleCount
        }
        func outTris(_ build: (inout BB.Output) -> Void) -> Int {
            var out = BB.Output()
            build(&out)
            return out.props.triangleCount
        }
        let edges = BB.EdgeWalls(corridor: corridor, walls: walls, sideRoads: sideRoads)
        rows.append(("edge walls (stone, coping, what stands on them)", kitTris { kit in
            for run in edges.runs { BB.buildEdgeWall(run, corridor: corridor, kit: &kit) }
        }))
        for kind in ["terrace", "retaining", "masonry", "parapet", "fence"] {
            // Same indices, the other kinds emptied, so `consumed` still applies.
            let only = walls.map { $0.kind == kind ? $0 : SceneryFile.Wall(kind: "none", points: [], heightM: nil) }
            rows.append(("map walls: \(kind) (\(walls.filter { $0.kind == kind }.count))", kitTris { kit in
                BB.buildMapWalls(only, skip: edges.consumed, corridor: corridor, kit: &kit)
            }))
        }
        rows.append(("guardrail", kitTris { BB.buildGuardrails(corridor: corridor, sideRoads: sideRoads, kit: &$0) }))
        rows.append(("railings, fences, screens", kitTris { kit in
            for run in art.railings {
                let line = BB.vergeLine(corridor: corridor, span: run.span, side: run.side, offset: run.offset,
                                        sideRoads: sideRoads)
                for piece in line { BB.emitRailing(run.kind, line: piece, side: run.side, kit: &kit) }
            }
        }))
        rows.append(("painted words, chevrons, trolley wires", kitTris { kit in
            for word in art.paintedWords { BB.paintWord(word, corridor: corridor, kit: &kit) }
            for chevron in art.chevrons { BB.chevronPlate(chevron, corridor: corridor, kit: &kit) }
            for span in art.trolleyWires { BB.trolleyWires(span, corridor: corridor, kit: &kit) }
        }))
        rows.append(("furniture and the piazza", kitTris { kit in
            for item in art.furniture {
                if case .riviera(let prop) = item.kind { BB.rivieraProp(prop, item: item, corridor: corridor, kit: &kit) }
            }
            for item in art.placed { BB.placedProp(item, corridor: corridor, kit: &kit) }
        }))
        rows.append(("lamps", outTris { BB.buildLamps(&$0, corridor: corridor) }))
        rows.append(("poles and wires", outTris { BB.buildPoles(&$0, corridor: corridor) }))
        rows.append(("signs", outTris { BB.buildSigns(&$0, corridor: corridor, scenery: scenery,
                                                       cells: BB.signCells(for: art.look)) }))
        let roadside = rows.reduce(0) { $0 + $1.1 }
        let all = BB.build(corridor: corridor, scenery: scenery, courseID: "poggio").props.triangleCount
        var text = rows.map { "\($0.0): \($0.1)" }
        text.append("roadside total: \(roadside)")
        text.append("props total (BuildingBuilder.build): \(all)")
        if let path = ProcessInfo.processInfo.environment["CJ_ROADSIDE_STATS"] {
            try text.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        XCTAssertLessThan(roadside, 330_000, text.joined(separator: "; "))
    }
}
