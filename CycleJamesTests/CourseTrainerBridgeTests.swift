import XCTest
@testable import CycleJames

@MainActor
private final class FakeTrainer: TrainerSimControl {
    var autoReconnectEnabled = false
    /// Without control the trainer takes no simulation commands.
    var hasControl = true
    var sims: [(grade: Double, crr: Double, cw: Double)] = []
    var starts = 0
    var stops = 0
    var controlRequests = 0

    func setSimulation(grade: Double, crr: Double, cw: Double) -> Bool {
        guard hasControl else { return false }
        sims.append((grade, crr, cw))
        return true
    }
    func startTraining() { starts += 1 }
    func stopTraining() { stops += 1 }
    func requestControlIfNeeded() { controlRequests += 1 }
}

final class CourseTrainerBridgeTests: XCTestCase {
    private func grade(_ g: Double, difficulty: Int = 100) -> Double {
        var config = TrainerSimBridge.Config()
        config.difficultyPct = difficulty
        return TrainerSimBridge.trainerGrade(courseGradePct: g, config: config)
    }

    func test_scaling_uphillByDifficulty() {
        XCTAssertEqual(grade(10), 10, accuracy: 1e-9)
        XCTAssertEqual(grade(10, difficulty: 50), 5, accuracy: 1e-9)
        XCTAssertEqual(grade(21, difficulty: 0), 0, accuracy: 1e-9)
    }

    func test_scaling_descentsAtHalfTheScaledValue() {
        XCTAssertEqual(grade(-4), -2, accuracy: 1e-9)
        XCTAssertEqual(grade(-4, difficulty: 50), -1, accuracy: 1e-9)
    }

    func test_scaling_clamps() {
        XCTAssertEqual(grade(40), 25, accuracy: 1e-9)
        XCTAssertEqual(grade(-40), -10, accuracy: 1e-9)
        // Out-of-range difficulty is clamped too.
        XCTAssertEqual(grade(10, difficulty: 250), 10, accuracy: 1e-9)
    }

    func test_lookAheadIsThreeToFiveMetres() {
        XCTAssertEqual(TrainerSimBridge.lookAheadM(speedMps: 0), 3)
        XCTAssertEqual(TrainerSimBridge.lookAheadM(speedMps: 4), 4)
        XCTAssertEqual(TrainerSimBridge.lookAheadM(speedMps: 12), 5)
    }

    @MainActor
    func test_begin_startsTraining_firstUpdateSendsAtOnce() {
        let fake = FakeTrainer()
        let bridge = TrainerSimBridge(target: fake)
        XCTAssertFalse(bridge.update(courseGradePct: 5, crr: 0.009, now: 0), "inactive before begin")
        bridge.begin()
        XCTAssertEqual(fake.starts, 1)
        XCTAssertTrue(fake.autoReconnectEnabled)
        XCTAssertTrue(bridge.update(courseGradePct: 5, crr: 0.009, now: 100))
        XCTAssertEqual(fake.sims.count, 1)
        XCTAssertEqual(fake.sims[0].grade, 5, accuracy: 1e-9)
        XCTAssertEqual(fake.sims[0].crr, 0.009)
        XCTAssertEqual(fake.sims[0].cw, 0.51)
        XCTAssertEqual(bridge.lastSentGradePct, 5, accuracy: 1e-9)
    }

    @MainActor
    func test_rateLimit_atMostTwoPerSecond() {
        let fake = FakeTrainer()
        let bridge = TrainerSimBridge(target: fake)
        bridge.begin()
        // A gradient that changes every 30 Hz tick for 10 s.
        for i in 0..<300 {
            let t = Double(i) / 30
            bridge.update(courseGradePct: 2 + t, crr: 0.004, now: t)
        }
        XCTAssertLessThanOrEqual(fake.sims.count, 21)
        XCTAssertGreaterThanOrEqual(fake.sims.count, 19)
    }

    @MainActor
    func test_onlySendsWhenGradeMovesByATenth() {
        let fake = FakeTrainer()
        let bridge = TrainerSimBridge(target: fake)
        bridge.begin()
        bridge.update(courseGradePct: 5, crr: 0.004, now: 0)
        XCTAssertFalse(bridge.update(courseGradePct: 5.05, crr: 0.004, now: 1))
        XCTAssertFalse(bridge.update(courseGradePct: 4.95, crr: 0.004, now: 2))
        XCTAssertTrue(bridge.update(courseGradePct: 5.1, crr: 0.004, now: 3))
        XCTAssertEqual(fake.sims.count, 2)
        // A surface change alone is worth a command.
        XCTAssertTrue(bridge.update(courseGradePct: 5.1, crr: 0.009, now: 4))
        XCTAssertEqual(fake.sims.last?.crr, 0.009)
    }

    @MainActor
    func test_descentHalfAndDifficultyApplied() {
        let fake = FakeTrainer()
        var config = TrainerSimBridge.Config()
        config.difficultyPct = 50
        let bridge = TrainerSimBridge(target: fake, config: config)
        bridge.begin()
        bridge.update(courseGradePct: 20, crr: 0.009, now: 0)
        bridge.update(courseGradePct: -2, crr: 0.004, now: 1)
        XCTAssertEqual(fake.sims.map(\.grade), [10, -0.5])
    }

    @MainActor
    func test_pauseHoldsFlat_resumeResends() {
        let fake = FakeTrainer()
        let bridge = TrainerSimBridge(target: fake)
        bridge.begin()
        bridge.update(courseGradePct: 12, crr: 0.009, now: 0)
        bridge.hold(now: 0.1)
        XCTAssertEqual(fake.sims.last?.grade, 0)
        XCTAssertEqual(bridge.lastSentGradePct, 0)
        XCTAssertFalse(bridge.update(courseGradePct: 12, crr: 0.009, now: 5), "held while paused")
        bridge.resume()
        // Straight away, without waiting out the rate limit.
        XCTAssertTrue(bridge.update(courseGradePct: 12, crr: 0.009, now: 5.01))
        XCTAssertEqual(fake.sims.last?.grade, 12)
        XCTAssertEqual(fake.stops, 0)
    }

    @MainActor
    func test_endSendsFlat_stopsTraining_disarmsReconnect() {
        let fake = FakeTrainer()
        let bridge = TrainerSimBridge(target: fake)
        bridge.begin()
        bridge.update(courseGradePct: 15, crr: 0.009, now: 0)
        bridge.end()
        XCTAssertEqual(fake.sims.last?.grade, 0)
        XCTAssertEqual(fake.stops, 1)
        XCTAssertFalse(fake.autoReconnectEnabled)
        XCTAssertFalse(bridge.isActive)
        XCTAssertFalse(bridge.update(courseGradePct: 15, crr: 0.009, now: 10))
        // Ending twice doesn't send a second stop.
        bridge.end()
        XCTAssertEqual(fake.stops, 1)
    }

    @MainActor
    func test_resyncAfterReconnect_restartsAndResends() {
        let fake = FakeTrainer()
        let bridge = TrainerSimBridge(target: fake)
        bridge.begin()
        bridge.update(courseGradePct: 9, crr: 0.009, now: 0)
        bridge.resync(now: 0.1)
        XCTAssertEqual(fake.starts, 2)
        XCTAssertTrue(bridge.update(courseGradePct: 9, crr: 0.009, now: 0.2), "resent despite no change")
    }

    @MainActor
    func test_withoutControl_nothingCountsAsSent_untilControlArrives() {
        let fake = FakeTrainer()
        fake.hasControl = false
        let bridge = TrainerSimBridge(target: fake)
        bridge.begin()
        XCTAssertEqual(fake.controlRequests, 1, "asks for control again at the start")
        XCTAssertFalse(bridge.update(courseGradePct: 12, crr: 0.009, now: 0))
        XCTAssertTrue(fake.sims.isEmpty)
        XCTAssertEqual(bridge.lastSentGradePct, 0, "the trainer never took 12 %")
        XCTAssertNil(bridge.lastSentCrr)
        // Control granted a moment later: sent straight away, no rate limit.
        fake.hasControl = true
        XCTAssertTrue(bridge.update(courseGradePct: 12, crr: 0.009, now: 0.05))
        XCTAssertEqual(fake.sims.count, 1)
        XCTAssertEqual(bridge.lastSentGradePct, 12, accuracy: 1e-9)
    }

    @MainActor
    func test_noTarget_isHarmless() {
        let bridge = TrainerSimBridge(target: nil)
        bridge.begin()
        XCTAssertTrue(bridge.update(courseGradePct: 7, crr: 0.009, now: 0))
        XCTAssertEqual(bridge.lastSentGradePct, 7, accuracy: 1e-9)
        bridge.end()
        XCTAssertEqual(bridge.lastSentGradePct, 0)
    }
}
