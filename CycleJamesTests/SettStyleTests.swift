import XCTest
@testable import CycleJames

/// The procedural setts (`WorldShaders.settSurface`, `CourseArt.SettStyle`,
/// `SettFarMap`). The shader finds the course and the sett a pixel lies in
/// by looking at three boundaries each way, which is exact while no
/// boundary strays more than half a course (or half a sett) from its
/// nominal place; how far one strays grows with the distance from the
/// centre line, so the bound is checked against every cobbled surface the
/// courses really have.
final class SettStyleTests: XCTestCase {
    private let looks: [CourseArt.SettLook] = [.mixedGrey, .paleSplit, .darkRegular, .smallWorn, .mossyGrey, .warmOblong]

    private func bundle(_ id: String) throws -> CourseBundle {
        do {
            return try CourseBundle.load(id: id)
        } catch {
            throw XCTSkip("\(id) data not in the test host bundle: \(error)")
        }
    }

    func test_neighbourSearchHoldsOnEveryCobbledSurface() throws {
        typealias S = CourseArt.SettStyle
        for id in CourseCatalog.courseIDs {
            let b = try bundle(id)
            let art = CourseArt.make(bundle: b)
            let r = b.route
            // The carriageway, its raised pavements and the cobbled side
            // roads: lateral u is measured from the carriageway's centre
            // line, and each side road's own.
            var widestRoad = 0.0
            for i in 0..<r.count where r.surfaceNames.indices.contains(r.surface[i]) && r.surfaceNames[r.surface[i]] == "cobbles" {
                widestRoad = max(widestRoad, r.widthM[i] / 2)
            }
            for road in RoadBuilder.sideRoadSamples(scenery: b.scenery) where road.part == 1 {
                widestRoad = max(widestRoad, road.halfWidth)
            }
            var widestU = widestRoad
            for p in art.pavements {
                var s = p.span.lowerBound
                while s <= p.span.upperBound {
                    widestU = max(widestU, r.width(at: s) / 2 + p.width)
                    s += 1
                }
            }
            // Flush paved verges: from their strip's own middle line, which
            // keeps to the carriageway edge.
            for strip in RoadBuilder.pavedVergeStrips(art) {
                let us = [0, strip.maxWidth].map { RoadBuilder.pavedVergeU(side: strip.side, offset: $0, maxWidth: strip.maxWidth) }
                widestU = max(widestU, us.map(abs).max()!)
                // Narrower than the far map's span, so no course shows the
                // same setts twice across the strip.
                XCTAssertLessThan(Float(abs(us[1] - us[0])), SettFarMap.span, "\(id): paved strip \(strip.span) repeats its setts")
            }
            // An all-asphalt course with no sett pavements (the Poggio) has no setts to search.
            guard widestU > 0 else { continue }
            XCTAssertGreaterThan(widestU, 1, id)
            // Each course's setts repeat across the road every span: never
            // twice across one road (a pavement beyond it shows stones its
            // own course has across the road, where it has none).
            XCTAssertLessThan(Float(widestRoad), SettFarMap.span / 2, "\(id): a road wider than a course's setts")
            let st = art.setts.style
            let d = st.layout.x, l = st.layout.y
            let u = Float(widestU)
            let course = d * st.layout.z / 2 + S.courseTurn * u + S.courseWave
            XCTAssertLessThan(course, d / 2, "\(id): courses tear beyond |u| = \(widestU) m")
            let lk = l * S.shortestBatch
            let sett = lk * st.layout.w / 2 + S.settSkew * (d / 2 + course)
            XCTAssertLessThan(sett, lk / 2, "\(id): setts tear beyond |u| = \(widestU) m")
            // Rounding a course to whole setts in the span stays within the
            // shortest batch.
            for look in looks {
                let l0 = look.style.layout.y
                let shortest = SettFarMap.span / (SettFarMap.span / (l0 * 0.88)).rounded()
                XCTAssertGreaterThanOrEqual(shortest, l0 * S.shortestBatch, "\(look)")
            }
        }
    }

    /// No two areas of the pavements' setts (the raised pavements and the
    /// flush paved strips, either side) share a course of the far map at one
    /// place across its span, which would lay the same stones in both; nor
    /// does the carriageway (whose courses key the same joints and colours)
    /// within 100 m of one, where it still draws its setts one by one.
    func test_pavedAreasNeverShareStones() throws {
        typealias Span = CourseArt.Span
        let n = SettFarMap.courses
        let span = Double(SettFarMap.span), cellW = 0.1
        let across = Int((span / cellW).rounded())
        for id in CourseCatalog.courseIDs {
            let b = try bundle(id)
            let art = CourseArt.make(bundle: b)
            let r = b.route
            let depth = art.setts.style.layout.x, d = Double(depth)
            let first = SettFarMap.firstCourse(r, depth: depth)
            /// The (course of the far map, place across its span) cells an
            /// area lays at `s`, a course either side for the course edges'
            /// stray (`settSurface`'s sw and course key).
            func cells(at s: Double, surface: Int, v: Double, u: ClosedRange<Double>) -> [Int] {
                let sw = v + 0.9 * sin(v * 0.071 + 1.3) + 0.45 * sin(v * 0.213 + 0.4)
                let k = Int((sw / d).rounded(.down)) + Int(WorldMaterials.settCourseOffsets[surface]) - first
                var places = Set<Int>()
                for x in Array(stride(from: u.lowerBound, to: u.upperBound, by: cellW)) + [u.upperBound] {
                    places.insert(Int((x - span * (x / span).rounded(.down)) / cellW) % across)
                }
                return (-1...1).flatMap { dk in places.map { (((k + dk) % n + n) % n) * across + $0 } }
            }
            // Each area: its span, and its v and u at s.
            var areas: [(name: String, span: Span, v: (Double) -> Double, u: (Double) -> ClosedRange<Double>)] = []
            for side in [-1.0, 1.0] {
                var merged: [(span: Span, width: Double)] = []
                for p in art.pavements.filter({ $0.side == side }).sorted(by: { $0.span.lowerBound < $1.span.lowerBound }) {
                    if let last = merged.last, p.span.lowerBound <= last.span.upperBound + 0.01 {
                        merged[merged.count - 1] = (last.span.lowerBound...max(last.span.upperBound, p.span.upperBound),
                                                    max(last.width, p.width))
                    } else {
                        merged.append((p.span, p.width))
                    }
                }
                for p in merged {
                    areas.append(("pavement \(side) \(p.span)", p.span, { $0 }, { s in
                        let hw = r.width(at: s) / 2
                        return side > 0 ? hw...(hw + p.width) : -(hw + p.width)...(-hw)
                    }))
                }
            }
            for strip in RoadBuilder.pavedVergeStrips(art) {
                let side = strip.side
                areas.append(("paved strip \(side) \(strip.span)", strip.span,
                              { RoadBuilder.pavedVergeV(side: side, s: $0, depth: depth) }, { s in
                    let w = art.pavedVerges.filter { $0.side == side && $0.span.contains(s) }.map(\.width).max() ?? 0
                    let us = [0, w].map { RoadBuilder.pavedVergeU(side: side, offset: $0, maxWidth: strip.maxWidth) }
                    return us.min()!...us.max()!
                }))
            }
            // Each area's cells, and where along the road it lays them.
            var laid: [[Int: Double]] = []
            for a in areas {
                var at: [Int: Double] = [:]
                var s = a.span.lowerBound
                while s <= a.span.upperBound {
                    for c in cells(at: s, surface: 2, v: a.v(s), u: a.u(s)) where at[c] == nil { at[c] = s }
                    s += d * 0.9
                }
                laid.append(at)
            }
            for i in areas.indices {
                for j in areas.indices where j > i {
                    XCTAssertTrue(Set(laid[i].keys).isDisjoint(with: laid[j].keys), "\(id): \(areas[i].name) and \(areas[j].name) share setts")
                }
                // The carriageway's cobbles within 100 m of where the area
                // lays the same cell.
                var s = max(areas[i].span.lowerBound - 100, 0), near = Double.infinity
                while s <= min(areas[i].span.upperBound + 100, r.length) {
                    if r.surfaceName(at: s) == "cobbles" {
                        let hw = r.width(at: s) / 2
                        for c in cells(at: s, surface: 0, v: s, u: -hw...hw) {
                            if let sa = laid[i][c] { near = min(near, abs(sa - s)) }
                        }
                    }
                    s += d * 0.9
                }
                XCTAssertGreaterThan(near, 100, "\(id): \(areas[i].name) shares setts with the carriageway \(near) m off")
            }
            // Every cobbled berg but the Paterberg has sett pavements; the Poggio has no setts at all.
            let cobbled = stride(from: 0.0, through: r.length, by: 1).contains { r.surfaceName(at: $0) == "cobbles" }
            if id != "paterberg" && cobbled { XCTAssertFalse(areas.isEmpty, id) }
        }
    }

    func test_jointsAndSharesAreSane() {
        for look in looks {
            let st = look.style
            XCTAssertLessThan(st.joint.x, st.joint.y, "\(look)")
            XCTAssertLessThan(2 * st.joint.y, min(st.layout.x, st.layout.y) / 4, "\(look): joints wider than a quarter sett")
            // A split stone's widest gap and largest chip leave most of it.
            XCTAssertLessThan(2 * (st.joint.y + st.split.x), min(st.layout.x, st.layout.y) / 2, "\(look): gaps wider than half a sett")
            XCTAssertLessThan(st.split.y, min(st.layout.x, st.layout.y) / 3, "\(look): chips over a third of a sett")
            XCTAssertLessThan(st.stoneB.w + st.stoneC.w, 1, "\(look)")
            XCTAssertLessThan(st.jointShare, 0.3, "\(look): far mean mostly joint")
            let m = st.mean
            XCTAssert((0.3...0.7).contains(m.x), "\(look): share of the joints across the road \(m.x)")
            XCTAssert((0.7...1).contains(m.z), "\(look): farMatch \(m.z)")
            XCTAssert((0.8...1.2).contains(m.w), "\(look): farAO \(m.w)")
            XCTAssert((0...0.3).contains(st.joint.w), "\(look): far sun-shadow share \(st.joint.w)")
            // The far mean's sun shadows never cover more than a joint.
            XCTAssertLessThanOrEqual(st.joint.w / st.jointShare, 1, "\(look)")
            // A relaid band in at most every 250 m section.
            XCTAssertLessThanOrEqual(st.wear.w * 16, 1, "\(look)")
        }
    }

    func test_eachClimbHasItsLook() {
        let kopp = CourseArt.SettLook.mixedGrey.style
        let kwar = CourseArt.SettLook.paleSplit.style
        let pat = CourseArt.SettLook.darkRegular.style
        let muur = CourseArt.SettLook.smallWorn.style
        // The Muur's setts the smallest ("kleiner" than the other bergs'),
        // close, unsplit, with the most polished wheel tracks.
        for st in [kopp, kwar, pat] {
            XCTAssertLessThan(muur.layout.x, st.layout.x)
            XCTAssertLessThan(muur.layout.y, st.layout.y)
            XCTAssertGreaterThan(muur.wear.z, st.wear.z)
        }
        XCTAssertLessThanOrEqual(muur.joint.y, pat.joint.y)
        XCTAssertEqual(muur.split, SIMD4(0, 0, 0.016, 0.48))
        // Photos: the Koppenberg's stones near square (not bricks along the
        // road), its damage light for a climb kept up for the race.
        XCTAssertEqual(kopp.layout.x / kopp.layout.y, 1, accuracy: 0.15)
        XCTAssertLessThanOrEqual(kopp.wear.w, 0.025)
        // The Paterberg's joints tighter than the Koppenberg's, and the
        // Kwaremont's no wider on average (the survey: up to about 28 mm on
        // the Koppenberg, 3-15 mm on sand elsewhere; wide sandy joints all
        // round ring every stone like grout on new pavers): most close, a
        // few gaping where a split stone falls short. The Kwaremont's split
        // tops rougher, its stones less regular and chipped; the
        // Koppenberg's domes the strongest; only the Kwaremont's stones split.
        XCTAssertLessThan(pat.joint.y, kopp.joint.y)
        XCTAssertLessThanOrEqual(kwar.joint.x, kopp.joint.x)
        XCTAssertLessThanOrEqual(kwar.joint.y, kopp.joint.y)
        XCTAssertLessThanOrEqual(kwar.meanJoint, kopp.meanJoint)
        XCTAssertGreaterThan(kwar.split.x, 0)
        XCTAssertGreaterThan(kwar.split.y, 0)
        XCTAssertGreaterThan(kwar.layout.w, max(kopp.layout.w, pat.layout.w))
        XCTAssertGreaterThan(kwar.grainNormal, 1)
        XCTAssertGreaterThan(kopp.shape.y, max(kwar.shape.y, pat.shape.y, muur.shape.y))
        for st in [kopp, pat] {
            XCTAssertEqual(st.split, SIMD4(0, 0, 0.016, 0.48))
        }
        // Warm-neutral stones, never blue: red at least blue in every family.
        for st in [kopp, kwar, pat, muur] {
            for c in [st.stoneA, st.stoneB, st.stoneC] {
                XCTAssertGreaterThanOrEqual(c.x, c.z * 0.95)
            }
        }
        // The Molenberg's near square, on joints as wide as the Koppenberg's;
        // the Taaienberg's longer across the road than along it, warm, domed.
        let mol = CourseArt.SettLook.mossyGrey.style, taai = CourseArt.SettLook.warmOblong.style
        XCTAssertEqual(mol.layout.x / mol.layout.y, 1, accuracy: 0.1)
        XCTAssertGreaterThan(taai.layout.y, taai.layout.x * 1.15)
        for st in [mol, taai] {
            XCTAssertGreaterThan(st.meanJoint, pat.meanJoint)
            for c in [st.stoneA, st.stoneB, st.stoneC] { XCTAssertGreaterThanOrEqual(c.x, c.z * 0.95) }
            XCTAssertEqual(st.split, SIMD4(0, 0, 0.016, 0.48))
        }
        XCTAssertGreaterThan(taai.shape.y, mol.shape.y)
        XCTAssertGreaterThan(taai.stoneC.w, mol.stoneC.w)
        let ids = Set(looks.map(\.seed))
        XCTAssertEqual(ids.count, looks.count)
    }

    func test_tiersFadeInOrder() {
        typealias S = CourseArt.SettStyle
        let high = S.lod(.high), balanced = S.lod(.balanced), battery = S.lod(.battery)
        XCTAssertLessThan(battery.y, balanced.y)
        XCTAssertLessThan(balanced.y, high.y)
        XCTAssertLessThan(balanced.x, balanced.y)
        // Balanced keeps the conservative fade until it is measured on an
        // iPhone 14.
        XCTAssertLessThanOrEqual(balanced.y, 0.55)
        XCTAssertEqual(S.microShadow(.battery), 0)
        XCTAssertGreaterThan(S.microShadow(.balanced), 0)
    }

    func test_farMapHoldsTheStonesAndJoints() {
        typealias F = SettFarMap
        for look in looks {
            let st = look.style
            let start = Date()
            let px = F.pixels(style: st, seed: look.seed)
            print("SettFarMap \(look): \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
            XCTAssertEqual(px.count, F.width * F.rows * 4)
            XCTAssertEqual(F.rows, F.courses * F.rowsPerCourse)
            if look == .mixedGrey {
                XCTAssertEqual(px, F.pixels(style: st, seed: look.seed), "\(look): not deterministic")
            }
            // Over the road (|u| < 2.5 m): the joints' share and the stones'
            // mean colour match the style's; the rows on the joints between
            // courses (even) hold those joints, so the far road keeps a line
            // at every course.
            let x0 = F.width / 2 - Int(2.5 / F.span * Float(F.width))
            let x1 = F.width - x0
            var joint = [0.0, 0.0], red = 0.0, n = [0.0, 0.0]
            for r in stride(from: 0, to: F.rows, by: 3) {
                for x in x0..<x1 {
                    let o = (r * F.width + x) * 4
                    joint[r % 2] += Double(px[o + 3]) / 255
                    red += Double(px[o]) / 255 / Double(F.colourScale)
                    n[r % 2] += 1
                }
            }
            let jEven = joint[0] / n[0], jOdd = joint[1] / n[1]
            let jMean = (joint[0] + joint[1]) / (n[0] + n[1])
            red /= n[0] + n[1]
            XCTAssertEqual(Float(jMean), st.jointShare - st.cornerShare, accuracy: 0.03, "\(look): joint share \(jMean)")
            XCTAssertGreaterThan(Float(jEven - jOdd), st.courseJointShare, "\(look): no course line (\(jEven) vs \(jOdd))")
            let pA = 1 - st.stoneB.w - st.stoneC.w
            let meanRed = st.stoneA.x * pA + st.stoneB.x * st.stoneB.w + st.stoneC.x * st.stoneC.w
            // The shoulders' darkening: a few per cent.
            let shade = Float(red / (1 - jMean)) / meanRed
            XCTAssert((0.88...0.99).contains(shade), "\(look): stone red x \(shade) of the palette's")
            // Every course of the map is its own: the middle rows of
            // courses a few apart and far apart differ.
            let row = F.width * 4
            func mid(_ c: Int) -> ArraySlice<UInt8> { px[((2 * c + 1) * row)..<((2 * c + 2) * row)] }
            for (a, b) in [(0, 1), (10, 11), (5, 2053), (100, 4000), (4095, 0)] {
                XCTAssertNotEqual(mid(a), mid(b), "\(look): courses \(a) and \(b) alike")
            }
        }
    }

    /// The carriageway's course 0 of the far map is a few metres before the
    /// route's first setts, so on the Koppenberg and the Paterberg, whose
    /// cobbles are shorter than the map, no course's layout and colour come
    /// back; the Kwaremont's (1.5 km) come back after 4096 courses (614 m)
    /// with other crowns, grain, damage and course edges.
    func test_shortClimbsNeverRepeatACourse() throws {
        for id in CourseCatalog.courseIDs {
            let b = try bundle(id)
            let r = b.route
            guard let ci = r.surfaceNames.firstIndex(of: "cobbles"), let last = r.surface.lastIndex(of: ci) else { continue }
            let d = CourseArt.make(bundle: b).setts.style.layout.x
            let first = SettFarMap.firstCourse(r, depth: d)
            // sw drifts up to 1.35 m either side of s.
            let courses = Int(((r.s[last] + 1.4) / Double(d)).rounded(.up)) - first
            XCTAssertGreaterThan(courses, 1000, id)
            if id == "koppenberg" || id == "paterberg" {
                XCTAssertLessThan(courses, SettFarMap.courses, "\(id): \(courses) courses of setts")
            }
        }
    }
}
