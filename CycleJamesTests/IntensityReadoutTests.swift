import XCTest
@testable import CycleJames

final class IntensityReadoutTests: XCTestCase {
    func test_wholeRide_zero_showsPlainWatts() {
        XCTAssertEqual(IntensityReadout.wholeRide(offsetWatts: 0), "0 W")
    }

    func test_wholeRide_positive_showsPlusSign() {
        XCTAssertEqual(IntensityReadout.wholeRide(offsetWatts: 10), "+10 W")
    }

    func test_wholeRide_negative_usesTypographicMinus() {
        // U+2212 minus, not ASCII hyphen.
        XCTAssertEqual(IntensityReadout.wholeRide(offsetWatts: -5), "\u{2212}5 W")
    }

    func test_intervalTarget_active_showsAbsoluteWatts() {
        XCTAssertEqual(
            IntensityReadout.intervalTarget(watts: 210, hasActiveInterval: true),
            "This interval · 210 W"
        )
    }

    func test_intervalTarget_inactive_showsDash() {
        XCTAssertEqual(
            IntensityReadout.intervalTarget(watts: 0, hasActiveInterval: false),
            "This interval · —"
        )
    }
}
