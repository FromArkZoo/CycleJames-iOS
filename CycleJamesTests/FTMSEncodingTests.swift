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

    // Wattbike readings (B4CC1224-…): [sequence, 0x03, sub-message, payload…].
    func test_wattbikeMessage_readsTheGear() {
        XCTAssertEqual(FTMSManager.wattbikeMessage(Data([0x2A, 0x03, 0xB6, 0x0E])), .gear(14))
        XCTAssertEqual(FTMSManager.wattbikeMessage(Data([0xFF, 0x03, 0xB6, 0x01, 0x00, 0x00])), .gear(1))
        XCTAssertEqual(FTMSManager.wattbikeMessage(Data([0x00, 0x03, 0xB6, 0x16])), .gear(22))
        XCTAssertEqual(FTMSManager.wattbikeMessage(Data([0x00, 0x03, 0xB6, 0x18])), .gear(24))
    }

    func test_wattbikeMessage_readsShifterPresses() {
        XCTAssertEqual(FTMSManager.wattbikeMessage(Data([0x07, 0x03, 0xF0, 0x02, 0x01])), .shift(up: true))
        XCTAssertEqual(FTMSManager.wattbikeMessage(Data([0x08, 0x03, 0xF0, 0x04, 0x01])), .shift(up: false))
        XCTAssertEqual(FTMSManager.wattbikeMessage(Data([0x09, 0x03, 0xF0, 0x01, 0x01])), .other)
    }

    func test_wattbikeMessage_ignoresEverythingElse() {
        XCTAssertEqual(FTMSManager.wattbikeMessage(Data([0x01, 0x03, 0xB6])), .other)        // too short
        XCTAssertEqual(FTMSManager.wattbikeMessage(Data([0x01, 0x03, 0xB6, 0x00])), .other)  // gear 0
        XCTAssertEqual(FTMSManager.wattbikeMessage(Data([0x01, 0x03, 0xB6, 0xFF])), .other)  // junk
        XCTAssertEqual(FTMSManager.wattbikeMessage(Data([0x01, 0x03, 0xC3, 0x05])), .other)
        XCTAssertEqual(FTMSManager.wattbikeMessage(Data([0x01, 0x02, 0xB6, 0x05])), .other)  // other message type
        XCTAssertEqual(FTMSManager.wattbikeMessage(Data()), .other)
    }

    #if DEBUG
    /// The DEBUG Wattbike log's FTMS fallback: the resistance level (bit 5)
    /// and the cadence in half rpm, which the ride's parser skips or rounds.
    func test_bikeFields_readTheResistanceLevel_andTheExactCadence() {
        // Flags 0x0064: speed, cadence (151 = 75.5 rpm), resistance 12, power 250.
        let full = WattbikeLog.bikeFields(Data([0x64, 0x00, 0xE8, 0x03, 0x97, 0x00, 0x0C, 0x00, 0xFA, 0x00]))
        XCTAssertEqual(full.flags, 0x0064)
        XCTAssertEqual(full.resistance, 12)
        XCTAssertEqual(full.cadenceRpm ?? 0, 75.5, accuracy: 1e-9)
        // Average speed, average cadence and distance before it: resistance -3.
        let late = WattbikeLog.bikeFields(Data([0x3E, 0x00, 0x00, 0x00, 0x00, 0x00, 0xAA, 0x00,
                                                0x00, 0x00, 0x00, 0x00, 0x00, 0xFD, 0xFF]))
        XCTAssertEqual(late.resistance, -3)
        XCTAssertEqual(late.cadenceRpm ?? 0, 85, accuracy: 1e-9)
        // No resistance flagged, and a short record.
        XCTAssertNil(WattbikeLog.bikeFields(Data([0x44, 0x02, 0xE8, 0x03, 0xAA, 0x00, 0xFA, 0x00, 0x8C])).resistance)
        XCTAssertNil(WattbikeLog.bikeFields(Data([0x20, 0x00, 0x0C])).resistance)
    }
    #endif
}
