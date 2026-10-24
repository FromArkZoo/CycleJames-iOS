import XCTest
@testable import CycleJames

final class RideModeTests: XCTestCase {
    func test_ergConnected_sendsTarget() {
        XCTAssertTrue(RideController.shouldSendErgTarget(mode: .erg, connected: true))
    }
    func test_freeRideConnected_doesNotSendTarget() {
        XCTAssertFalse(RideController.shouldSendErgTarget(mode: .freeRide, connected: true))
    }
    func test_ergDisconnected_doesNotSendTarget() {
        XCTAssertFalse(RideController.shouldSendErgTarget(mode: .erg, connected: false))
    }
    func test_gearShows_onlyInFreeRide_withAWattbike() {
        XCTAssertTrue(RideController.showsGear(mode: .freeRide, gearsAvailable: true))
        XCTAssertFalse(RideController.showsGear(mode: .erg, gearsAvailable: true))
        XCTAssertFalse(RideController.showsGear(mode: .freeRide, gearsAvailable: false))
    }
}
