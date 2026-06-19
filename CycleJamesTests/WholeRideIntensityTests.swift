import XCTest
@testable import CycleJames

final class WholeRideIntensityTests: XCTestCase {
    private func sampleWorkout() -> Workout {
        Workout(id: "t", name: "T", description: "", category: .endurance,
                intervals: [
                    .steady(name: "easy", duration: 60, powerPercent: 50),
                    .steady(name: "hard", duration: 60, powerPercent: 100)
                ])
    }

    func test_adjustingAllIntervals_scalesEveryInterval() {
        let w = sampleWorkout().adjustingAllIntervals(byWatts: 10, ftp: 200)
        // +10W at FTP 200 = +5% of FTP applied to each interval.
        XCTAssertEqual(w.intervals[0].midPercent, 55, accuracy: 0.001)
        XCTAssertEqual(w.intervals[1].midPercent, 105, accuracy: 0.001)
    }

    @MainActor
    func test_adjustWholeRide_accumulatesOffset() {
        let rc = RideController()
        rc.select(sampleWorkout())
        rc.adjustWholeRide(byWatts: 5)
        rc.adjustWholeRide(byWatts: 5)
        XCTAssertEqual(rc.wholeRideOffsetWatts, 10)
    }
}
