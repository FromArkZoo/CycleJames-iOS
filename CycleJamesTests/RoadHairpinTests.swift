import XCTest
import simd
@testable import CycleJames

/// The Riviera road's cross-sections (`RoadCorridor.clearances`): round a
/// hairpin neither the carriageway nor the verge folds over itself, the
/// verge stops short of the other leg, a bend tighter than the road is
/// wide draws its inside to the bend's centre, and a road that never comes
/// back on itself keeps every section whole. Also the fans' stroke font
/// and the paint's channels.
final class RoadHairpinTests: XCTestCase {
    private typealias Station = RoadCorridor.Station

    /// A road north up `lead` metres of straight, a right-hand turn of
    /// `degrees` on radius `radius`, and `lead` metres on, every 0.25 m.
    private func road(radius: Double, degrees: Double = 180, halfWidth: Double = 2.75, verge: Double = 13,
                      lead: Double = 40) -> [Station] {
        var out: [Station] = []
        let step = 0.25
        var p = SIMD2<Double>(0, 0)
        var heading = 0.0  // radians from north, clockwise
        var s = 0.0
        let arc = radius * degrees * .pi / 180
        let total = lead * 2 + arc
        while s <= total + 1e-9 {
            // The part of this step on the arc turns it, so the bend turns
            // exactly `degrees` (a whole step at a time it fell 2° short,
            // and the legs splayed 1.4 m apart over the 40 m lead).
            let turn = max(0, min(s + step, lead + arc) - max(s, lead)) / radius
            let d = SIMD2(sin(heading), cos(heading))
            out.append(Station(s: s, east: p.x, north: p.y, elev: 0, dirE: d.x, dirN: d.y, halfWidth: halfWidth,
                               surface: 0, vergeLeft: verge, vergeRight: verge, reachLeft: halfWidth,
                               reachRight: halfWidth, curvature: turn / step, beyond: 0))
            // Midpoint rule along the arc.
            let h = heading + turn / 2
            p += SIMD2(sin(h), cos(h)) * step
            heading += turn
            s += step
        }
        return out
    }

    private func point(_ st: Station, _ lat: Double) -> SIMD2<Double> {
        let q = st.point(lateral: lat)
        return SIMD2(q.east, q.north)
    }

    /// Twice the signed area of a quad a-b-c-d (east, north), positive
    /// counter-clockwise from above: a cell running out to the right of
    /// travel and on up the road.
    private func area(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>) -> Double {
        let pts = [a, b, c, d]
        var acc = 0.0
        for i in 0..<4 {
            let p = pts[i], q = pts[(i + 1) % 4]
            acc += p.x * q.y - q.x * p.y
        }
        return acc
    }

    /// Every cell between consecutive stations, from the centreline out to
    /// the verge's end on `side`, keeps its winding: nothing folds.
    private func assertNoFold(_ st: [Station], side: Double, file: StaticString = #filePath, line: UInt = #line) {
        for i in 0..<(st.count - 1) {
            let a = st[i], b = st[i + 1]
            for (f0, f1) in [(0.0, 0.5), (0.5, 1.0)] {
                let a0 = point(a, side * a.reach(side) * f0), a1 = point(a, side * a.reach(side) * f1)
                let b0 = point(b, side * b.reach(side) * f0), b1 = point(b, side * b.reach(side) * f1)
                XCTAssertGreaterThanOrEqual(side * area(a0, a1, b1, b0), -1e-6,
                                            "carriageway folds at s \(a.s) side \(side)", file: file, line: line)
            }
            let va = side > 0 ? a.vergeRight : a.vergeLeft, vb = side > 0 ? b.vergeRight : b.vergeLeft
            let e0 = point(a, side * a.reach(side)), e1 = point(b, side * b.reach(side))
            let o0 = point(a, side * (a.reach(side) + va)), o1 = point(b, side * (b.reach(side) + vb))
            XCTAssertGreaterThanOrEqual(side * area(e0, o0, o1, e1), -1e-6,
                                        "verge folds at s \(a.s) side \(side)", file: file, line: line)
        }
    }

    func test_hairpinSectionsNeitherFoldNorReachTheOtherLeg() {
        for radius in [5.0, 6.0, 7.0] {
            var st = road(radius: radius)
            RoadCorridor.clearances(&st, vergeWidth: 13)
            // A 5.5 m road on a 5-7 m radius: the carriageway is whole.
            for s in st {
                XCTAssertEqual(s.reachLeft, s.halfWidth, accuracy: 1e-9)
                XCTAssertEqual(s.reachRight, s.halfWidth, accuracy: 1e-9)
            }
            assertNoFold(st, side: 1)
            assertNoFold(st, side: -1)
            // The legs run 2R apart: the inside verge reaches their midline
            // and no further, so it never lies on the other leg's tarmac.
            for s in st where s.s < 30 {
                XCTAssertLessThanOrEqual(s.halfWidth + s.vergeRight, radius + 0.01,
                                         "R \(radius): inside verge at s \(s.s) reaches the other leg")
            }
            XCTAssertEqual(st[40].halfWidth + st[40].vergeRight, radius, accuracy: 0.05)
            // The outside verge keeps its full width on the straights.
            XCTAssertEqual(st[10].vergeLeft, 13, accuracy: 1e-9)
        }
    }

    func test_bendTighterThanTheRoadDrawsItsInsideToTheCentre() {
        // The summit corner if the data held its OSM 3.6 m radius with the
        // junction's 10 m of tarmac.
        var st = road(radius: 3.6, degrees: 147, halfWidth: 5)
        RoadCorridor.clearances(&st, vergeWidth: 13)
        let mid = 40 + 3.6 * 147 * .pi / 360
        let apex = st.min { abs($0.s - mid) < abs($1.s - mid) }!
        XCTAssertLessThanOrEqual(apex.reachRight, 3.6 + 0.01)
        XCTAssertEqual(apex.reachLeft, 5, accuracy: 1e-9)
        XCTAssertEqual(apex.vergeRight, 0, accuracy: 1e-9)
        assertNoFold(st, side: 1)
        assertNoFold(st, side: -1)
    }

    func test_aRoadThatNeverComesBackKeepsItsSections() {
        // A gentle 60 m radius bend: nothing is cut.
        var st = road(radius: 60, degrees: 30)
        RoadCorridor.clearances(&st, vergeWidth: 13)
        for s in st {
            XCTAssertEqual(s.reachLeft, s.halfWidth, accuracy: 1e-9)
            XCTAssertEqual(s.reachRight, s.halfWidth, accuracy: 1e-9)
            XCTAssertEqual(s.vergeLeft, 13, accuracy: 1e-9)
        }
        XCTAssertGreaterThan(st.map(\.vergeRight).min()!, 13 - 1e-9)
    }

    func test_hairpinsAreFoundOnTheirSide() {
        var st = road(radius: 6)
        // The corridor's curvature, from the stations' directions.
        for i in st.indices {
            let a = st[max(i - 1, 0)], b = st[min(i + 1, st.count - 1)]
            var d = atan2(b.dirE, b.dirN) - atan2(a.dirE, a.dirN)
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            st[i].curvature = d / max(b.s - a.s, 0.05)
        }
        let apexes = RoadBuilder.hairpinApexes(st)
        XCTAssertEqual(apexes.count, 1)
        XCTAssertEqual(apexes.first?.side, 1)
        XCTAssertEqual(apexes.first?.s ?? 0, 40 + 3 * .pi, accuracy: 4)
        let (left, right) = RoadBuilder.hairpinWeights(st)
        XCTAssertEqual(right[Int((40 + 3 * Double.pi) / 0.25)], 1, accuracy: 1e-6)
        XCTAssertEqual(left.max()!, 0, accuracy: 1e-6)
    }

    /// A side road's kink is rounded over a few metres, its ends stay put
    /// and its straight stretches stay straight (`RoadBuilder.eased`).
    func test_sideRoadEasingRoundsKinksAndKeepsTheEnds() {
        let pts = (0...10).map { SIMD2(Double($0), 0) } + (1...10).map { SIMD2(10.0, Double($0)) }
        let e = RoadBuilder.eased(pts)
        XCTAssertEqual(e.count, pts.count)
        XCTAssertEqual(e.first!, pts.first!)
        XCTAssertEqual(e.last!, pts.last!)
        XCTAssertEqual(e[3], pts[3])
        // The corner moves in towards the bend's inside by about a metre.
        XCTAssertGreaterThan(simd_distance(e[10], pts[10]), 0.8)
        XCTAssertLessThan(simd_distance(e[10], pts[10]), 1.6)
    }

    /// On the Poggio the tarmac runs on to the face of a wall at the edge
    /// (`RoadCorridor.edgeAprons`): the walls' 0.14 m and the viewpoint
    /// lay-by's 0.9 m to its parapet; none on a Flemish climb.
    func test_poggioPavesToTheWallFace() throws {
        func bundle(_ id: String) throws -> CourseBundle {
            do { return try CourseBundle.load(id: id) } catch { throw XCTSkip("\(id) not in the test host: \(error)") }
        }
        let b = try bundle("poggio")
        let corridor = RoadCorridor(bundle: b, vergeWidth: 13)
        func p(_ look: Double) -> Double { CourseArt.poggioClimbStart + look * CourseArt.poggioScale }
        let aprons = RoadCorridor.edgeAprons(corridor, scenery: corridor.edgeScenery)
        XCTAssertFalse(aprons.isEmpty)
        // The lay-by (look 622-752, right; broken by the mouths of the
        // paths down to the villas) and the sandstone wall on the right
        // after hairpin 2 (look 1400-1690).
        let layBy = stride(from: p(625), to: p(750), by: 1.0).map { aprons.width($0, side: 1) }
        XCTAssertEqual(layBy.max()!, 0.9, accuracy: 0.01)
        XCTAssertGreaterThan(Double(layBy.filter { $0 > 0.89 }.count) / Double(layBy.count), 0.2)
        XCTAssertEqual(aprons.width(p(1550), side: 1), 0.14, accuracy: 0.01)
        let st = corridor.station(at: p(1550))
        XCTAssertEqual(RoadBuilder.apronWidth(aprons, st, side: 1), 0.26, accuracy: 0.01)
        // No wall across a side road's mouth, so no paving past the edge there.
        for j in corridor.junctions where j.s > p(0) && j.s < p(3700) {
            XCTAssertEqual(aprons.width(j.s, side: j.side), 0, accuracy: 0.3, "mouth at \(j.s)")
        }
        let flemish = try bundle("paterberg")
        let fc = RoadCorridor(bundle: flemish, vergeWidth: 13)
        XCTAssertNil(fc.edgeScenery)
        XCTAssertTrue(RoadCorridor.edgeAprons(fc, scenery: flemish.scenery).isEmpty)
    }

    /// No lane or driveway on the Poggio lies on the carriageway
    /// (`RoadBuilder.appendRivieraSideRoad`): before, 32 of them reached up
    /// to 3 m on to it (the SS1 over the left lane at route 304-315, a seam
    /// in the first frames of the ride). Every vertex, and the middle of
    /// every triangle's edge, stays within the 5 cm the lanes are laid on
    /// to the carriageway's edge (well short of the edge line), but for a
    /// handful within 0.25 m: a straight cross-section between two points
    /// off the road can cut the corner where the route's width steps
    /// (route 4266, 6.75 -> 5.5 m in a metre, Salita Poggio beside it).
    /// And the lanes still meet it (some edge within 0.1 m of it).
    func test_poggioSideRoadsStopAtTheCarriageway() throws {
        let b: CourseBundle
        do { b = try CourseBundle.load(id: "poggio") } catch { throw XCTSkip("poggio not in the test host: \(error)") }
        let corridor = RoadCorridor(bundle: b, vergeWidth: 13)
        XCTAssertTrue(corridor.art.look.isRiviera)
        let m = RoadBuilder.buildSideRoads(corridor: corridor, scenery: b.scenery, reach: 60)
        XCTAssertGreaterThan(m.triangleCount, 2000)
        func on(_ v: Int) -> SIMD2<Double> {
            SIMD2(Double(m.positions[3 * v]), -Double(m.positions[3 * v + 2]))
        }
        /// Metres the point lies inside the carriageway (negative: clear).
        func inside(_ p: SIMD2<Double>) -> Double {
            corridor.mainRoadDistance(east: p.x, north: p.y).map { $0.halfWidth - $0.dist } ?? -.infinity
        }
        var worstVertex = -Double.infinity, worstEdge = -Double.infinity, meeting = 0, onIt = 0
        var worstAt = SIMD2<Double>(0, 0)
        for v in 0..<m.vertexCount {
            let d = inside(on(v))
            if d > worstVertex { worstVertex = d; worstAt = on(v) }
            if d > -0.1 { meeting += 1 }
            if d > 0.06 { onIt += 1 }
        }
        for part in m.parts {
            for t in stride(from: 0, to: part.count, by: 3) {
                for k in 0..<3 {
                    let a = on(Int(part[t + k])), c = on(Int(part[t + (k + 1) % 3]))
                    worstEdge = max(worstEdge, inside((a + c) / 2))
                }
            }
        }
        XCTAssertLessThan(worstVertex, 0.25, "a side road's vertex on the carriageway at \(worstAt)")
        XCTAssertLessThanOrEqual(onIt, 12, "side-road vertices more than 6 cm on the carriageway")
        XCTAssertLessThan(worstEdge, 0.25, "a side road's edge across the carriageway")
        XCTAssertGreaterThan(meeting, 100, "the lanes no longer meet the road")
    }

    /// Every letter the fans write is in the font, on its 4 x 6 grid.
    func test_strokeFontCoversTheWriting() {
        for word in ["VAI", "DAI", "FORZA", "ALLEZ", "TADEJ", "POGI", "MATHIEU", "PIPPO", "GANNA", "MILAN", "SLO",
                     "BRAVI", "GO", "BUS", "W"] {
            for ch in word where ch != " " {
                XCTAssertNotNil(RoadBuilder.strokeFont[ch], "no glyph for \(ch)")
            }
        }
        for (ch, lines) in RoadBuilder.strokeFont {
            for line in lines {
                XCTAssertGreaterThanOrEqual(line.count, 2, "\(ch)")
                for p in line {
                    XCTAssertTrue((-0.5...4.5).contains(p.x) && (-0.5...6.5).contains(p.y), "\(ch) \(p)")
                }
            }
        }
    }
}
