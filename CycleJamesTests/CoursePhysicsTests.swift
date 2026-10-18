import XCTest
@testable import CycleJames

final class CoursePhysicsTests: XCTestCase {
    private let rider = RidePhysics.Parameters(massKg: 83.5)
    private let asphalt = 0.004
    private let cobbles = 0.009

    /// Rides `seconds` at 30 Hz ticks on a constant road.
    private func ride(from state: RidePhysics.State, powerW: Double, gradePct: Double, crr: Double,
                      seconds: Double, dt: Double = 1.0 / 30,
                      each: ((RidePhysics.State, RidePhysics.State) -> Void)? = nil) -> RidePhysics.State {
        var s = state
        let road = RidePhysics.Terrain(gradePct: gradePct, crr: crr)
        for _ in 0..<Int((seconds / dt).rounded()) {
            let next = RidePhysics.step(s, powerW: powerW, dt: dt, params: rider) { _ in road }
            each?(s, next)
            s = next
        }
        return s
    }

    func test_flat200W_settlesAround9Point4To9Point8() {
        let end = ride(from: .init(distanceM: 0, speedMps: 0), powerW: 200, gradePct: 0, crr: asphalt, seconds: 180)
        XCTAssertGreaterThanOrEqual(end.speedMps, 9.35)
        XCTAssertLessThanOrEqual(end.speedMps, 9.8)
        let steady = RidePhysics.steadySpeed(powerW: 200, terrain: .init(gradePct: 0, crr: asphalt), params: rider)
        XCTAssertEqual(end.speedMps, steady, accuracy: 0.02)
    }

    /// With the specified model (η 0.975, CdA 0.32, 83.5 kg) 250 W at
    /// 11.3 % settles at ~2.43 m/s on cobbles and ~2.53 m/s on asphalt.
    func test_climb250W_at11Point3Percent() {
        for crr in [asphalt, cobbles] {
            let end = ride(from: .init(distanceM: 0, speedMps: 4), powerW: 250, gradePct: 11.3, crr: crr, seconds: 60)
            XCTAssertGreaterThan(end.speedMps, 2.35, "crr \(crr)")
            XCTAssertLessThan(end.speedMps, 2.65, "crr \(crr)")
            let steady = RidePhysics.steadySpeed(powerW: 250, terrain: .init(gradePct: 11.3, crr: crr), params: rider)
            XCTAssertEqual(end.speedMps, steady, accuracy: 0.01)
        }
        // Cobbles cost speed.
        let a = RidePhysics.steadySpeed(powerW: 250, terrain: .init(gradePct: 11.3, crr: asphalt), params: rider)
        let c = RidePhysics.steadySpeed(powerW: 250, terrain: .init(gradePct: 11.3, crr: cobbles), params: rider)
        XCTAssertGreaterThan(a, c + 0.05)
    }

    func test_zeroPowerOnTwentyPercent_stopsAndNeverRollsBack() {
        var minSpeed = Double.infinity
        var stoppedAfter: Double?
        var t = 0.0
        let end = ride(from: .init(distanceM: 590, speedMps: 4), powerW: 0, gradePct: 20, crr: cobbles, seconds: 10) { a, b in
            t += 1.0 / 30
            minSpeed = min(minSpeed, b.speedMps)
            XCTAssertGreaterThanOrEqual(b.distanceM, a.distanceM)
            XCTAssertFalse(b.speedMps.isNaN)
            if b.speedMps == 0, stoppedAfter == nil { stoppedAfter = t }
        }
        XCTAssertEqual(end.speedMps, 0)
        XCTAssertGreaterThanOrEqual(minSpeed, 0)
        // ~2 m/s² of deceleration from 4 m/s: stopped within about 2 s.
        XCTAssertNotNil(stoppedAfter)
        XCTAssertLessThan(stoppedAfter ?? 99, 3)
        // And it stays put.
        let later = ride(from: end, powerW: 0, gradePct: 20, crr: cobbles, seconds: 5)
        XCTAssertEqual(later, end)
    }

    func test_fromRestOnRamp_powerGetsRiderMoving() {
        let end = ride(from: .init(distanceM: 0, speedMps: 0), powerW: 300, gradePct: 21, crr: cobbles, seconds: 20)
        let steady = RidePhysics.steadySpeed(powerW: 300, terrain: .init(gradePct: 21, crr: cobbles), params: rider)
        XCTAssertEqual(end.speedMps, steady, accuracy: 0.02)
        XCTAssertGreaterThan(end.distanceM, 20)
    }

    func test_tinyPowerOnRamp_crawlsWithoutBlowingUp() {
        let end = ride(from: .init(distanceM: 0, speedMps: 0), powerW: 5, gradePct: 20, crr: cobbles, seconds: 10)
        XCTAssertFalse(end.speedMps.isNaN)
        XCTAssertGreaterThan(end.speedMps, 0)
        XCTAssertLessThan(end.speedMps, 0.1)
    }

    func test_steepDescentPullsStoppedBikeForward_gentleOneDoesNot() {
        let steep = ride(from: .init(distanceM: 0, speedMps: 0), powerW: 0, gradePct: -6, crr: asphalt, seconds: 10)
        XCTAssertGreaterThan(steep.speedMps, 3)
        // −0.2 % is less than rolling resistance: a stopped bike stays stopped.
        let gentle = ride(from: .init(distanceM: 0, speedMps: 0), powerW: 0, gradePct: -0.2, crr: asphalt, seconds: 10)
        XCTAssertEqual(gentle.speedMps, 0)
        XCTAssertEqual(gentle.distanceM, 0)
    }

    func test_longTickMatchesManySmallOnes() {
        let start = RidePhysics.State(distanceM: 100, speedMps: 3)
        let road = RidePhysics.Terrain(gradePct: 8, crr: cobbles)
        let one = RidePhysics.step(start, powerW: 280, dt: 2, params: rider) { _ in road }
        let many = ride(from: start, powerW: 280, gradePct: 8, crr: cobbles, seconds: 2)
        XCTAssertEqual(one.speedMps, many.speedMps, accuracy: 0.01)
        XCTAssertEqual(one.distanceM, many.distanceM, accuracy: 0.02)
    }

    func test_zeroOrNegativeDt_isNoOp() {
        let start = RidePhysics.State(distanceM: 10, speedMps: 5)
        XCTAssertEqual(RidePhysics.step(start, powerW: 300, dt: 0, params: rider) { _ in .init(gradePct: 0, crr: 0.004) }, start)
        XCTAssertEqual(RidePhysics.step(start, powerW: 300, dt: -1, params: rider) { _ in .init(gradePct: 0, crr: 0.004) }, start)
    }

    /// Route distance is horizontal: at steady speed v along a 20 % slope
    /// the rider covers v·cos(atan 0.2) of it per second.
    func test_onAGrade_routeDistanceIsTheHorizontalPart() {
        let road = RidePhysics.Terrain(gradePct: 20, crr: cobbles)
        let v = RidePhysics.steadySpeed(powerW: 300, terrain: road, params: rider)
        let end = ride(from: .init(distanceM: 0, speedMps: v), powerW: 300, gradePct: 20, crr: cobbles, seconds: 10)
        XCTAssertEqual(end.speedMps, v, accuracy: 1e-3)
        XCTAssertEqual(end.distanceM, v * 10 / (1.0 + 0.04).squareRoot(), accuracy: 0.01)
        // Flat ground is unchanged.
        let flat = RidePhysics.steadySpeed(powerW: 200, terrain: .init(gradePct: 0, crr: asphalt), params: rider)
        let onFlat = ride(from: .init(distanceM: 0, speedMps: flat), powerW: 200, gradePct: 0, crr: asphalt, seconds: 10)
        XCTAssertEqual(onFlat.distanceM, flat * 10, accuracy: 0.01)
    }

    func test_terrainFollowsDistance() {
        // Flat to 50 m, then a wall: the rider slows once on it.
        var s = RidePhysics.State(distanceM: 0, speedMps: 8)
        for _ in 0..<(30 * 30) {
            s = RidePhysics.step(s, powerW: 200, dt: 1.0 / 30, params: rider) { d in
                .init(gradePct: d < 50 ? 0 : 15, crr: 0.004)
            }
        }
        let wall = RidePhysics.steadySpeed(powerW: 200, terrain: .init(gradePct: 15, crr: 0.004), params: rider)
        XCTAssertEqual(s.speedMps, wall, accuracy: 0.02)
    }
}
