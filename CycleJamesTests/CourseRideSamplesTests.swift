import XCTest
@testable import CycleJames

final class CourseRideSamplesTests: XCTestCase {
    func test_oldSamplesJSON_stillDecodes() throws {
        let old = #"{"power":[100,200],"cadence":[80,90],"hr":[120,130],"targets":[150,150]}"#
        let samples = try JSONDecoder().decode(RideSamples.self, from: Data(old.utf8))
        XCTAssertEqual(samples.power, [100, 200])
        XCTAssertEqual(samples.targets, [150, 150])
        XCTAssertNil(samples.distanceM)
        XCTAssertNil(samples.altitudeM)
        XCTAssertNil(samples.speedMps)
    }

    func test_workoutSamples_encodeWithoutCourseKeys() throws {
        let samples = RideSamples(power: [1], cadence: [2], hr: [3], targets: [4])
        let json = String(decoding: try JSONEncoder().encode(samples), as: UTF8.self)
        XCTAssertFalse(json.contains("distanceM"))
        XCTAssertFalse(json.contains("speedMps"))
    }

    func test_courseSamples_roundTrip() throws {
        let samples = RideSamples(power: [250], cadence: [70], hr: [160], targets: [0],
                                  distanceM: [312.5], altitudeM: [14.2], speedMps: [2.61])
        let back = try JSONDecoder().decode(RideSamples.self, from: JSONEncoder().encode(samples))
        XCTAssertEqual(back.distanceM, [312.5])
        XCTAssertEqual(back.altitudeM, [14.2])
        XCTAssertEqual(back.speedMps, [2.61])
    }

    func test_recorder_onePerSecond_timeWeighted() {
        let rec = CourseRideRecorder()
        // 1.5 s at 100 W, then 1.5 s at 400 W, in 30 Hz ticks.
        for i in 0..<90 {
            let p: Double = i < 45 ? 100 : 400
            rec.record(dt: 1.0 / 30, powerW: p, cadenceRpm: 80, hr: 150,
                       distanceM: Double(i), altitudeM: 10, speedMps: 3)
        }
        XCTAssertEqual(rec.samples.count, 3)
        XCTAssertEqual(rec.samples.map(\.power), [100, 250, 400])
        XCTAssertEqual(rec.samples[0].cadence, 80)
        XCTAssertEqual(rec.samples[0].hr, 150)
        // The part-second at the end is kept.
        rec.record(dt: 0.4, powerW: 300, cadenceRpm: 60, hr: 151, distanceM: 95, altitudeM: 11, speedMps: 2)
        rec.flush(hr: 151, distanceM: 95, altitudeM: 11, speedMps: 2)
        XCTAssertEqual(rec.samples.count, 4)
        XCTAssertEqual(rec.samples.last?.power, 300)
    }

    func test_recorder_longTickFillsEverySecond() {
        let rec = CourseRideRecorder()
        rec.record(dt: 2.5, powerW: 200, cadenceRpm: 85, hr: 0, distanceM: 20, altitudeM: 5, speedMps: 8)
        XCTAssertEqual(rec.samples.count, 2)
        XCTAssertEqual(rec.samples.map(\.power), [200, 200])
    }

    func test_recorder_snapshotHasMatchingCourseArrays() {
        let rec = CourseRideRecorder()
        for i in 0..<120 {
            rec.record(dt: 1, powerW: 200, cadenceRpm: 85, hr: 140,
                       distanceM: Double(i) * 3.04567, altitudeM: 12.3456, speedMps: 3.04567)
        }
        let snap = rec.snapshot()
        XCTAssertEqual(snap.interval, 1)
        XCTAssertEqual(snap.samples.power.count, 120)
        XCTAssertEqual(snap.samples.distanceM?.count, 120)
        XCTAssertEqual(snap.samples.altitudeM?.count, 120)
        XCTAssertEqual(snap.samples.speedMps?.count, 120)
        XCTAssertEqual(snap.samples.targets, Array(repeating: 0, count: 120))
        // Rounded for storage.
        XCTAssertEqual(snap.samples.altitudeM?.first ?? 0, 12.3, accuracy: 1e-9)
        XCTAssertEqual(snap.samples.speedMps?.first ?? 0, 3.05, accuracy: 1e-9)
    }

    func test_recorder_downsamplesLongRides() {
        let rec = CourseRideRecorder()
        for i in 0..<(100 * 60) {
            rec.record(dt: 1, powerW: 200, cadenceRpm: 85, hr: 140,
                       distanceM: Double(i), altitudeM: 0, speedMps: 1)
        }
        let snap = rec.snapshot()
        XCTAssertEqual(snap.interval, 5)
        XCTAssertEqual(snap.samples.power.count, 1200)
        XCTAssertEqual(snap.samples.distanceM?.count, 1200)
        // Distance at the end of each 5 s chunk.
        XCTAssertEqual(snap.samples.distanceM?.first ?? -1, 4, accuracy: 1e-9)
    }

    func test_rollingAverage_threeSeconds() {
        var avg = RollingAverage(windowSec: 3)
        XCTAssertEqual(avg.mean, 0)
        for _ in 0..<90 { avg.add(200, dt: 1.0 / 30) }
        XCTAssertEqual(avg.mean, 200, accuracy: 1e-9)
        // 1.5 s later at 400 W: half the window each.
        for _ in 0..<45 { avg.add(400, dt: 1.0 / 30) }
        XCTAssertEqual(avg.mean, 300, accuracy: 1)
        for _ in 0..<90 { avg.add(400, dt: 1.0 / 30) }
        XCTAssertEqual(avg.mean, 400, accuracy: 1e-6)
        // A long tick replaces the whole window.
        avg.add(100, dt: 5)
        XCTAssertEqual(avg.mean, 100, accuracy: 1e-9)
        avg.reset()
        XCTAssertEqual(avg.mean, 0)
    }
}
