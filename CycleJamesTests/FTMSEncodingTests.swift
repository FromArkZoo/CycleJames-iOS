import XCTest
@testable import CycleJames

final class FTMSEncodingTests: XCTestCase {
    // Set Indoor Bike Simulation Parameters (op 0x11):
    // [0x11, windSpeed(int16 LE, 0.001 m/s), grade(int16 LE, 0.01%), crr(uint8, 0.0001), cw(uint8, 0.01)]
    func test_simParams_zeroGrade_defaultCoeffs() {
        let data = FTMSManager.simulationParametersData(grade: 0)
        XCTAssertEqual([UInt8](data), [0x11, 0x00, 0x00, 0x00, 0x00, 0x28, 0x33])
    }

    func test_simParams_fivePercentGrade() {
        let data = FTMSManager.simulationParametersData(grade: 5.0)
        // grade 5.00% -> 500 -> 0x01F4 -> LE F4 01
        XCTAssertEqual([UInt8](data), [0x11, 0x00, 0x00, 0xF4, 0x01, 0x28, 0x33])
    }
}
