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

    // Control-point responses: [0x80, request opcode, result code].
    func test_controlPointResponse_readsOpcodeAndResult() {
        let accepted = FTMSManager.controlPointResponse(Data([0x80, 0x11, 0x01]))
        XCTAssertEqual(accepted?.opcode, 0x11)
        XCTAssertEqual(accepted?.result, 0x01)
        let refused = FTMSManager.controlPointResponse(Data([0x80, 0x11, 0x05]))
        XCTAssertEqual(refused?.result, 0x05)
    }

    func test_controlPointResponse_ignoresOtherData() {
        XCTAssertNil(FTMSManager.controlPointResponse(Data([0x11, 0x00, 0x00])))  // a request, not a response
        XCTAssertNil(FTMSManager.controlPointResponse(Data([0x80, 0x11])))        // too short
        XCTAssertNil(FTMSManager.controlPointResponse(Data()))
    }

    func test_refusalReason_namesTheFTMSResultCodes() {
        XCTAssertEqual(FTMSManager.refusalReason(code: 0x02), "not supported")
        XCTAssertEqual(FTMSManager.refusalReason(code: 0x03), "invalid value")
        XCTAssertEqual(FTMSManager.refusalReason(code: 0x04), "failed")
        XCTAssertEqual(FTMSManager.refusalReason(code: 0x05), "no control")
        XCTAssertEqual(FTMSManager.refusalReason(code: 0x09), "code 0x09")
    }

    // Indoor Bike Data (0x2AD2): uint16 flags, then the fields they flag.
    func test_bikeData_fullRecord() {
        // Flags 0x0244: speed (bit 0 clear), cadence, power, heart rate.
        let data = Data([0x44, 0x02, 0xE8, 0x03, 0xAA, 0x00, 0xFA, 0x00, 0x8C])
        let d = FTMSManager.parseIndoorBikeData(data)
        XCTAssertEqual(d.speedKph ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(d.cadence, 85)
        XCTAssertEqual(d.power, 250)
        XCTAssertEqual(d.heartRate, 140)
    }

    /// A trainer splitting its record across notifications: one without
    /// power must not read as 0 W.
    func test_bikeData_splitRecord_absentFieldsAreNil() {
        // More Data set (no speed), cadence only.
        let cadenceOnly = FTMSManager.parseIndoorBikeData(Data([0x05, 0x00, 0xAA, 0x00]))
        XCTAssertNil(cadenceOnly.power)
        XCTAssertNil(cadenceOnly.speedKph)
        XCTAssertNil(cadenceOnly.heartRate)
        XCTAssertEqual(cadenceOnly.cadence, 85)
        // More Data set, power only.
        let powerOnly = FTMSManager.parseIndoorBikeData(Data([0x41, 0x00, 0x2C, 0x01]))
        XCTAssertEqual(powerOnly.power, 300)
        XCTAssertNil(powerOnly.cadence)
    }
}
