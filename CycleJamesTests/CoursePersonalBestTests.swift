import XCTest
import SwiftData
@testable import CycleJames

/// Personal bests worked out again from History after a ride is deleted.
final class CoursePersonalBestTests: XCTestCase {
    private let courseID = "pb_test_course"
    private let startS = 100.0
    private let endS = 200.0

    override func tearDown() {
        AppSettings.clearPersonalBest(courseID: courseID)
        super.tearDown()
    }

    /// 1 Hz samples of a ride from s = 0: 10 m/s to the climb start, the
    /// 100 m climb at an even pace in `climbSec`, then 20 s more at 5 m/s.
    private func samples(climbSec: Int, virtual: Bool? = false) -> RideSamples {
        var dist: [Double] = [], speed: [Double] = []
        var s = 0.0
        for _ in 0..<10 { s += 10; dist.append(s); speed.append(10) }
        let pace = (endS - startS) / Double(climbSec)
        for _ in 0..<climbSec { s += pace; dist.append(s); speed.append(pace) }
        for _ in 0..<20 { s += 5; dist.append(s); speed.append(5) }
        let n = dist.count
        return RideSamples(power: Array(repeating: 250, count: n), cadence: Array(repeating: 80, count: n),
                           hr: Array(repeating: 0, count: n), targets: Array(repeating: 0, count: n),
                           distanceM: dist, altitudeM: Array(repeating: 10, count: n), speedMps: speed,
                           climbOnVirtualPower: virtual)
    }

    @MainActor
    private func session(climbSec: Int, virtual: Bool? = false, in context: ModelContext) -> RideSessionModel {
        let model = RideSessionModel(
            workoutId: CourseRideController.workoutID(courseID: courseID), workoutName: "Test", category: "Climb",
            durationSec: 30 + climbSec, ftp: 250, avgPower: 250, avgCadence: 80, avgHR: 0,
            np: 250, intensityFactor: 1, tss: 10, partial: false, sampleInterval: 1,
            samplesJSON: try? JSONEncoder().encode(samples(climbSec: climbSec, virtual: virtual))
        )
        context.insert(model)
        return model
    }

    @MainActor
    private func recompute(_ sessions: [RideSessionModel]) {
        CourseRideRecorder.recomputePersonalBest(courseID: courseID, climbStartS: startS, climbEndS: endS, from: sessions)
    }

    func test_climbTiming_fromSamples() throws {
        let t = try XCTUnwrap(CourseRideRecorder.climbTiming(samples: samples(climbSec: 40), interval: 1,
                                                             startS: startS, endS: endS))
        XCTAssertEqual(t.seconds, 40, accuracy: 1e-9)
        XCTAssertEqual(t.splits.count, 11)
        XCTAssertEqual(t.splits[0], 0)
        XCTAssertEqual(t.splits[5], 20, accuracy: 1e-9)
        XCTAssertEqual(t.splits.last ?? 0, 40, accuracy: 1e-9)
        // A ride that never reached the summit, or began past the climb
        // start, has no climb time.
        XCTAssertNil(CourseRideRecorder.climbTiming(samples: samples(climbSec: 40), interval: 1,
                                                    startS: startS, endS: 10_000))
        let late = RideSamples(power: [1, 1, 1], cadence: [0, 0, 0], hr: [0, 0, 0], targets: [0, 0, 0],
                               distanceM: [150, 175, 210], speedMps: [10, 25, 35])
        XCTAssertNil(CourseRideRecorder.climbTiming(samples: late, interval: 1, startS: startS, endS: endS))
    }

    @MainActor
    func test_recompute_afterDeletingRides() throws {
        let container = try ModelContainer(for: RideSessionModel.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let fast = session(climbSec: 40, in: context)
        let slow = session(climbSec: 50, in: context)
        let virtual = session(climbSec: 20, virtual: true, in: context)
        let older = session(climbSec: 45, virtual: nil, in: context)
        AppSettings.setPersonalBest(seconds: 39.87, splits: [0, 39.87], courseID: courseID, sessionID: fast.id)

        // Deleting another ride leaves the PB exactly as it was.
        recompute([fast, slow, virtual, older])
        XCTAssertEqual(AppSettings.personalBestSeconds(courseID: courseID), 39.87)
        XCTAssertEqual(AppSettings.personalBestSessionID(courseID: courseID), fast.id)

        // Deleting the PB ride: the fastest one left, never a virtual one
        // (older rides without the flag count).
        recompute([slow, virtual, older])
        XCTAssertEqual(AppSettings.personalBestSeconds(courseID: courseID) ?? 0, 45, accuracy: 1e-9)
        XCTAssertEqual(AppSettings.personalBestSessionID(courseID: courseID), older.id)
        XCTAssertEqual(AppSettings.personalBestSplits(courseID: courseID)?.count, 11)

        recompute([slow, virtual])
        XCTAssertEqual(AppSettings.personalBestSeconds(courseID: courseID) ?? 0, 50, accuracy: 1e-9)

        // Nothing left that counts: no PB.
        recompute([virtual])
        XCTAssertNil(AppSettings.personalBestSeconds(courseID: courseID))
        XCTAssertNil(AppSettings.personalBestSplits(courseID: courseID))
        XCTAssertNil(AppSettings.personalBestSessionID(courseID: courseID))

        // A PB the rider reset stays reset.
        recompute([fast, slow])
        XCTAssertNil(AppSettings.personalBestSeconds(courseID: courseID))
    }

    /// Reset, then a new PB ride that is discarded (deleted): the rides
    /// from before the reset don't bring the old PB back.
    @MainActor
    func test_recompute_afterAReset_ignoresRidesFromBeforeIt() throws {
        let container = try ModelContainer(for: RideSessionModel.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let before = session(climbSec: 40, in: context)
        before.date = Date(timeIntervalSinceNow: -3600)
        AppSettings.setPersonalBest(seconds: 40, splits: [0, 40], courseID: courseID, sessionID: before.id)
        AppSettings.clearPersonalBest(courseID: courseID)

        let after = session(climbSec: 50, in: context)
        let later = session(climbSec: 55, in: context)
        AppSettings.setPersonalBest(seconds: 50, splits: [0, 50], courseID: courseID, sessionID: after.id)

        // Deleting the new PB ride: only rides since the reset count.
        recompute([before, later])
        XCTAssertEqual(AppSettings.personalBestSeconds(courseID: courseID) ?? 0, 55, accuracy: 1e-9)
        XCTAssertEqual(AppSettings.personalBestSessionID(courseID: courseID), later.id)
        recompute([before])
        XCTAssertNil(AppSettings.personalBestSeconds(courseID: courseID))
    }
}
