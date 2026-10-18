import XCTest
@testable import CycleJames

/// Every shipped course: its baked data loads and is self-consistent, its
/// climb matches the published figures, and its hand-placed roadside
/// details lie on its route.
final class CourseCatalogTests: XCTestCase {
    /// Published figures with the tolerance the LiDAR profile is held to.
    /// Roadbooks round to 10 m and 0.1 %, and quote a maximum from a short
    /// window of an unsmoothed profile, so the maximum here is the 25 m one
    /// the app shows, a little below the roadbook's.
    private struct Published {
        let lengthM: ClosedRange<Double>
        let avgPct: ClosedRange<Double>
        let max25Pct: ClosedRange<Double>
        let cobblesM: ClosedRange<Double>
    }

    private let published: [String: Published] = [
        // Ronde 2025 roadmap: 600 m, 11.6 %, max 22 %; climbfinder 570 m, 11.4 %.
        "koppenberg": Published(lengthM: 540...620, avgPct: 10.5...12, max25Pct: 19...22.5, cobblesM: 550...650),
        // Roadbook 2200 m, 4 %, max 11.6 %, 1500 m of cobbles.
        "oudekwaremont": Published(lengthM: 2150...2250, avgPct: 3.7...4.4, max25Pct: 9.5...12, cobblesM: 1450...1550),
        // Roadbook 360 m, 12.9 %, max 20.3 %, 360 m of cobbles.
        "paterberg": Published(lengthM: 345...380, avgPct: 12...13.5, max25Pct: 17.5...21, cobblesM: 345...380),
    ]

    private func bundle(_ id: String) throws -> CourseBundle {
        do {
            return try CourseBundle.load(id: id)
        } catch {
            throw XCTSkip("\(id) data not in the test host bundle: \(error)")
        }
    }

    func test_catalogListsTheThreeBergsInOrder() {
        XCTAssertEqual(CourseCatalog.courseIDs, ["koppenberg", "oudekwaremont", "paterberg"])
        XCTAssertEqual(CourseCatalog.all.map(\.id), CourseCatalog.courseIDs)
    }

    func test_everyCourseLoadsWithConsistentData() throws {
        for id in CourseCatalog.courseIDs {
            let b = try bundle(id)
            let c = b.course
            XCTAssertEqual(c.id, id)
            XCTAssertFalse(c.attribution.isEmpty, id)
            XCTAssertLessThan(c.climb.startS, c.climb.endS, id)
            XCTAssertGreaterThanOrEqual(c.climb.startS, 0, id)
            XCTAssertLessThanOrEqual(c.climb.endS, b.route.length, id)
            XCTAssertEqual(c.stats.totalLengthM, b.route.length, accuracy: 1e-6, id)
            for name in c.surfaces {
                XCTAssertNotNil(c.surfaceCrr[name], "\(id): no Crr for \(name)")
            }
            // The near terrain covers the route, and the road sits on it.
            var s = 0.0
            while s <= b.route.length {
                let p = b.route.planar(at: s)
                let h = b.terrainNear.sample(east: p.x, north: p.y)
                XCTAssertFalse(h.isNaN, "\(id): no terrain at s \(s)")
                XCTAssertEqual(Double(h), b.route.elevation(at: s), accuracy: 1.0, "\(id): road off the terrain at s \(s)")
                s += 10
            }
            XCTAssertNotNil(b.terrainFar, id)
            XCTAssertNotNil(b.scenery, id)
            XCTAssertGreaterThan(b.scenery?.buildings?.count ?? 0, 0, id)
            // The baked ground maps ship with the course.
            for name in ["\(id)_ortho_ground.jpg", "\(id)_splat.rgbz"] {
                let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
                let url = Bundle.main.url(forResource: base, withExtension: ext)
                    ?? Bundle.main.url(forResource: base, withExtension: ext, subdirectory: "CourseTextures")
                XCTAssertNotNil(url, "\(id): \(name) missing")
            }
        }
    }

    func test_climbsMatchPublishedFigures() throws {
        for id in CourseCatalog.courseIDs {
            guard let expected = published[id] else { return XCTFail("no published figures for \(id)") }
            let summary = try XCTUnwrap(CourseCatalog.summary(id: id), id)
            XCTAssertTrue(expected.lengthM.contains(summary.climbLengthM), "\(id) length \(summary.climbLengthM)")
            XCTAssertTrue(expected.avgPct.contains(summary.climbAvgGradePct), "\(id) avg \(summary.climbAvgGradePct)")
            XCTAssertTrue(expected.max25Pct.contains(summary.climbMaxGradePct), "\(id) max \(summary.climbMaxGradePct)")
            // Cobbles on the timed climb only.
            let cobbles = summary.surfaceSections.filter { $0.surface == "cobbles" }.reduce(0.0) { sum, sec in
                sum + max(0, min(sec.toS, summary.climbEndS) - max(sec.fromS, summary.climbStartS))
            }
            XCTAssertTrue(expected.cobblesM.contains(cobbles), "\(id) cobbles \(cobbles)")
            // Gain agrees with length × average grade.
            XCTAssertEqual(summary.climbGainM, summary.climbLengthM * summary.climbAvgGradePct / 100, accuracy: 0.5, id)
        }
    }

    /// The race direction is uphill and the route starts before the climb.
    func test_routesRunUphillWithARunIn() throws {
        for id in CourseCatalog.courseIDs {
            let b = try bundle(id)
            let r = b.route
            XCTAssertGreaterThan(r.elevation(at: b.climb.endS) - r.elevation(at: b.climb.startS), 40, id)
            XCTAssertGreaterThanOrEqual(b.climb.startS, 250, "\(id): too short a run-in")
            XCTAssertGreaterThanOrEqual(r.length - b.climb.endS, 150, "\(id): too short a run-out")
        }
    }

    func test_handPlacedDetailsLieOnTheRoute() throws {
        for id in CourseCatalog.courseIDs {
            let b = try bundle(id)
            let art = CourseArt.make(bundle: b)
            let length = b.route.length
            var spans: [(String, ClosedRange<Double>)] = art.sunkenLane.map { ("sunken", $0) } + art.villages.map { ("village", $0) }
            spans += art.kerbs.map { ("kerb", $0.span) } + art.gutters.map { ("gutter", $0.span) }
            spans += art.lamps.map { ("lamps", $0.span) } + art.walls.map { ("wall", $0.span) }
            spans += art.fences.map { ("fence", $0.span) } + art.rails.map { ("rails", $0.span) }
            spans += art.poles.map { ("poles", $0.span) } + art.houseLooks.map { ("houses", $0.span) }
            for (kind, span) in spans {
                XCTAssertGreaterThanOrEqual(span.lowerBound, 0, "\(id) \(kind) \(span)")
                XCTAssertLessThanOrEqual(span.upperBound, length, "\(id) \(kind) \(span)")
                XCTAssertLessThan(span.lowerBound, span.upperBound, "\(id) \(kind) \(span)")
            }
            for side in art.kerbs.map(\.side) + art.gutters.map(\.side) + art.lamps.map(\.side) + art.walls.map(\.side)
                + art.fences.map(\.side) + art.rails.map(\.side) + art.poles.map(\.side) {
                XCTAssertEqual(abs(side), 1, "\(id): side must be -1 or +1")
            }
            for run in art.lamps { XCTAssertGreaterThan(run.spacing, 5, id) }
            for run in art.poles { XCTAssertGreaterThan(run.spacing, 15, id) }
        }
        // The Paterberg's concrete gutter runs the whole climb on the left.
        let pat = try bundle("paterberg")
        let gutter = try XCTUnwrap(CourseArt.make(bundle: pat).gutters.first)
        XCTAssertEqual(gutter.side, -1)
        XCTAssertLessThan(abs(gutter.span.lowerBound - pat.climb.startS), 3)
        XCTAssertLessThan(abs(gutter.span.upperBound - pat.climb.endS), 3)
    }

    /// Every hand-placed house look is used by at least one building, found
    /// the way `BuildingBuilder` finds them (a look written for a building
    /// it misses would silently leave that building in the default style).
    func test_everyHouseLookMatchesABuilding() throws {
        for id in CourseCatalog.courseIDs {
            let b = try bundle(id)
            let corridor = RoadCorridor(bundle: b, vergeWidth: 12)
            var used = Set<Int>()
            for building in b.scenery?.buildings ?? [] {
                var ring = building.ring.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }
                ring = BuildingBuilder.cleaned(ring)
                guard ring.count >= 3, let place = BuildingBuilder.lookPlace(ring, corridor: corridor) else { continue }
                if let k = corridor.art.houseLookIndex(s: place.s, routeDistance: place.dist, side: place.side,
                                                       kind: building.kind) {
                    used.insert(k)
                }
            }
            for (k, look) in corridor.art.houseLooks.enumerated() {
                XCTAssertTrue(used.contains(k), "\(id): house look \(k) (\(look.span), \(look.look)) matches no building")
            }
        }
    }

    /// The Paterberg leaves the top on the concrete Stooktestraat.
    func test_paterbergExitIsConcrete() throws {
        let b = try bundle("paterberg")
        XCTAssertEqual(b.course.surfaces, ["asphalt", "cobbles", "concrete"])
        XCTAssertEqual(b.route.surfaceName(at: b.climb.endS + 50), "concrete")
        XCTAssertEqual(b.route.surfaceName(at: b.climb.startS + 50), "cobbles")
        XCTAssertEqual(b.route.surfaceName(at: b.climb.startS - 50), "asphalt")
    }
}
