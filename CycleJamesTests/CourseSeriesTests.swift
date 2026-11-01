import XCTest
import SwiftData
import QuartzCore
@testable import CycleJames

/// A berg series end to end on the real Paterberg and Molenberg data: a
/// climb, the easy spin while the next course loads, the next climb, one
/// ride in History. Synthetic 30 Hz ticks, no countdown, no timer.
final class CourseSeriesTests: XCTestCase {
    private let ids = ["paterberg", "molenberg"]

    /// Keeps the Simulator's own PBs on these courses intact.
    private struct SavedPBs {
        let saved: [(id: String, seconds: Double?, splits: [Double]?, session: UUID?)]

        init(_ ids: [String]) {
            saved = ids.map {
                ($0, AppSettings.personalBestSeconds(courseID: $0), AppSettings.personalBestSplits(courseID: $0),
                 AppSettings.personalBestSessionID(courseID: $0))
            }
        }

        func restore() {
            for pb in saved {
                AppSettings.clearPersonalBest(courseID: pb.id)
                if let seconds = pb.seconds {
                    AppSettings.setPersonalBest(seconds: seconds, splits: pb.splits ?? [], courseID: pb.id, sessionID: pb.session)
                }
            }
        }
    }

    @MainActor
    private func loadedSeries(recoverySec: Double) async throws -> CourseRideController {
        let c = CourseRideController()
        await c.load(plan: CourseRidePlan(courseIDs: ids, recoverySec: recoverySec))
        guard c.phase == .ready, c.bundle != nil else {
            throw XCTSkip("course data not in the test host bundle: \(c.loadError ?? "?")")
        }
        return c
    }

    /// One trainer notification per 30 Hz tick (each runs the physics, as
    /// on a real ride) while the ride is live, until `until` holds or
    /// `maxSec` passes.
    @MainActor
    @discardableResult
    private func trainerRide(_ c: CourseRideController, watts: Int, now: inout CFTimeInterval, maxSec: Double,
                             until stop: () -> Bool = { false }, each: () -> Void = {}) -> Int {
        var ticks = 0
        while c.phase == .riding || c.phase == .recovering, Double(ticks) < maxSec * 30, !stop() {
            now += 1.0 / 30
            c.handleTrainerData(TrainerData(power: watts, cadence: 85), now: now)
            each()
            ticks += 1
        }
        return ticks
    }

    /// Plain ticks (virtual power) while live.
    @MainActor
    private func ride(_ c: CourseRideController, now: inout CFTimeInterval, maxSec: Double,
                      until stop: () -> Bool = { false }) {
        var ticks = 0
        while c.phase == .riding || c.phase == .recovering, Double(ticks) < maxSec * 30, !stop() {
            now += 1.0 / 30
            c.tick(now: now)
            ticks += 1
        }
    }

    private func memoryContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: RideSessionModel.self, ScheduledRideModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @MainActor
    func test_series_climbsBoth_spinsFlatBetween_andSavesOneRideWithBothPBs() async throws {
        let saved = SavedPBs(ids)
        defer { saved.restore() }
        ids.forEach { AppSettings.clearPersonalBest(courseID: $0) }

        let c = try await loadedSeries(recoverySec: 20)
        let first = try XCTUnwrap(c.bundle)
        XCTAssertEqual(first.id, "paterberg")
        XCTAssertEqual(c.legIndex, 0)
        XCTAssertEqual(c.nextCourseID, "molenberg")
        var now: CFTimeInterval = 1000
        c.handleTrainerLink(true, now: now)
        c.handleTrainerControl(true, now: now)
        c.beginRiding(now: now)

        // The first climb, to the end of its route.
        trainerRide(c, watts: 350, now: &now, maxSec: 900, until: { c.isRecovering })
        XCTAssertEqual(c.phase, .recovering, "a series spins after a climb rather than finishing")
        XCTAssertTrue(c.isRecovering)
        XCTAssertNil(c.result)
        XCTAssertEqual(c.legResults.count, 1)
        let leg1 = try XCTUnwrap(c.legResults.first)
        XCTAssertEqual(leg1.courseID, "paterberg")
        let time1 = try XCTUnwrap(leg1.climbTimeSec)
        XCTAssertTrue(leg1.isPersonalBest)
        XCTAssertFalse(leg1.climbOnVirtualPower)
        XCTAssertEqual(c.nextCourseID, "molenberg")
        XCTAssertEqual(c.recoveryRemainingSec, 20, accuracy: 0.2)
        // Not a PB until the ride is in History.
        XCTAssertNil(AppSettings.personalBestSeconds(courseID: "paterberg"))

        // The next course loads while the rider waits at its start, parked.
        await c.waitForNextCourse()
        XCTAssertEqual(c.bundle?.id, "molenberg")
        XCTAssertEqual(c.legIndex, 1)
        XCTAssertEqual(c.nextCourseID, "molenberg")
        XCTAssertEqual(c.distanceM, 0)
        XCTAssertFalse(c.stateBox.read().isRunning)

        // A flat road on the trainer; the spin's speed comes from its power.
        let spinStartDistance = c.rideDistanceM
        trainerRide(c, watts: 120, now: &now, maxSec: 8)
        XCTAssertEqual(c.phase, .recovering)
        XCTAssertEqual(c.trainerGradePct, 0)
        XCTAssertEqual(c.gradePct, 0)
        XCTAssertEqual(c.surfaceName, "asphalt")
        XCTAssertEqual(c.powerW, 120)
        XCTAssertGreaterThan(c.speedKph, 20, "120 W on the flat")
        XCTAssertGreaterThan(c.rideDistanceM, spinStartDistance + 40)
        XCTAssertEqual(c.recoveryRemainingSec, 12, accuracy: 0.3)

        // Spun out, but the next world isn't showing yet: hold short of the
        // 3-2-1 rather than start a climb nobody can see.
        trainerRide(c, watts: 120, now: &now, maxSec: 30)
        XCTAssertEqual(c.phase, .recovering)
        XCTAssertNil(c.recoveryCountdown)
        XCTAssertEqual(c.recoveryRemainingSec, CourseRideController.recoveryCountdownSec, accuracy: 0.1)

        // A ready call for another course changes nothing.
        c.legSceneDidBecomeReady(courseID: "paterberg")
        trainerRide(c, watts: 120, now: &now, maxSec: 5)
        XCTAssertNil(c.recoveryCountdown)

        // Its world shows: 3, 2, 1 and away at the spin's speed.
        c.legSceneDidBecomeReady(courseID: "molenberg")
        var counted: [Int] = []
        trainerRide(c, watts: 120, now: &now, maxSec: 5, until: { c.phase == .riding }) {
            if let n = c.recoveryCountdown, counted.last != n { counted.append(n) }
        }
        XCTAssertEqual(counted, [3, 2, 1])
        XCTAssertEqual(c.phase, .riding)
        XCTAssertFalse(c.isRecovering)
        XCTAssertNil(c.recoveryCountdown)
        XCTAssertGreaterThan(c.stateBox.read().speedMps, 5, "rolls on at the spin's speed")
        XCTAssertLessThan(c.distanceM, 1)
        let spunM = c.rideDistanceM - first.route.length

        // The second climb, to the end.
        let second = try XCTUnwrap(c.bundle)
        trainerRide(c, watts: 350, now: &now, maxSec: 900)
        XCTAssertEqual(c.phase, .finished)
        let r = try XCTUnwrap(c.result)
        XCTAssertTrue(r.completed)
        XCTAssertEqual(r.legs.count, 2)
        XCTAssertEqual(r.legs.map(\.courseID), ids)
        let time2 = try XCTUnwrap(r.legs[1].climbTimeSec)
        XCTAssertTrue(r.legs[1].isPersonalBest)
        XCTAssertTrue(r.isPersonalBest)
        XCTAssertEqual(r.distanceM, first.route.length + spunM + second.route.length, accuracy: 0.5)
        XCTAssertGreaterThan(Double(r.totalTimeSec), time1 + time2 + 20)

        // One History ride, both climbs in it, both PBs from it.
        let context = try memoryContext()
        let model = try XCTUnwrap(c.saveRide(context: context))
        XCTAssertEqual(model.workoutId, BergSeries.workoutID)
        XCTAssertEqual(model.workoutName, BergSeries.name(legCount: 2))
        XCTAssertEqual(model.category, "Climb")
        XCTAssertFalse(model.partial)
        XCTAssertNil(ClimbHistorySection.courseID(of: model), "not mistaken for one course")
        XCTAssertEqual(AppSettings.personalBestSeconds(courseID: "paterberg") ?? -1, time1, accuracy: 1e-9)
        XCTAssertEqual(AppSettings.personalBestSeconds(courseID: "molenberg") ?? -1, time2, accuracy: 1e-9)
        XCTAssertEqual(AppSettings.personalBestSessionID(courseID: "paterberg"), model.id)
        XCTAssertEqual(AppSettings.personalBestSessionID(courseID: "molenberg"), model.id)

        let samples = try XCTUnwrap(model.samples)
        let dist = try XCTUnwrap(samples.distanceM)
        XCTAssertEqual(zip(dist, dist.dropFirst()).filter { $1 < $0 - 1e-6 }.count, 0, "ride distance only rises")
        XCTAssertEqual(dist.last ?? 0, first.route.length + spunM + second.route.length, accuracy: 0.5)
        let segments = try XCTUnwrap(samples.segments)
        XCTAssertEqual(segments.map(\.courseID), ids)
        XCTAssertEqual(segments[0].offsetM, 0)
        XCTAssertEqual(segments[1].offsetM, first.route.length + spunM, accuracy: 0.01)
        XCTAssertEqual(segments.map(\.climbOnVirtualPower), [false, false])

        // History times each climb from the samples as the ride did.
        let legs = CourseRideRecorder.courseLegs(workoutID: model.workoutId, samples: samples)
        XCTAssertEqual(legs.map(\.courseID), ids)
        for (leg, (bundle, time)) in zip(legs, [(first, time1), (second, time2)]) {
            let timing = try XCTUnwrap(CourseRideRecorder.climbTiming(
                samples: leg.samples, interval: model.sampleInterval,
                startS: bundle.climb.startS, endS: bundle.climb.endS))
            XCTAssertEqual(timing.seconds, time, accuracy: 0.5, leg.courseID)
        }

        // A PB from a ride since deleted falls back to the series' climb.
        AppSettings.setPersonalBest(seconds: 1, splits: [], courseID: "molenberg", sessionID: UUID())
        CourseRideRecorder.recomputePersonalBest(courseID: "molenberg", from: [model])
        XCTAssertEqual(AppSettings.personalBestSeconds(courseID: "molenberg") ?? -1, time2, accuracy: 0.5)
        XCTAssertEqual(AppSettings.personalBestSessionID(courseID: "molenberg"), model.id)
        // Deleting the series takes both PBs with it.
        RideHistory.delete(model, in: context)
        XCTAssertNil(AppSettings.personalBestSeconds(courseID: "paterberg"))
        XCTAssertNil(AppSettings.personalBestSeconds(courseID: "molenberg"))
        c.reset()
        XCTAssertEqual(c.phase, .idle)
        XCTAssertNil(c.bundle)
        XCTAssertTrue(c.legResults.isEmpty)
    }

    @MainActor
    func test_spin_pausesAndResumes_extends_andStartsNowAfterTheCountdown() async throws {
        let c = try await loadedSeries(recoverySec: 30)
        let first = try XCTUnwrap(c.bundle)
        c.debugStartS = first.route.length - 40
        c.virtualPowerW = 250
        var now: CFTimeInterval = 1000
        c.beginRiding(now: now)
        ride(c, now: &now, maxSec: 60, until: { c.isRecovering })
        XCTAssertEqual(c.phase, .recovering)
        XCTAssertNil(c.legResults.first?.climbTimeSec, "started past the climb: not timed")
        await c.waitForNextCourse()
        c.legSceneDidBecomeReady(courseID: "molenberg")

        // A pause holds the spin's clock and comes back to the spin.
        ride(c, now: &now, maxSec: 2)
        XCTAssertGreaterThan(c.cadenceRpm, 60, "the virtual rider pedals on the spin")
        c.pauseOrResume(now: now)
        XCTAssertEqual(c.phase, .paused)
        XCTAssertTrue(c.isRecovering)
        let held = c.recoveryRemainingSec
        for _ in 0..<90 { now += 1.0 / 30; c.tick(now: now) }
        XCTAssertEqual(c.recoveryRemainingSec, held, accuracy: 1e-9)
        c.pauseOrResume(now: now)
        XCTAssertEqual(c.phase, .recovering)

        // A minute more, then straight on after the 3-2-1.
        let before = c.recoveryRemainingSec
        c.extendRecovery()
        XCTAssertEqual(c.recoveryRemainingSec, before + 60, accuracy: 0.05)
        c.skipRecovery()
        XCTAssertEqual(c.recoveryRemainingSec, CourseRideController.recoveryCountdownSec, accuracy: 0.05)
        ride(c, now: &now, maxSec: 3.3)
        XCTAssertEqual(c.phase, .riding)
        XCTAssertEqual(c.bundle?.id, "molenberg")
        // Virtual power on the spin is the way to this climb: no PB on it.
        XCTAssertTrue(c.climbUsedVirtualPower)

        // Stopped before the second summit: a partial series with both
        // courses in its samples.
        ride(c, now: &now, maxSec: 20)
        c.finishEarly()
        let r = try XCTUnwrap(c.result)
        XCTAssertFalse(r.completed)
        XCTAssertEqual(r.legs.map(\.courseID), ids)
        XCTAssertNil(r.legs[1].climbTimeSec)
        let model = try XCTUnwrap(c.saveRide(context: try memoryContext()))
        XCTAssertTrue(model.partial)
        XCTAssertEqual(model.samples?.segments?.map(\.courseID), ids)
        XCTAssertEqual(model.samples?.segments?.map(\.climbOnVirtualPower), [true, true])
        c.reset()
    }

    @MainActor
    func test_stoppingInTheSpin_keepsTheClimbsDone() async throws {
        let c = try await loadedSeries(recoverySec: 60)
        let first = try XCTUnwrap(c.bundle)
        c.virtualPowerW = 400
        var now: CFTimeInterval = 1000
        c.beginRiding(now: now)
        ride(c, now: &now, maxSec: 900, until: { c.isRecovering })
        XCTAssertEqual(c.phase, .recovering)
        await c.waitForNextCourse()
        ride(c, now: &now, maxSec: 10)
        c.finishEarly()
        XCTAssertEqual(c.phase, .finished)
        let r = try XCTUnwrap(c.result)
        XCTAssertEqual(r.legs.count, 1)
        XCTAssertNotNil(r.climbTimeSec, "the climb behind the spin")
        XCTAssertGreaterThan(r.distanceM, first.route.length + 50, "the spin counts as riding")
        let model = try XCTUnwrap(c.saveRide(context: try memoryContext()))
        XCTAssertTrue(model.partial, "one climb of two")
        XCTAssertEqual(model.samples?.segments?.map(\.courseID), ["paterberg"])
        c.reset()
    }

    @MainActor
    func test_discardingASeriesAfterItsFirstClimb_startsOverFromIt() async throws {
        let c = try await loadedSeries(recoverySec: 10)
        let first = try XCTUnwrap(c.bundle)
        c.debugStartS = first.route.length - 20
        var now: CFTimeInterval = 1000
        c.beginRiding(now: now)
        ride(c, now: &now, maxSec: 30, until: { c.isRecovering })
        await c.waitForNextCourse()
        XCTAssertEqual(c.bundle?.id, "molenberg")
        c.discard()
        for _ in 0..<300 where c.phase != .ready || c.bundle?.id != "paterberg" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(c.bundle?.id, "paterberg")
        XCTAssertEqual(c.legIndex, 0)
        XCTAssertTrue(c.legResults.isEmpty)
        c.reset()
    }

    func test_plan_keepsRaceOrder_needsTwoClimbs() throws {
        let all = BergSeries.availableIDs
        XCTAssertEqual(all, BergSeries.order.filter(CourseCatalog.courseIDs.contains))
        XCTAssertEqual(all.count, 6, "the six Flemish bergs")
        XCTAssertTrue(Set(all).isSubset(of: CourseCatalog.courseIDs), "only shipped courses")
        let plan = try XCTUnwrap(BergSeries.plan(excluding: ["oudekwaremont", "muur"], recoveryMin: 2))
        XCTAssertEqual(plan.courseIDs, ["molenberg", "paterberg", "koppenberg", "taaienberg"])
        XCTAssertEqual(plan.recoverySec, 120)
        XCTAssertNil(BergSeries.plan(excluding: Set(all.dropFirst()), recoveryMin: 3), "one climb isn't a series")
        XCTAssertFalse(CourseRidePlan.single("koppenberg").isSeries)
        XCTAssertFalse(BergSeries.workoutID.hasPrefix(CourseRideController.workoutIDPrefix))
    }
}
