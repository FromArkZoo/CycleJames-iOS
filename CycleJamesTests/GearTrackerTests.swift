import XCTest
@testable import CycleJames

final class GearTrackerTests: XCTestCase {
    private func tracker(count: Int = 22) -> GearTracker {
        var t = GearTracker(count: count)
        t.setAvailable(true)
        return t
    }

    func test_firstGear_showsWithoutAFlash() {
        var t = tracker()
        XCTAssertNil(t.gear)
        t.receive(gear: 8, now: 10)
        XCTAssertEqual(t.gear, 8)
        XCTAssertNil(t.lastShift)
    }

    func test_eachShift_flashesItsDirection() {
        var t = tracker()
        t.receive(gear: 8, now: 10)
        t.receive(gear: 9, now: 12)
        XCTAssertEqual(t.lastShift?.kind, .harder)
        XCTAssertEqual(t.lastShift?.steps, 1)
        XCTAssertEqual(t.lastShift?.gear, 9)
        XCTAssertEqual(t.lastShift?.at, 12)
        t.receive(gear: 8, now: 14)
        XCTAssertEqual(t.lastShift?.kind, .easier)
        XCTAssertEqual(t.lastShift?.steps, 1)
    }

    func test_quickShiftsTheSameWay_addUp_andAReversalStartsAgain() {
        var t = tracker()
        t.receive(gear: 8, now: 10)
        t.receive(gear: 9, now: 11.0)
        t.receive(gear: 10, now: 11.4)
        t.receive(gear: 12, now: 11.8)          // two presses in one report
        XCTAssertEqual(t.lastShift?.steps, 4)
        let serial = t.lastShift?.serial
        t.receive(gear: 11, now: 12.0)
        XCTAssertEqual(t.lastShift?.kind, .easier)
        XCTAssertEqual(t.lastShift?.steps, 1)
        XCTAssertNotEqual(t.lastShift?.serial, serial)
        t.receive(gear: 10, now: 20)            // long after: a new run
        XCTAssertEqual(t.lastShift?.steps, 1)
    }

    func test_repeatedReportsOfTheSameGear_flashNothing() {
        var t = tracker()
        t.receive(gear: 8, now: 10)
        t.receive(gear: 9, now: 11)
        let shift = t.lastShift
        t.receive(gear: 9, now: 30)
        XCTAssertEqual(t.lastShift, shift)
    }

    func test_aGearAboveTheCount_raisesItForTheSession() {
        var t = tracker(count: 22)
        t.receive(gear: 24, now: 10)
        XCTAssertEqual(t.count, 24)
        t.receive(gear: 12, now: 11)
        XCTAssertEqual(t.count, 24, "still 24 back down the range")
        t.setAvailable(false)
        XCTAssertEqual(t.count, 22)
    }

    func test_changingTheGearCount_keepsTheSessionsHighestGear() {
        var t = tracker(count: 22)
        t.receive(gear: 9, now: 10)
        t.setCount(11)
        XCTAssertEqual(t.count, 11)
        XCTAssertEqual(t.gear, 9)
        t.setCount(24)
        XCTAssertEqual(t.count, 24)
        t.setCount(11)
        t.receive(gear: 14, now: 11)
        XCTAssertEqual(t.count, 14)
        t.setCount(11)                          // unchanged: no effect
        XCTAssertEqual(t.count, 14)
        t.setAvailable(true, count: 22)
        XCTAssertEqual(t.count, 22)
    }

    func test_aPressPastEitherEnd_bumps_butAPressThatShifts_doesNot() {
        var t = tracker()
        t.receive(gear: 21, now: 10)
        t.press(up: true, now: 11)              // the press, then its gear
        t.receive(gear: 22, now: 11.05)
        t.settle(now: 12)
        XCTAssertEqual(t.lastShift?.kind, .harder)
        t.press(up: true, now: 13)              // nothing further up
        t.settle(now: 13.3)
        XCTAssertEqual(t.lastShift?.kind, .harder, "not settled yet")
        t.settle(now: 13.7)
        XCTAssertEqual(t.lastShift?.kind, .top)
        XCTAssertEqual(t.lastShift?.steps, 0)
        t.receive(gear: 1, now: 20)
        t.press(up: false, now: 21)
        t.settle(now: 22)
        XCTAssertEqual(t.lastShift?.kind, .bottom)
    }

    func test_aPressInTheMiddleOfTheRange_withNoGearReport_isNotABump() {
        var t = tracker()
        t.receive(gear: 10, now: 10)
        t.press(up: true, now: 11)
        t.settle(now: 12)
        XCTAssertNil(t.lastShift)
    }

    func test_aPressSettledTooLate_isDropped() {
        var t = tracker()
        t.receive(gear: 22, now: 10)
        t.press(up: true, now: 11)
        t.settle(now: 14)                       // nothing settled it in time
        XCTAssertNil(t.lastShift)
    }

    func test_aPressReportedAfterItsGear_isNotABump() {
        var t = tracker()
        t.receive(gear: 21, now: 10)
        t.receive(gear: 22, now: 11)
        t.press(up: true, now: 11.1)
        t.settle(now: 12)
        XCTAssertEqual(t.lastShift?.kind, .harder)
    }

    func test_pressesWithoutGears_stillShowTheDirection() {
        var t = tracker()
        t.press(up: true, now: 10)
        XCTAssertEqual(t.lastShift?.kind, .harder)
        XCTAssertNil(t.lastShift?.gear)
        XCTAssertTrue(t.sawPresses)
        t.press(up: true, now: 10.3)
        XCTAssertEqual(t.lastShift?.steps, 2)
        t.press(up: false, now: 10.6)
        XCTAssertEqual(t.lastShift?.kind, .easier)
    }

    func test_losingTheLink_forgetsTheGear() {
        var t = tracker()
        t.receive(gear: 8, now: 10)
        t.receive(gear: 9, now: 11)
        t.receive(gear: nil, now: 12)
        XCTAssertNil(t.gear)
        XCTAssertNil(t.lastShift)
        XCTAssertTrue(t.available)
        t.setAvailable(false)
        XCTAssertFalse(t.available)
        // Back again: the first gear shows quietly.
        t.setAvailable(true)
        t.receive(gear: 12, now: 20)
        XCTAssertEqual(t.gear, 12)
        XCTAssertNil(t.lastShift)
    }

    // MARK: Badge wording

    func test_badgeWords_andVoiceOver() {
        func shift(_ kind: GearShift.Kind, steps: Int) -> GearShift {
            GearShift(kind: kind, steps: steps, gear: 14, at: 0, serial: 1)
        }
        XCTAssertEqual(GearBadge.word(shift(.harder, steps: 1)), "HARDER")
        XCTAssertEqual(GearBadge.word(shift(.harder, steps: 3)), "HARDER +3")
        XCTAssertEqual(GearBadge.word(shift(.easier, steps: 2)), "EASIER −2")
        XCTAssertEqual(GearBadge.word(shift(.top, steps: 0)), "TOP GEAR")
        XCTAssertEqual(GearBadge.word(shift(.bottom, steps: 0)), "LOWEST")
        XCTAssertEqual(GearBadge.spoken(gear: 14, count: 22, shift: shift(.harder, steps: 1)), "Gear 14 of 22, harder")
        XCTAssertEqual(GearBadge.spoken(gear: nil, count: 22, shift: nil), "Gear not known yet. Shift once to show it")
    }

    // MARK: Feed

    @MainActor
    func test_feed_followsReportsThroughItsEntryPoints() {
        let feed = GearFeed(count: 22)
        XCTAssertFalse(feed.state.available)
        feed.handleSupport(true)
        XCTAssertTrue(feed.state.available)
        XCTAssertEqual(feed.state.count, AppSettings.wattbikeGearCount)
        feed.handleGear(5, now: 100)
        feed.handleGear(6, now: 101)
        XCTAssertEqual(feed.state.gear, 6)
        XCTAssertEqual(feed.state.lastShift?.kind, .harder)
        feed.handlePress(up: false, now: 102)
        feed.handleGear(5, now: 102.05)
        XCTAssertEqual(feed.state.lastShift?.kind, .easier)
        feed.handleSupport(false)
        XCTAssertFalse(feed.state.available)
        XCTAssertNil(feed.state.gear)
    }
}
