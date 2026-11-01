import simd
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
        // From the Dender to the chapel: climbfinder 1143 m, +91 m (18.6 -> 109.5 m), 8 %, cobbles
        // from 200 m; the Ronde's 1075 m, 9.3 %, max 19.8 %.
        "muur": Published(lengthM: 1075...1150, avgPct: 7.5...9.5, max25Pct: 17.5...20.5, cobblesM: 900...1000),
        // Ronde 2025 roadmap: 463 m, 7 %, max 14.2 %, 300 m of cobbles; climbfinder 431 m, 7.7 %,
        // cobbles for 250 m. The setts end at the Caildenberg junction, 257 m up.
        "molenberg": Published(lengthM: 430...480, avgPct: 6.5...7.8, max25Pct: 12.5...14.5, cobblesM: 240...310),
        // Roadmap 530 m, 6.6 %, max 15.8 %, 500 m of cobbles; here the setts junction to junction.
        "taaienberg": Published(lengthM: 520...570, avgPct: 6.2...7.0, max25Pct: 14.5...16.5, cobblesM: 495...570),
        // RCS 2026 (Milano-Sanremo): 3.7 km, 24 -> 160 m, 136 m, 3.7 %, max 8 %; climbfinder 3.7 km, 3.8 %,
        // steepest 100 m 7.3 %. All asphalt.
        "poggio": Published(lengthM: 3650...3800, avgPct: 3.5...3.9, max25Pct: 6.5...8.5, cobblesM: 0...0),
    ]

    private func bundle(_ id: String) throws -> CourseBundle {
        do {
            return try CourseBundle.load(id: id)
        } catch {
            throw XCTSkip("\(id) data not in the test host bundle: \(error)")
        }
    }

    func test_catalogListsTheBergsInOrder() {
        XCTAssertEqual(CourseCatalog.courseIDs, ["koppenberg", "oudekwaremont", "paterberg", "muur", "molenberg", "taaienberg", "poggio"])
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
    /// The Molenberg is the lowest berg, about 32 m.
    func test_routesRunUphillWithARunIn() throws {
        for id in CourseCatalog.courseIDs {
            let b = try bundle(id)
            let r = b.route
            XCTAssertGreaterThan(r.elevation(at: b.climb.endS) - r.elevation(at: b.climb.startS), 28, id)
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
            spans += art.stoneWalls.map { ("stone wall", $0.span) } + art.unmarked.map { ("unmarked", $0) }
            spans += art.lawns.map { ("lawn", $0.span) } + art.palings.map { ("paling", $0.span) }
            for (kind, span) in spans {
                XCTAssertGreaterThanOrEqual(span.lowerBound, 0, "\(id) \(kind) \(span)")
                XCTAssertLessThanOrEqual(span.upperBound, length, "\(id) \(kind) \(span)")
                XCTAssertLessThan(span.lowerBound, span.upperBound, "\(id) \(kind) \(span)")
            }
            for side in art.kerbs.map(\.side) + art.gutters.map(\.side) + art.lamps.map(\.side) + art.walls.map(\.side)
                + art.fences.map(\.side) + art.rails.map(\.side) + art.poles.map(\.side) + art.stoneWalls.map(\.side)
                + art.lawns.map(\.side) {
                XCTAssertEqual(abs(side), 1, "\(id): side must be -1 or +1")
            }
            for wall in art.stoneWalls { XCTAssert((0.2...2.5).contains(wall.height), "\(id): stone wall \(wall.span) \(wall.height) m") }
            for wall in art.walls {
                XCTAssert((0.3...2.5).contains(wall.height), "\(id): wall \(wall.span) \(wall.height) m")
                XCTAssert((0...3).contains(wall.offset), "\(id): wall \(wall.span) \(wall.offset) m off")
            }
            for g in art.gutters { XCTAssert((0.4...0.8).contains(g.width), "\(id): gutter \(g.span) \(g.width) m") }
            for p in art.palings {
                XCTAssertEqual(abs(p.side), 1, id)
                XCTAssert((0.8...1.8).contains(p.height), "\(id): paling \(p.span)")
            }
            for run in art.lamps { XCTAssertGreaterThan(run.spacing, 5, id) }
            for run in art.poles { XCTAssertGreaterThan(run.spacing, 15, id) }

            // Village paving, grates and pollards.
            var paved = art.pavedVerges.map { ("paved verge", $0.span) } + art.streetGrates.map { ("grates", $0.span) }
            paved += art.pollards.map { ("pollards", $0.span) }
            for (kind, span) in paved {
                XCTAssertGreaterThanOrEqual(span.lowerBound, 0, "\(id) \(kind) \(span)")
                XCTAssertLessThanOrEqual(span.upperBound, length, "\(id) \(kind) \(span)")
                XCTAssertLessThan(span.lowerBound, span.upperBound, "\(id) \(kind) \(span)")
            }
            for side in art.pavedVerges.map(\.side) + art.pollards.map(\.side) {
                XCTAssertEqual(abs(side), 1, "\(id): side must be -1 or +1")
            }
            for v in art.pavedVerges { XCTAssert((0.3...6).contains(v.width), "\(id): paved verge \(v.span) \(v.width) m") }
            // A side's paved spans may touch (one strip) but never overlap:
            // two strips on one spot would fight.
            for side in [-1.0, 1.0] {
                let spans = art.pavedVerges.filter { $0.side == side }.map(\.span).sorted { $0.lowerBound < $1.lowerBound }
                for (earlier, later) in zip(spans, spans.dropFirst()) {
                    XCTAssertLessThanOrEqual(earlier.upperBound, later.lowerBound, "\(id): paved verges \(earlier) and \(later) overlap")
                }
            }
            for g in art.streetGrates {
                XCTAssertGreaterThan(g.spacing, 5, id)
                XCTAssertLessThan(abs(g.lateral), b.route.width(at: g.span.lowerBound) / 2 - 0.3, "\(id): grates off the road")
            }
            if art.gutterGrateSpacing > 0 { XCTAssertFalse(art.gutters.isEmpty, "\(id): grates without a gutter") }

            // Signs, furniture and extra trees: on the route, on a side, every
            // plate in the atlas. A pole stands clear of the broadcast
            // camera's moto, which keeps within about 2.35 m of the centre
            // line (`CameraRig`: the rider's 0.4 m plus a 1.95 m swing).
            // The Riviera's plates are on its own atlas (cj_signs_it).
            let cells = BuildingBuilder.signCells(for: art.look)
            XCTAssertFalse(cells.isEmpty, "\(id): \(art.look.signAtlas)_map.json not in the bundle")
            for post in art.signs {
                XCTAssert((0...length).contains(post.s), "\(id): sign at \(post.s)")
                XCTAssertEqual(abs(post.side), 1, "\(id): sign at \(post.s)")
                XCTAssertFalse(post.plates.isEmpty, "\(id): sign at \(post.s)")
                for key in post.plates { XCTAssertNotNil(cells[key], "\(id): plate \(key) not in the sign atlas") }
                if post.mount == .pole {
                    XCTAssertGreaterThan(b.route.width(at: post.s) / 2 + post.offset, 2.5, "\(id): sign at \(post.s) in the camera's way")
                }
            }
            for item in art.furniture {
                XCTAssert((0...length).contains(item.s), "\(id): furniture at \(item.s)")
                XCTAssertEqual(abs(item.side), 1, "\(id): furniture at \(item.s)")
                XCTAssertGreaterThanOrEqual(item.offset, 0, "\(id): furniture at \(item.s)")
            }
            for t in art.extraTrees {
                XCTAssert((0...length).contains(t.s), "\(id): tree at \(t.s)")
                XCTAssertEqual(abs(t.side), 1, "\(id): tree at \(t.s)")
                XCTAssertGreaterThan(t.offset, t.radius * 0.5, "\(id): tree at \(t.s) crowding the road")
                // Clear of every stretch of the route, the one it turns into
                // included.
                let d = b.route.direction(at: t.s)
                let p = b.route.planar(at: t.s) + SIMD2(d.y, -d.x) * (t.side * (b.route.width(at: t.s) / 2 + t.offset))
                var nearest = Double.infinity
                var s = 0.0
                while s <= length {
                    nearest = min(nearest, simd_distance(p, b.route.planar(at: s)))
                    s += 1
                }
                XCTAssertGreaterThan(nearest, 5, "\(id): tree at \(t.s) stands on the route")
            }
        }
        // The signs' paints and grates are in the atlas too.
        for key in ["paint.blue", "paint.green", "paint.yellow", "paint.cabinet", "paint.gold", "paint.stone", "paint.marble",
                    "paint.door", "paint.glass", "paint.niche", "grate.round", "grate.rect"] {
            XCTAssertNotNil(BuildingBuilder.signCells[key], key)
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

    /// The Muur starts at the Dender bridge, rides the Brugstraat's pavers
    /// like asphalt and the setts from the Markt to the chapel, which is
    /// built whole on its footprint near the top. The LiDAR ground under the
    /// bridge is the river; the deck is carried across instead.
    func test_muurCrossesTheDenderAndEndsAtTheChapel() throws {
        let b = try bundle("muur")
        let r = b.route
        // The bridge (s ≈ 265-290) lies level with its ends, not down at the water.
        let ends = min(r.elevation(at: 256), r.elevation(at: 298))
        var s = 262.0
        while s <= 292 {
            XCTAssertGreaterThan(r.elevation(at: s), ends - 0.3, "dip at s \(s)")
            s += 1
        }
        XCTAssertEqual(r.surfaceName(at: b.climb.startS + 100), "asphalt")
        XCTAssertEqual(r.surfaceName(at: b.climb.startS + 250), "cobbles")
        XCTAssertEqual(r.surfaceName(at: b.climb.endS - 10), "cobbles")
        let corridor = RoadCorridor(bundle: b, vergeWidth: 12)
        let sites = BuildingBuilder.domedChapelSites(corridor: corridor, scenery: b.scenery)
        XCTAssertEqual(sites.count, 1)
        let site = try XCTUnwrap(sites.first)
        XCTAssertEqual(b.scenery?.buildings?[site.index].kind, "chapel")
        XCTAssertLessThan(abs(site.s - b.climb.endS), 30)
    }

    /// The Molenberg turns off the concrete Smarre onto the setts and crosses
    /// the beek by the mill on a deck carried level (the LiDAR ground there
    /// is the water) between low brick parapets; the setts end at the
    /// Caildenberg, 257 m up, and the climb on asphalt at Moldergem.
    func test_molenbergCrossesTheBeekAtTheMill() throws {
        let b = try bundle("molenberg")
        let r = b.route
        XCTAssertEqual(r.surfaceName(at: b.climb.startS - 50), "concrete")
        XCTAssertEqual(r.surfaceName(at: b.climb.startS + 20), "cobbles")
        XCTAssertEqual(r.surfaceName(at: b.climb.startS + 245), "cobbles")
        XCTAssertEqual(r.surfaceName(at: b.climb.startS + 270), "asphalt")
        XCTAssertEqual(r.surfaceName(at: b.climb.endS + 20), "concrete")
        // The deck (s ≈ 329-340) no lower than the road either side of it.
        let ends = min(r.elevation(at: 327), r.elevation(at: 342))
        var s = 329.0
        while s <= 340 {
            XCTAssertGreaterThan(r.elevation(at: s), ends - 0.2, "dip at s \(s)")
            s += 1
        }
        let art = CourseArt.make(bundle: b)
        let parapets = art.walls.filter { $0.height < 1 && $0.span.overlaps(328...341) }
        XCTAssertEqual(Set(parapets.map(\.side)), [-1, 1])
        XCTAssertTrue(art.kerbs.isEmpty && art.gutters.isEmpty, "setts to the verges, an edge row laid lengthwise")
    }

    /// The Taaienberg's cobbled carriageway: a narrow concrete strip on the
    /// left, the setts, and the concrete gutter riders take on the right,
    /// from the foot of the setts to the top; the bronze legs stand at the
    /// top on the left.
    func test_taaienbergHasItsGutterAndTheLegsAtTheTop() throws {
        let b = try bundle("taaienberg")
        let r = b.route
        XCTAssertEqual(r.surfaceName(at: b.climb.startS - 20), "concrete")
        XCTAssertEqual(r.surfaceName(at: b.climb.startS + 10), "cobbles")
        XCTAssertEqual(r.surfaceName(at: b.climb.endS + 20), "concrete")
        let art = CourseArt.make(bundle: b)
        let gutter = try XCTUnwrap(art.gutters.first)
        XCTAssertEqual(gutter.side, 1)
        XCTAssertEqual(gutter.width, 0.7, accuracy: 0.05)
        XCTAssertLessThan(abs(gutter.span.lowerBound - b.climb.startS), 3)
        XCTAssertLessThan(abs(gutter.span.upperBound - b.climb.endS), 3)
        let strip = try XCTUnwrap(art.kerbs.first)
        XCTAssertEqual(strip.side, -1)
        // About 3.25 m of setts between the strip (0.24 m drawn) and the gutter.
        var s = b.climb.startS + 5
        while s < b.climb.endS - 5 {
            let setts = r.width(at: s) - 0.24 - gutter.width
            XCTAssert((2.9...3.6).contains(setts), "setts \(setts) m wide at s \(s)")
            s += 10
        }
        let legs = try XCTUnwrap(art.furniture.first { if case .bronzeLegs = $0.kind { true } else { false } })
        XCTAssertEqual(legs.side, -1)
        XCTAssertLessThan(abs(legs.s - b.climb.endS), 20)
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
