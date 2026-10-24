import XCTest
import SwiftData
import QuartzCore
import Combine
@testable import CycleJames

/// End-to-end rides on the real Koppenberg data with virtual power, driven
/// by synthetic 30 Hz ticks (no countdown, no timer).
final class CourseRideControllerTests: XCTestCase {
    private let courseID = "koppenberg"

    /// Keeps the Simulator's own Koppenberg PB intact across the tests.
    private struct SavedPB {
        let id: String
        let seconds: Double?
        let splits: [Double]?

        init(_ id: String) {
            self.id = id
            seconds = AppSettings.personalBestSeconds(courseID: id)
            splits = AppSettings.personalBestSplits(courseID: id)
        }

        func restore() {
            AppSettings.clearPersonalBest(courseID: id)
            if let seconds, let splits {
                AppSettings.setPersonalBest(seconds: seconds, splits: splits, courseID: id)
            } else if let seconds {
                AppSettings.setPersonalBestSeconds(seconds, courseID: id)
            }
        }
    }

    @MainActor
    private func loadedController() async throws -> (CourseRideController, CourseBundle) {
        let c = CourseRideController()
        await c.load(courseID: courseID)
        guard c.phase == .ready, let bundle = c.bundle else {
            throw XCTSkip("Koppenberg data not in the test host bundle: \(c.loadError ?? "?")")
        }
        return (c, bundle)
    }

    /// Ticks at 30 Hz from `now` until the ride stops or `maxSec` passes.
    @MainActor
    @discardableResult
    private func ride(_ c: CourseRideController, now: inout CFTimeInterval, maxSec: Double,
                      each: (() -> Void)? = nil) -> Int {
        var ticks = 0
        while c.phase == .riding, Double(ticks) < maxSec * 30 {
            now += 1.0 / 30
            c.tick(now: now)
            each?()
            ticks += 1
        }
        return ticks
    }

    /// Ticks at 30 Hz on trainer power, each tick a trainer notification
    /// (which runs the physics step) as on a real ride, until the ride stops,
    /// `maxSec` passes or `until` holds.
    @MainActor
    @discardableResult
    private func trainerRide(_ c: CourseRideController, watts: Int, cadence: Int = 85,
                             now: inout CFTimeInterval, maxSec: Double,
                             until stop: (() -> Bool)? = nil, each: (() -> Void)? = nil) -> Int {
        var ticks = 0
        while c.phase == .riding, Double(ticks) < maxSec * 30, !(stop?() ?? false) {
            now += 1.0 / 30
            c.handleTrainerData(TrainerData(power: watts, cadence: cadence), now: now)
            each?()
            ticks += 1
        }
        return ticks
    }

    @MainActor
    private func connectTrainer(_ c: CourseRideController, now: CFTimeInterval, control: Bool = true) {
        c.handleTrainerLink(true, now: now)
        if control { c.handleTrainerControl(true, now: now) }
    }

    private func memoryContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: RideSessionModel.self, ScheduledRideModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @MainActor
    func test_fullRide_timesClimb_PBStoredOnSave_savesOnce_thenSlowerRideTrailsPB() async throws {
        let saved = SavedPB(courseID)
        defer { saved.restore() }
        AppSettings.clearPersonalBest(courseID: courseID)

        let (c, bundle) = try await loadedController()
        XCTAssertNil(c.personalBestSec)
        var now: CFTimeInterval = 1000
        connectTrainer(c, now: now)
        let startedAfter = Date()
        c.beginRiding(now: now)
        let startedBefore = Date()
        XCTAssertEqual(c.phase, .riding)
        XCTAssertFalse(c.usingVirtualPower)
        XCTAssertTrue(c.trainerConnected)
        XCTAssertTrue(c.trainerControlGranted)

        var lastS = 0.0
        var wentBackwards = false
        trainerRide(c, watts: 300, now: &now, maxSec: 900) {
            let snap = c.stateBox.read()
            if snap.s < lastS { wentBackwards = true }
            lastS = snap.s
            if c.distanceM < bundle.climb.startS - 1 { XCTAssertNil(c.climbElapsedSec) }
            XCTAssertNil(c.pbDeltaSec, "no PB yet")
        }
        XCTAssertFalse(wentBackwards)
        XCTAssertEqual(c.phase, .finished)
        XCTAssertFalse(c.stateBox.read().isRunning)

        let r = try XCTUnwrap(c.result)
        XCTAssertTrue(r.completed)
        XCTAssertTrue(r.isPersonalBest, "first ascent is a PB")
        XCTAssertNil(r.previousBestSec)
        let climbTime = try XCTUnwrap(r.climbTimeSec)
        // 570 m at 11.3 % on ~300 W: roughly 3–4 minutes.
        XCTAssertGreaterThan(climbTime, 150)
        XCTAssertLessThan(climbTime, 300)
        XCTAssertEqual(r.climbAvgPowerW, 300)
        XCTAssertEqual(r.avgPowerW, 300)
        XCTAssertEqual(r.distanceM, bundle.route.length, accuracy: 0.01)
        XCTAssertGreaterThan(r.elevationGainM, 64)
        XCTAssertEqual(r.climbAvgSpeedKph ?? 0, bundle.climb.lengthM / climbTime * 3.6, accuracy: 1e-9)
        XCTAssertEqual(c.climbProgress, 1)
        XCTAssertEqual(c.distanceToSummitM, 0)
        XCTAssertFalse(c.climbUsedVirtualPower)

        // Not a PB until the ride is in History.
        XCTAssertNil(AppSettings.personalBestSeconds(courseID: courseID))

        // Saving twice gives one History row.
        let context = try memoryContext()
        let model = try XCTUnwrap(c.saveRide(context: context))

        // Saved, the PB is stored with its 10 m splits and the ride it came from.
        XCTAssertEqual(AppSettings.personalBestSeconds(courseID: courseID) ?? -1, climbTime, accuracy: 1e-9)
        let splits = try XCTUnwrap(AppSettings.personalBestSplits(courseID: courseID))
        XCTAssertEqual(splits.count, ClimbTimer.splitDistances(lengthM: bundle.climb.lengthM, spacingM: 10).count)
        XCTAssertEqual(splits.last ?? -1, climbTime, accuracy: 1e-9)
        XCTAssertEqual(AppSettings.personalBestSessionID(courseID: courseID), model.id)
        // History dates the ride from its start, not from the save.
        XCTAssertGreaterThanOrEqual(model.date, startedAfter)
        XCTAssertLessThanOrEqual(model.date, startedBefore)
        XCTAssertTrue(c.saveRide(context: context) === model)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RideSessionModel>()).count, 1)
        XCTAssertEqual(model.workoutId, "course_koppenberg")
        XCTAssertEqual(model.workoutName, bundle.name)
        XCTAssertEqual(model.category, "Climb")
        XCTAssertFalse(model.partial)
        XCTAssertEqual(model.avgPower, 300)
        XCTAssertEqual(model.durationSec, r.totalTimeSec)
        XCTAssertEqual(model.sampleInterval, 1)
        XCTAssertGreaterThan(model.np, 0)
        XCTAssertGreaterThan(model.tss, 0)
        let samples = try XCTUnwrap(model.samples)
        XCTAssertEqual(Double(samples.power.count), Double(r.totalTimeSec), accuracy: 1)
        XCTAssertEqual(samples.distanceM?.count, samples.power.count)
        XCTAssertEqual(samples.altitudeM?.count, samples.power.count)
        XCTAssertEqual(samples.speedMps?.count, samples.power.count)
        XCTAssertEqual(samples.distanceM?.last ?? 0, bundle.route.length, accuracy: 0.1)
        XCTAssertEqual(samples.climbOnVirtualPower, false)
        // History works out about the same climb time from the samples.
        let fromSamples = try XCTUnwrap(CourseRideRecorder.climbTiming(
            samples: samples, interval: model.sampleInterval,
            startS: bundle.climb.startS, endS: bundle.climb.endS))
        XCTAssertEqual(fromSamples.seconds, climbTime, accuracy: 0.5)
        XCTAssertEqual(fromSamples.splits.count, splits.count)

        // A slower second ride trails the new PB.
        c.discard()
        XCTAssertEqual(c.phase, .ready)
        XCTAssertNil(c.result)
        XCTAssertEqual(c.personalBestSec ?? -1, climbTime, accuracy: 1e-9)
        c.beginRiding(now: now)
        XCTAssertEqual(c.personalBestSec ?? -1, climbTime, accuracy: 1e-9)
        var sawDelta = false
        trainerRide(c, watts: 250, now: &now, maxSec: 900) {
            if c.distanceM < bundle.climb.startS - 1 { XCTAssertNil(c.pbDeltaSec) }
            if c.pbDeltaSec != nil { sawDelta = true }
        }
        XCTAssertTrue(sawDelta)
        let r2 = try XCTUnwrap(c.result)
        let climbTime2 = try XCTUnwrap(r2.climbTimeSec)
        XCTAssertGreaterThan(climbTime2, climbTime)
        XCTAssertFalse(r2.isPersonalBest)
        XCTAssertEqual(r2.previousBestSec ?? -1, climbTime, accuracy: 1e-9)
        XCTAssertEqual(c.pbDeltaSec ?? -999, climbTime2 - climbTime, accuracy: 1e-6)
        // Saving the slower ride doesn't overwrite the PB.
        let model2 = try XCTUnwrap(c.saveRide(context: context))
        XCTAssertEqual(AppSettings.personalBestSeconds(courseID: courseID) ?? -1, climbTime, accuracy: 1e-9)
        XCTAssertEqual(AppSettings.personalBestSessionID(courseID: courseID), model.id)

        // Deleting the PB ride from History falls back to the other one.
        CourseRideRecorder.recomputePersonalBest(courseID: courseID, from: [model, model2])
        XCTAssertEqual(AppSettings.personalBestSeconds(courseID: courseID) ?? -1, climbTime, accuracy: 1e-9)
        CourseRideRecorder.recomputePersonalBest(courseID: courseID, from: [model2])
        XCTAssertEqual(AppSettings.personalBestSeconds(courseID: courseID) ?? -1, climbTime2, accuracy: 0.5)
        XCTAssertEqual(AppSettings.personalBestSessionID(courseID: courseID), model2.id)
        c.reset()
        XCTAssertEqual(c.phase, .idle)
        XCTAssertNil(c.bundle)
    }

    @MainActor
    func test_discardAfterTheSummit_leavesThePBAsItWas() async throws {
        let saved = SavedPB(courseID)
        defer { saved.restore() }
        AppSettings.clearPersonalBest(courseID: courseID)
        AppSettings.setPersonalBestSeconds(900, courseID: courseID)

        let (c, _) = try await loadedController()
        XCTAssertEqual(c.personalBestSec, 900)
        var now: CFTimeInterval = 1000
        connectTrainer(c, now: now)
        c.beginRiding(now: now)
        trainerRide(c, watts: 300, now: &now, maxSec: 900, until: { c.climbProgress >= 1 })
        XCTAssertEqual(c.phase, .riding, "past the summit, short of the route end")
        c.finishEarly()
        let r = try XCTUnwrap(c.result)
        XCTAssertNotNil(r.climbTimeSec)
        XCTAssertTrue(r.isPersonalBest)

        c.discard()
        XCTAssertEqual(AppSettings.personalBestSeconds(courseID: courseID), 900)
        XCTAssertNil(AppSettings.personalBestSessionID(courseID: courseID))
        XCTAssertEqual(c.personalBestSec, 900)
        // Neither does an unsaved ride's PB survive into the next ride.
        c.beginRiding(now: now)
        XCTAssertEqual(c.personalBestSec, 900)
        c.reset()
    }

    @MainActor
    func test_savingAfterTheSummit_isACompleteClimb_andStoresThePB() async throws {
        let saved = SavedPB(courseID)
        defer { saved.restore() }
        AppSettings.clearPersonalBest(courseID: courseID)

        let (c, bundle) = try await loadedController()
        var now: CFTimeInterval = 1000
        connectTrainer(c, now: now)
        c.beginRiding(now: now)
        trainerRide(c, watts: 280, now: &now, maxSec: 900, until: { c.climbProgress >= 1 })
        XCTAssertLessThan(c.distanceM, bundle.route.length - 10)

        // Stop and save at the summit rather than riding on to the end.
        let model = try XCTUnwrap(c.saveRide(context: try memoryContext()))
        let r = try XCTUnwrap(c.result)
        XCTAssertFalse(r.completed, "the route wasn't finished")
        XCTAssertFalse(model.partial, "but the climb was")
        let climbTime = try XCTUnwrap(r.climbTimeSec)
        XCTAssertEqual(AppSettings.personalBestSeconds(courseID: courseID) ?? -1, climbTime, accuracy: 1e-9)
        c.reset()
    }

    @MainActor
    func test_climbOnVirtualPower_isNeverAPB_butStillSaves() async throws {
        let saved = SavedPB(courseID)
        defer { saved.restore() }
        AppSettings.clearPersonalBest(courseID: courseID)

        let (c, _) = try await loadedController()
        c.virtualPowerW = 600
        var now: CFTimeInterval = 1000
        c.beginRiding(now: now)
        XCTAssertTrue(c.usingVirtualPower)
        XCTAssertFalse(c.awaitingTrainer, "no trainer ever powered this ride")
        ride(c, now: &now, maxSec: 900)
        XCTAssertEqual(c.phase, .finished)
        let r = try XCTUnwrap(c.result)
        XCTAssertNotNil(r.climbTimeSec)
        XCTAssertFalse(r.isPersonalBest)
        XCTAssertTrue(c.climbUsedVirtualPower)

        let model = try XCTUnwrap(c.saveRide(context: try memoryContext()))
        XCTAssertEqual(model.samples?.climbOnVirtualPower, true)
        XCTAssertNil(AppSettings.personalBestSeconds(courseID: courseID))
        // Nor does it become one when History is recomputed.
        AppSettings.setPersonalBestSeconds(999, courseID: courseID)
        CourseRideRecorder.recomputePersonalBest(courseID: courseID, from: [model])
        XCTAssertNil(AppSettings.personalBestSeconds(courseID: courseID))
        c.reset()
    }

    @MainActor
    func test_trainerDrop_coastsOnZeroWatts_virtualPowerOnlyWhenChosen() async throws {
        let (c, _) = try await loadedController()
        var now: CFTimeInterval = 1000
        connectTrainer(c, now: now)
        c.beginRiding(now: now)
        trainerRide(c, watts: 250, now: &now, maxSec: 12)
        let speedBefore = c.stateBox.read().speedMps
        XCTAssertGreaterThan(speedBefore, 5)

        c.handleTrainerLink(false, now: now)
        XCTAssertFalse(c.trainerConnected)
        XCTAssertFalse(c.trainerControlGranted)
        XCTAssertTrue(c.awaitingTrainer)
        XCTAssertTrue(c.usingVirtualPower, "the virtual control is offered")
        // No invented power: the rider coasts and slows.
        ride(c, now: &now, maxSec: 8)
        XCTAssertEqual(c.powerW, 0)
        XCTAssertEqual(c.cadenceRpm, 0)
        XCTAssertLessThan(c.stateBox.read().speedMps, speedBefore - 0.5)
        XCTAssertFalse(c.climbUsedVirtualPower)

        // Using the control is choosing virtual power, and then this climb
        // can't be a PB.
        c.virtualPowerW = 220
        XCTAssertFalse(c.awaitingTrainer)
        ride(c, now: &now, maxSec: 4)
        XCTAssertEqual(c.powerW, 220)
        XCTAssertTrue(c.climbUsedVirtualPower)

        // The trainer is back and takes over again.
        connectTrainer(c, now: now)
        trainerRide(c, watts: 260, now: &now, maxSec: 4)
        XCTAssertEqual(c.powerW, 260)
        XCTAssertFalse(c.usingVirtualPower)
        // A second drop coasts again.
        c.handleTrainerLink(false, now: now)
        XCTAssertTrue(c.awaitingTrainer)
        XCTAssertNil(c.climbElapsedSec, "all before the climb")

        let model = try XCTUnwrap(c.saveRide(context: try memoryContext()))
        let power = try XCTUnwrap(model.samples?.power)
        XCTAssertGreaterThanOrEqual(power.filter { $0 == 0 }.count, 7, "the coast is recorded as 0 W")
        c.reset()
    }

    /// trn-4 and the data-timeout half of the dropout: a trainer another app
    /// controls powers the ride without taking gradients, and when its
    /// readings stop the rider coasts.
    @MainActor
    func test_trainerWithoutControl_isNotGranted_andSilenceCoasts() async throws {
        let (c, _) = try await loadedController()
        var now: CFTimeInterval = 1000
        connectTrainer(c, now: now, control: false)
        c.handleTrainerData(TrainerData(power: 240, cadence: 88), now: now)
        XCTAssertTrue(c.trainerConnected)
        XCTAssertFalse(c.trainerControlGranted)
        c.beginRiding(now: now)
        trainerRide(c, watts: 240, cadence: 88, now: &now, maxSec: 5)
        XCTAssertEqual(c.powerW, 240)

        // Readings stop with the link still up: 3 s later they count as gone.
        ride(c, now: &now, maxSec: 8)
        XCTAssertFalse(c.trainerConnected)
        XCTAssertTrue(c.awaitingTrainer)
        XCTAssertEqual(c.powerW, 0)

        c.handleTrainerControl(true, now: now)
        XCTAssertTrue(c.trainerControlGranted)
        XCTAssertTrue(c.trainerConnected)
        c.reset()
    }

    /// A trainer that refuses the gradient shows why on the HUD until it
    /// takes one again or drops.
    @MainActor
    func test_refusedGradient_isReported_untilAcceptedOrDisconnected() async throws {
        let (c, _) = try await loadedController()
        XCTAssertNil(c.trainerSlopeRefusal)
        c.handleSlopeReply(.refused(code: 0x05))
        XCTAssertEqual(c.trainerSlopeRefusal, "no control")
        c.handleSlopeReply(.refused(code: 0x02))
        XCTAssertEqual(c.trainerSlopeRefusal, "not supported")
        c.handleSlopeReply(.accepted)
        XCTAssertNil(c.trainerSlopeRefusal)
        c.handleSlopeReply(.refused(code: 0x04))
        c.handleSlopeReply(.none)
        XCTAssertNil(c.trainerSlopeRefusal)
        c.reset()
    }

    /// trn-6: a trainer that sends power and cadence in separate
    /// notifications keeps its power rather than halving it.
    @MainActor
    func test_splitTrainerNotifications_keepTheLastPower() async throws {
        let (c, _) = try await loadedController()
        var now: CFTimeInterval = 1000
        connectTrainer(c, now: now)
        c.beginRiding(now: now)
        for i in 0..<(10 * 30) {
            now += 1.0 / 30
            if i % 2 == 0 {
                c.handleTrainerData(TrainerData(power: 280), now: now)
            } else {
                c.handleTrainerData(TrainerData(cadence: 92, heartRate: 150), now: now)
                c.tick(now: now)
            }
        }
        XCTAssertEqual(c.avgPowerW, 280)
        XCTAssertEqual(c.powerW, 280)
        XCTAssertEqual(c.cadenceRpm, 92)
        XCTAssertEqual(c.heartRate, 150)
        c.reset()
    }

    /// trn-1: an ERG workout counting down, running or paused holds the
    /// trainer, and leaving its countdown never starts it.
    @MainActor
    func test_workoutCountdown_holdsTheTrainer_andLeavingItNeverStartsTheWorkout() async throws {
        let (c, _) = try await loadedController()
        let workout = Workout(id: "t", name: "T", description: "", category: .endurance,
                              intervals: [.steady(name: "easy", duration: 600, powerPercent: 50)])
        let erg = RideController()
        erg.countdownStepNanoseconds = 20_000_000

        for leaveBySaving in [false, true] {
            erg.select(workout)
            let countdown = Task { await erg.startRide() }
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertEqual(erg.state, .countdown)

            // The course ride won't start against it.
            await c.start()
            XCTAssertEqual(c.phase, .ready)
            XCTAssertTrue(c.trainerHeldByWorkout)
            c.beginRiding(now: 1000)
            XCTAssertEqual(c.phase, .ready)

            if leaveBySaving {
                _ = erg.saveAndStop(context: try memoryContext())
            } else {
                erg.discardAndStop()
            }
            let left = erg.state
            await countdown.value
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(erg.state, left, "the countdown didn't carry on into the workout")
            XCTAssertNotEqual(erg.player.state, .running)
        }

        // Free again: the course ride starts, and then holds the trainer.
        c.beginRiding(now: 1000)
        XCTAssertEqual(c.phase, .riding)
        XCTAssertFalse(c.trainerHeldByWorkout)
        erg.select(workout)
        await erg.startRide()
        XCTAssertEqual(erg.state, .ready, "a workout won't start during a course ride")
        c.reset()
        erg.deselect()
    }

    @MainActor
    func test_debugStart_onTheSteepest_zeroPowerStaysPut_andIsNotTimed() async throws {
        let (c, _) = try await loadedController()
        c.debugStartS = 590
        // Placed there before the start, for the scene.
        XCTAssertEqual(c.stateBox.read().s, 590, accuracy: 1e-9)
        XCTAssertGreaterThan(c.gradePct, 15)
        c.virtualPowerW = 0
        var now = CACurrentMediaTime()
        c.beginRiding(now: now)
        ride(c, now: &now, maxSec: 3)
        let snap = c.stateBox.read()
        XCTAssertEqual(snap.s, 590, accuracy: 1e-9)
        XCTAssertEqual(snap.speedMps, 0)
        XCTAssertEqual(snap.lateralM, 0.6, accuracy: 1e-9, "cobbles line")
        XCTAssertNil(c.climbElapsedSec)

        c.virtualPowerW = 400
        ride(c, now: &now, maxSec: 10)
        XCTAssertGreaterThan(c.stateBox.read().s, 600)
        XCTAssertNil(c.climbElapsedSec, "started past the climb start")
        c.reset()
    }

    @MainActor
    func test_pauseFreezes_andASuspensionGapIsClamped() async throws {
        let (c, _) = try await loadedController()
        c.virtualPowerW = 250
        var now = CACurrentMediaTime()
        c.beginRiding(now: now)
        ride(c, now: &now, maxSec: 5)
        let before = c.stateBox.read()
        XCTAssertTrue(before.isRunning)
        XCTAssertGreaterThan(before.speedMps, 3)

        c.pauseOrResume()
        XCTAssertEqual(c.phase, .paused)
        XCTAssertFalse(c.stateBox.read().isRunning)
        c.tick(now: now + 30)
        XCTAssertEqual(c.stateBox.read().s, before.s, accuracy: 1e-9)
        XCTAssertEqual(c.speedKph, 0)

        c.pauseOrResume()
        XCTAssertEqual(c.phase, .riding)
        let elapsedBefore = c.elapsedSec
        let sBefore = c.stateBox.read().s
        // Ten minutes without a tick (suspended): at most 2 s are integrated.
        now = CACurrentMediaTime() + 600
        c.tick(now: now)
        XCTAssertLessThanOrEqual(c.elapsedSec - elapsedBefore, 2)
        XCTAssertLessThan(c.stateBox.read().s - sBefore, 2 * 12)
        c.reset()
    }

    @MainActor
    func test_saveMidRide_endsItAsPartial_saveBeforeRiding_isNil() async throws {
        let (c, _) = try await loadedController()
        let context = try memoryContext()
        XCTAssertNil(c.saveRide(context: context), "nothing ridden yet")

        c.virtualPowerW = 220
        var now = CACurrentMediaTime()
        c.beginRiding(now: now)
        ride(c, now: &now, maxSec: 20)
        // Whatever reacts to `.finished` already sees the result.
        var resultAtFinish: CourseRideResult?
        let watcher = c.$phase.sink { if $0 == .finished { resultAtFinish = c.result } }
        defer { watcher.cancel() }
        let model = try XCTUnwrap(c.saveRide(context: context))
        XCTAssertEqual(c.phase, .finished)
        XCTAssertNotNil(resultAtFinish)
        XCTAssertTrue(model.partial)
        let r = try XCTUnwrap(c.result)
        XCTAssertFalse(r.completed)
        XCTAssertNil(r.climbTimeSec)
        XCTAssertFalse(r.isPersonalBest)
        XCTAssertEqual(model.durationSec, 20)
        XCTAssertEqual(model.avgPower, 220)
        XCTAssertTrue(c.saveRide(context: context) === model)
        c.reset()
    }

    @MainActor
    func test_virtualCadence_followsGearing() {
        // Stopped: the cranks don't turn.
        XCTAssertEqual(CourseRideController.virtualCadence(speedMps: 0, preferredRpm: 85), 0)
        // Anywhere a gear fits, the preferred cadence.
        XCTAssertEqual(CourseRideController.virtualCadence(speedMps: 5, preferredRpm: 85), 85, accuracy: 1e-9)
        XCTAssertEqual(CourseRideController.virtualCadence(speedMps: 12, preferredRpm: 85), 85, accuracy: 1e-9)
        // 6 km/h in the 34 x 34 bottom gear: under 50 rpm.
        let steep = CourseRideController.virtualCadence(speedMps: 6 / 3.6, preferredRpm: 85)
        XCTAssertEqual(steep, 6 / 3.6 * 60 / 2.105, accuracy: 1e-9)
        XCTAssertLessThan(steep, 50)
        // Faster than 50 x 11 at 85 rpm: the legs spin up.
        XCTAssertGreaterThan(CourseRideController.virtualCadence(speedMps: 16, preferredRpm: 85), 85)
    }
}
