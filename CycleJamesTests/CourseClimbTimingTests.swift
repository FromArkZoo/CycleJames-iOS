import XCTest
@testable import CycleJames

final class CourseClimbTimingTests: XCTestCase {
    // The Koppenberg's timed climb.
    private let startS = 299.97
    private let endS = 870.17

    func test_crossingsAreInterpolatedWithinATick() {
        var timer = ClimbTimer(startS: 300, endS: 400, rideStartS: 0)
        timer.advance(fromS: 290, toS: 299, t0: 0, t1: 1, powerW: 200)
        XCTAssertNil(timer.startTime)
        // Crosses 300 a quarter of the way through a 4 m tick.
        timer.advance(fromS: 299, toS: 303, t0: 1, t1: 2, powerW: 200)
        XCTAssertEqual(timer.startTime ?? -1, 1.25, accuracy: 1e-12)
        timer.advance(fromS: 303, toS: 398, t0: 2, t1: 30, powerW: 200)
        XCTAssertNil(timer.summitTime)
        // Summit at 400, 40 % into a 5 m tick from t = 30 to 31.
        timer.advance(fromS: 398, toS: 403, t0: 30, t1: 31, powerW: 200)
        XCTAssertEqual(timer.summitTime ?? -1, 30.4, accuracy: 1e-12)
        XCTAssertEqual(timer.climbTimeSec ?? -1, 29.15, accuracy: 1e-12)
        // Later ticks change nothing.
        timer.advance(fromS: 403, toS: 420, t0: 31, t1: 35, powerW: 500)
        XCTAssertEqual(timer.climbTimeSec ?? -1, 29.15, accuracy: 1e-12)
        XCTAssertEqual(timer.elapsed(at: 100) ?? -1, 29.15, accuracy: 1e-12)
    }

    func test_constantSpeedClimb_exactTimeAndSplits_atAnyTickRate() {
        for dt in [1.0 / 30, 0.25, 1.7] {
            let speed = 3.0
            var timer = ClimbTimer(startS: startS, endS: endS, rideStartS: 280)
            var s = 280.0, t = 0.0
            while s < 900 {
                let s1 = s + speed * dt
                timer.advance(fromS: s, toS: s1, t0: t, t1: t + dt, powerW: 250)
                s = s1; t += dt
            }
            let length = endS - startS
            XCTAssertEqual(timer.climbTimeSec ?? -1, length / speed, accuracy: 1e-6, "dt \(dt)")
            XCTAssertEqual(timer.avgPowerW ?? -1, 250, accuracy: 1e-6)
            XCTAssertEqual(timer.splits.count, 59)          // 0, 10 … 570, 570.2
            XCTAssertEqual(timer.splits[0], 0)
            XCTAssertEqual(timer.splits[10], 100 / speed, accuracy: 1e-6)
            XCTAssertEqual(timer.splits.last ?? -1, length / speed, accuracy: 1e-6)
        }
    }

    func test_climbWorkCountsOnlyTheClimb() {
        var timer = ClimbTimer(startS: 100, endS: 200, rideStartS: 0)
        // 1 s ticks at 10 m/s; 400 W before the climb, 200 W on it.
        var s = 0.0, t = 0.0
        while s < 300 {
            let p: Double = s < 100 ? 400 : 200
            timer.advance(fromS: s, toS: s + 10, t0: t, t1: t + 1, powerW: p)
            s += 10; t += 1
        }
        XCTAssertEqual(timer.climbTimeSec ?? -1, 10, accuracy: 1e-9)
        XCTAssertEqual(timer.avgPowerW ?? -1, 200, accuracy: 1e-9)
    }

    func test_rideStartingPastTheClimbStart_isNotTimed() {
        var timer = ClimbTimer(startS: startS, endS: endS, rideStartS: 560)
        XCTAssertFalse(timer.isEligible)
        timer.advance(fromS: 560, toS: 900, t0: 0, t1: 100, powerW: 300)
        XCTAssertNil(timer.startTime)
        XCTAssertNil(timer.climbTimeSec)
        XCTAssertNil(timer.elapsed(at: 50))
    }

    func test_standingStartOnTheLine_counts() {
        var timer = ClimbTimer(startS: 300, endS: 310, rideStartS: 300)
        timer.advance(fromS: 300, toS: 300, t0: 0, t1: 1, powerW: 0)  // not moving yet
        XCTAssertNil(timer.startTime)
        timer.advance(fromS: 300, toS: 301, t0: 1, t1: 2, powerW: 100)
        XCTAssertEqual(timer.startTime ?? -1, 1, accuracy: 1e-12)
    }

    func test_summitAtTheRouteEnd_counts() {
        // A ride that is clamped exactly onto the summit still finishes it.
        var timer = ClimbTimer(startS: 0, endS: 25.3, rideStartS: 0)
        timer.advance(fromS: 0, toS: 20, t0: 0, t1: 2, powerW: 100)
        timer.advance(fromS: 20, toS: 25.3, t0: 2, t1: 3, powerW: 100)
        XCTAssertEqual(timer.climbTimeSec ?? -1, 3, accuracy: 1e-12)
    }

    func test_splitDistances() {
        let a = ClimbTimer.splitDistances(lengthM: 570.2, spacingM: 10)
        XCTAssertEqual(a.count, 59)
        XCTAssertEqual(a[57], 570)
        XCTAssertEqual(a.last ?? -1, 570.2, accuracy: 1e-9)
        let b = ClimbTimer.splitDistances(lengthM: 570, spacingM: 10)
        XCTAssertEqual(b.count, 58)
        XCTAssertEqual(b.last, 570)
        // Float noise doesn't add a sliver of a split.
        XCTAssertEqual(ClimbTimer.splitDistances(lengthM: 570.0000000001, spacingM: 10).count, 58)
    }

    func test_referenceTime_interpolatesBetweenSplits() {
        let length = 25.0
        // Marks at 0, 10, 20, 25 m.
        let splits = [0.0, 4.0, 10.0, 14.0]
        XCTAssertEqual(ClimbTimer.referenceTime(atDistance: 0, splits: splits, totalSec: 14, lengthM: length), 0)
        XCTAssertEqual(ClimbTimer.referenceTime(atDistance: 5, splits: splits, totalSec: 14, lengthM: length), 2, accuracy: 1e-12)
        XCTAssertEqual(ClimbTimer.referenceTime(atDistance: 15, splits: splits, totalSec: 14, lengthM: length), 7, accuracy: 1e-12)
        XCTAssertEqual(ClimbTimer.referenceTime(atDistance: 22.5, splits: splits, totalSec: 14, lengthM: length), 12, accuracy: 1e-12)
        XCTAssertEqual(ClimbTimer.referenceTime(atDistance: 25, splits: splits, totalSec: 14, lengthM: length), 14, accuracy: 1e-12)
        // Clamped beyond either end.
        XCTAssertEqual(ClimbTimer.referenceTime(atDistance: 99, splits: splits, totalSec: 14, lengthM: length), 14, accuracy: 1e-12)
        XCTAssertEqual(ClimbTimer.referenceTime(atDistance: -5, splits: splits, totalSec: 14, lengthM: length), 0)
    }

    func test_referenceTime_fallsBackToEvenPace() {
        // No splits, or splits from a climb of another length.
        XCTAssertEqual(ClimbTimer.referenceTime(atDistance: 50, splits: nil, totalSec: 200, lengthM: 100), 100, accuracy: 1e-12)
        XCTAssertEqual(ClimbTimer.referenceTime(atDistance: 25, splits: [0, 1, 2], totalSec: 200, lengthM: 100), 50, accuracy: 1e-12)
    }

    /// The live PB delta: a rider 10 % slower than the PB run is 10 % of
    /// the PB's elapsed time behind at every point.
    func test_pbDelta_fromSplits() {
        let length = endS - startS
        var pbRun = ClimbTimer(startS: startS, endS: endS, rideStartS: 0)
        // PB: 3 m/s on the first half, 2 m/s on the second, in 30 Hz ticks
        // with one cut exactly at the change of pace.
        var s = 0.0, t = 0.0
        func ride(to target: Double, speed v: Double) {
            while s < target - 1e-12 {
                let ds = min(v / 30, target - s)
                pbRun.advance(fromS: s, toS: s + ds, t0: t, t1: t + ds / v, powerW: 300)
                s += ds; t += ds / v
            }
        }
        ride(to: startS + length / 2, speed: 3)
        ride(to: 1000, speed: 2)
        let pbSplits = pbRun.splits
        let pbTotal = pbRun.climbTimeSec ?? 0
        XCTAssertEqual(pbTotal, length / 2 / 3 + length / 2 / 2, accuracy: 1e-6)

        // (Not inside the 280–290 m split, where the pace changes mid-split.)
        for d in [0.0, 45, 200, 400, 555, 570.2] {
            let pbAtD = d <= length / 2 ? d / 3 : length / 2 / 3 + (d - length / 2) / 2
            let reference = ClimbTimer.referenceTime(atDistance: d, splits: pbSplits, totalSec: pbTotal, lengthM: length)
            XCTAssertEqual(reference, pbAtD, accuracy: 1e-6, "d \(d)")
            let current = pbAtD * 1.1
            XCTAssertEqual(current - reference, pbAtD * 0.1, accuracy: 1e-6)
        }
    }

    func test_personalBestStorage_roundTrips() {
        let id = "test_course_pb_storage"
        AppSettings.clearPersonalBest(courseID: id)
        defer { AppSettings.clearPersonalBest(courseID: id) }
        XCTAssertNil(AppSettings.personalBestSeconds(courseID: id))
        XCTAssertNil(AppSettings.personalBestSplits(courseID: id))
        AppSettings.setPersonalBest(seconds: 123.4, splits: [0, 5.5, 11.25], courseID: id)
        XCTAssertEqual(AppSettings.personalBestSeconds(courseID: id), 123.4)
        XCTAssertEqual(AppSettings.personalBestSplits(courseID: id), [0, 5.5, 11.25])
        AppSettings.clearPersonalBest(courseID: id)
        XCTAssertNil(AppSettings.personalBestSeconds(courseID: id))
        XCTAssertNil(AppSettings.personalBestSplits(courseID: id))
    }
}
