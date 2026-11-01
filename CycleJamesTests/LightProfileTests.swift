import XCTest
import SceneKit
@testable import CycleJames

/// The lane exposure (`LightProfile`, `LaneExposure`): read from each
/// course's light raster, it opens up the Koppenberg's holle weg, leaves the
/// open fields alone, hardly opens up on sunlit roads beside trees, and
/// never pumps or moves faster than its limits on a ride through any
/// course. The rider's sky light (`RiderMaterials`,
/// `RiderRig.setSkyVisibility`) reaches every material it draws with:
/// SceneKit reads an unset float as 0, which would black out the ambient.
final class LightProfileTests: XCTestCase {
    private func profile(_ id: String) throws -> (bundle: CourseBundle, light: LightProfile) {
        let b: CourseBundle
        do {
            b = try CourseBundle.load(id: id)
        } catch {
            throw XCTSkip("\(id) data not in the test host bundle: \(error)")
        }
        let light = LightProfile.make(bundle: b, pixels: WorldTextures.rawPixels("\(id)_light"))
        guard !light.sky.isEmpty else { throw XCTSkip("\(id)_light.rgbz not in the test host bundle") }
        return (b, light)
    }

    /// The exposure, frame by frame, riding the whole course at `kph`
    /// (60 fps): (s, ev) per frame. With `route`, no faster up a ramp than
    /// a strong rider climbs it (6 W/kg against gravity alone, so a little
    /// fast): nobody holds 35 km/h up the Molenberg's 10 %.
    private func ride(_ light: LightProfile, length: Double, kph: Double,
                      route: CourseRoute? = nil) -> [(s: Double, ev: Float)] {
        let exposure = LaneExposure()
        let dt = 1.0 / 60
        var out: [(s: Double, ev: Float)] = []
        var s = 0.0
        exposure.reset(s: s, profile: light) { _ in }
        while s < length {
            let grade = (route?.grade(at: s) ?? 0) / 100
            s += min(kph / 3.6, 6 / (9.81 * max(grade, 1e-3))) * dt
            exposure.update(s: s, dt: dt, profile: light) { _ in }
            out.append((s, exposure.ev))
        }
        return out
    }

    /// The largest pair of opposite swings (up then down, or down then up)
    /// completed within `window` seconds: what reads as pumping.
    private func worstPump(_ ev: [Float], dt: Double, window: Double) -> Float {
        // Turning points, ignoring wiggles under 0.02 EV.
        var turns: [(i: Int, e: Float)] = [(0, ev[0])]
        var dir = 0
        for (i, e) in ev.enumerated() {
            let last = turns[turns.count - 1].e
            if (dir == 1 && e > last) || (dir == -1 && e < last) {
                turns[turns.count - 1] = (i, e)
            } else if dir != -1, e < last - 0.02 {
                turns.append((i, e)); dir = -1
            } else if dir != 1, e > last + 0.02 {
                turns.append((i, e)); dir = 1
            }
        }
        var worst: Float = 0
        for k in 0..<max(turns.count - 2, 0) where Double(turns[k + 2].i - turns[k].i) * dt <= window {
            worst = max(worst, min(abs(turns[k + 1].e - turns[k].e), abs(turns[k + 2].e - turns[k + 1].e)))
        }
        return worst
    }

    func test_eachCourseHasAProfileAlongTheWholeRoute() throws {
        for id in CourseCatalog.courseIDs {
            let (b, light) = try profile(id)
            XCTAssertEqual(Double(light.sky.count), (b.route.length / LightProfile.stepM).rounded(.down) + 1, accuracy: 1, id)
            XCTAssertEqual(light.sun.count, light.sky.count, id)
            XCTAssertTrue(light.sky.allSatisfy { $0 >= 0 && $0 <= 1 }, id)
            XCTAssertTrue(light.sun.allSatisfy { $0 >= 0 && $0 <= 1 }, id)
        }
        // The sun is the raster's G, not another copy of its R: past the
        // holle weg the road is in sun beside trees that hide half the sky.
        let kopp = try profile("koppenberg").light
        func mean(_ a: [Float], _ s0: Int, _ s1: Int) -> Float { a[s0..<s1].reduce(0, +) / Float(s1 - s0) }
        XCTAssertGreaterThan(mean(kopp.sun, 620, 640), mean(kopp.sky, 620, 640) + 0.3)
    }

    /// At 20 km/h the exposure never moves faster than 0.5 EV a second (the
    /// hard limit) and, the profile being smooth, not faster than 0.25 (the
    /// limit hardly ever has to act); nor does it swing up and back down
    /// (or down and up) by more than 0.1 EV within 8 s, at any speed a
    /// rider can hold there (35 km/h through a short shade on the
    /// Molenberg's 10 % ramp would swing it 0.11 EV).
    func test_noPumpingAndWithinTheRateLimitsOnEveryCourse() throws {
        for id in CourseCatalog.courseIDs {
            let (b, light) = try profile(id)
            for kph in [8.0, 20.0, 35.0] {
                let trace = ride(light, length: b.route.length, kph: kph, route: b.route)
                var fastest: Float = 0, highest: Float = 0
                for k in 1..<trace.count {
                    fastest = max(fastest, abs(trace[k].ev - trace[k - 1].ev) * 60)
                    highest = max(highest, trace[k].ev)
                }
                XCTAssertLessThanOrEqual(fastest, LaneExposure.maxRate + 1e-4, "\(id) at \(kph) km/h")
                XCTAssertLessThanOrEqual(highest, LaneExposure.maxEV + 1e-6, "\(id) at \(kph) km/h")
                if kph == 20 {
                    XCTAssertLessThanOrEqual(fastest, 0.25, "\(id): the exposure changes \(fastest) EV/s at 20 km/h")
                }
                let pump = worstPump(trace.map(\.ev), dt: 1.0 / 60, window: 8)
                XCTAssertLessThanOrEqual(pump, 0.1, "\(id) at \(kph) km/h: swings of \(pump) EV within 8 s")
            }
        }
    }

    /// The holle weg's shaded heart opens up fully; the open fields above
    /// it, and the Paterberg's open climb, stay at the calibrated exposure.
    func test_theLaneOpensUpAndTheOpenFieldsDont() throws {
        let kopp = try profile("koppenberg")
        let trace = ride(kopp.light, length: kopp.bundle.route.length, kph: 20)
        func ev(_ s0: Double, _ s1: Double) -> (lo: Float, hi: Float) {
            let seg = trace.filter { $0.s >= s0 && $0.s < s1 }.map(\.ev)
            return (seg.min() ?? .nan, seg.max() ?? .nan)
        }
        XCTAssertGreaterThan(ev(575, 600).lo, 0.7, "Koppenberg holle weg")
        for s in stride(from: 570.0, through: 595, by: 5) {
            XCTAssertEqual(LaneExposure.target(at: s, profile: kopp.light), LaneExposure.maxEV, accuracy: 0.02,
                           "Koppenberg holle weg at \(s)")
        }
        XCTAssertEqual(ev(870, 1020).hi, 0, "Koppenberg fields")
        XCTAssertEqual(LaneExposure.target(at: 590, profile: kopp.light), LaneExposure.maxEV)

        let pat = try profile("paterberg")
        let patTrace = ride(pat.light, length: pat.bundle.route.length, kph: 20)
        for (s0, s1) in [(0.0, 220.0), (420.0, 470.0), (560.0, 620.0)] {
            let hi = patTrace.filter { $0.s >= s0 && $0.s < s1 }.map(\.ev).max() ?? .nan
            XCTAssertLessThan(hi, 0.02, "Paterberg fields \(s0)-\(s1)")
        }
        XCTAssertEqual(LaneExposure.target(at: 450, profile: pat.light), 0, "pat 450")
    }

    /// A sunlit road beside a few trees or a house sees little sky but
    /// plenty of sun (`LightProfile.sunShare`): the camera opens up there
    /// by well under the lane's 0.75 EV, where the sky alone opened it up
    /// 0.6-0.7 EV.
    func test_sunlitRoadsBesideTreesHardlyOpenUp() throws {
        for (id, s0, s1, spot) in [("koppenberg", 625.0, 680.0, 650.0), ("paterberg", 260.0, 290.0, 280.0)] {
            let (b, light) = try profile(id)
            let skyOnly = LightProfile(sky: light.sky, sun: light.sky)
            var settled: Float = 0, settledSkyOnly: Float = 0
            for s in stride(from: s0, through: s1, by: 1) {
                settled = max(settled, LaneExposure.target(at: s, profile: light))
                settledSkyOnly = max(settledSkyOnly, LaneExposure.target(at: s, profile: skyOnly))
            }
            XCTAssertLessThan(settled, 0.5, "\(id) \(s0)-\(s1)")
            XCTAssertGreaterThan(settledSkyOnly, 0.6, "\(id) \(s0)-\(s1): the sky alone")
            XCTAssertLessThan(LaneExposure.target(at: spot, profile: light), 0.45, "\(id) \(spot)")
            let hi = ride(light, length: b.route.length, kph: 20).filter { $0.s >= s0 && $0.s < s1 }.map(\.ev).max()
            XCTAssertLessThan(hi ?? .nan, 0.45, "\(id) \(s0)-\(s1) at 20 km/h")
        }
    }

    /// Into the dark over about 2 s, out over about 1 s, capped at 0.5 EV/s
    /// on the way out; it lands on the target exactly.
    func test_easing() {
        var ev: Float = 0
        let dt: Float = 1 / 60
        for _ in 0..<120 { ev = LaneExposure.step(ev, towards: 0.75, dt: dt) }   // 2 s in
        XCTAssertEqual(ev, 0.75 * (1 - exp(-1)), accuracy: 0.02)
        for _ in 0..<600 { ev = LaneExposure.step(ev, towards: 0.75, dt: dt) }
        XCTAssertEqual(ev, 0.75)
        let first = LaneExposure.step(ev, towards: 0, dt: dt)
        XCTAssertEqual((ev - first) / dt, LaneExposure.maxRate, accuracy: 1e-3, "rate-limited out of the lane")
        for _ in 0..<480 { ev = LaneExposure.step(ev, towards: 0, dt: dt) }
        XCTAssertEqual(ev, 0)
        XCTAssertEqual(LaneExposure.step(0.3, towards: 0.75, dt: 0), 0.3)
    }

    func test_noRasterMeansOpenSky() throws {
        let b: CourseBundle
        do {
            b = try CourseBundle.load(id: "koppenberg")
        } catch {
            throw XCTSkip("koppenberg data not in the test host bundle: \(error)")
        }
        XCTAssertTrue(LightProfile.make(bundle: b, pixels: nil).sky.isEmpty, "no raster decoded: open")
        let light = LightProfile.open
        XCTAssertEqual(light.sky(at: 120), 1)
        XCTAssertEqual(light.sun(at: 120), 1)
        XCTAssertEqual(light.metered(at: 120), 1)
        XCTAssertEqual(LaneExposure.target(at: 120, profile: light), 0)
        var applied: [Float] = []
        let exposure = LaneExposure()
        exposure.reset(s: 0, profile: light) { applied.append($0) }
        for k in 1...60 { exposure.update(s: Double(k), dt: 1.0 / 60, profile: light) { applied.append($0) } }
        XCTAssertEqual(applied, [0], "set once at the start, then left alone")
    }

    /// Every material on the rider and bike carries the sky light at 1,
    /// and all of them follow `setSkyVisibility`, never below the floor.
    func test_riderSkyLightReachesEveryMaterial() {
        let rig = RiderRig(quality: .balanced)
        var materials: [SCNMaterial] = []
        rig.node.enumerateHierarchy { n, _ in materials += n.geometry?.materials ?? [] }
        XCTAssertGreaterThan(materials.count, 20)
        func values() -> [Double] { materials.map { ($0.value(forKey: "riderSky") as? NSNumber)?.doubleValue ?? -1 } }
        for m in materials {
            XCTAssertEqual(m.shaderModifiers?[.surface], RiderMaterials.skySurface, m.name ?? "?")
        }
        XCTAssertTrue(values().allSatisfy { $0 == 1 }, "\(values())")
        XCTAssertFalse(RiderMaterials.skySurface.components(separatedBy: "#pragma body")[0].contains("//"))

        rig.setSkyVisibility(0.2, floor: 0.6, deltaTime: 0)
        XCTAssertTrue(values().allSatisfy { abs($0 - 0.6) < 1e-6 }, "\(values())")
        // Eased back out to the open sky, and landing on 1 exactly.
        for _ in 0..<120 { rig.setSkyVisibility(1, floor: 0.6, deltaTime: 1.0 / 60) }
        XCTAssertTrue(values().allSatisfy { $0 == 1 }, "\(values())")
        rig.setSkyVisibility(0.5, floor: 0.3, deltaTime: 0.1)
        let mid = values()[0]
        XCTAssertTrue(mid < 1 && mid > Double(pow(Float(0.5), 0.6)), "eased: \(mid)")
    }
}
