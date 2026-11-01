import Foundation
import SwiftUI
import SwiftData
import QuartzCore
import Combine

/// Outcome of a course ride, shown on the finish screen.
struct CourseRideResult: Equatable, Sendable {
    /// Time from crossing the climb start to the summit; nil if not reached.
    let climbTimeSec: Double?
    let totalTimeSec: Int
    /// Distance ridden (from where the ride started), metres.
    let distanceM: Double
    let avgPowerW: Int
    let climbAvgPowerW: Int?
    let previousBestSec: Double?
    let isPersonalBest: Bool
    /// True when the rider reached the end of the route.
    let completed: Bool
    /// Sum of all climbing on the ride, metres.
    var elevationGainM: Double = 0
    /// Average speed from the climb start to the summit; nil if not reached.
    var climbAvgSpeedKph: Double? = nil
    /// Every climb ridden, in order (one for a single course).
    var legs: [CourseLegResult] = []
}

/// One climb of a ride, for the series' recovery card and finish screen.
struct CourseLegResult: Equatable, Sendable {
    let courseID: String
    let name: String
    /// Start to summit; nil when the summit wasn't reached.
    let climbTimeSec: Double?
    let previousBestSec: Double?
    let isPersonalBest: Bool
    let climbAvgPowerW: Int?
    /// Virtual power on the climb or on the way to it: no PB.
    let climbOnVirtualPower: Bool
}

/// Runs one 3D course ride: load → countdown → riding ⇄ paused → finished.
/// A berg series (`CourseRidePlan` with several courses) recovers between
/// climbs: riding → recovering (an easy spin on a flat road while the next
/// course loads) → riding the next course, as one ride for History.
///
/// A 30 Hz timer integrates `RidePhysics` with the rider's power (the
/// trainer's when one is connected, `virtualPowerW` otherwise), hands the
/// result to the 3D view through `stateBox` every tick and refreshes the
/// published HUD values at ~5 Hz. `TrainerSimBridge` feeds the gradient
/// ahead to the trainer; `ClimbTimer` times the climb against the personal
/// best; `CourseRideRecorder` keeps per-second samples for History.
@MainActor
final class CourseRideController: ObservableObject {
    enum Phase: Equatable { case idle, loading, ready, countdown, riding, recovering, paused, finished }

    @Published private(set) var phase: Phase = .idle {
        didSet { syncTrainerClaim() }
    }
    @Published private(set) var bundle: CourseBundle?
    /// What this ride climbs; set by `load`.
    @Published private(set) var plan: CourseRidePlan?
    /// Which of the plan's courses `bundle` is.
    @Published private(set) var legIndex = 0
    /// Climbs finished (or stopped on) so far, in order.
    @Published private(set) var legResults: [CourseLegResult] = []
    /// Seconds of easy spinning left before the next climb; 0 outside a
    /// recovery. Held at the countdown while the next course loads.
    @Published private(set) var recoveryRemainingSec: Double = 0
    /// 3, 2, 1 over the last seconds of a recovery; nil otherwise.
    @Published private(set) var recoveryCountdown: Int?
    /// Distance ridden since the start, every climb and spin included.
    @Published private(set) var rideDistanceM: Double = 0
    @Published private(set) var loadError: String?
    @Published private(set) var countdownNumber: Int = 3

    // Live values for the HUD, refreshed at ~5 Hz.
    @Published private(set) var distanceM: Double = 0
    @Published private(set) var speedKph: Double = 0
    /// 3-second rolling average.
    @Published private(set) var powerW: Int = 0
    @Published private(set) var cadenceRpm: Int = 0
    @Published private(set) var heartRate: Int = 0
    @Published private(set) var gradePct: Double = 0
    @Published private(set) var elevationM: Double = 0
    @Published private(set) var elevationGainM: Double = 0
    @Published private(set) var elapsedSec: Int = 0
    /// Seconds since crossing the climb start; nil before it.
    @Published private(set) var climbElapsedSec: Double?
    /// Metres to the summit; 0 once past it.
    @Published private(set) var distanceToSummitM: Double = 0
    @Published private(set) var surfaceName: String = "asphalt"
    @Published private(set) var wattsPerKg: Double = 0
    @Published private(set) var result: CourseRideResult?
    /// 0 at the climb start, 1 at the summit.
    @Published private(set) var climbProgress: Double = 0
    /// Best climb time for this course before this ride, loaded with it.
    /// A new one is stored only when the ride is saved.
    @Published private(set) var personalBestSec: Double?
    /// Climb time so far minus the personal-best run's time at the same
    /// distance; negative is ahead. Nil without a PB or before the climb.
    @Published private(set) var pbDeltaSec: Double?
    /// True while power and cadence come from a connected trainer.
    @Published private(set) var trainerConnected: Bool = false
    /// True while the trainer has granted this app control, so the
    /// gradient reaches it. A trainer another app controls (or whose grant
    /// was missed) still powers the ride but feels like a flat road.
    @Published private(set) var trainerControlGranted: Bool = false
    /// Gradient the trainer last took, after the difficulty setting.
    /// Meaningful only while `trainerControlGranted`.
    @Published private(set) var trainerGradePct: Double = 0
    /// Why the trainer refused the last gradient it was sent ("no
    /// control", "not supported", …), or nil when it took it or hasn't
    /// answered. A refused gradient leaves the trainer in its previous
    /// mode, where its gears may do nothing.
    @Published private(set) var trainerSlopeRefusal: String?
    /// The trainer that powered this ride dropped (link lost or readings
    /// stopped): power is 0 and the rider coasts until it's back, unless
    /// they take up the virtual power control (`useVirtualPower()`).
    @Published private(set) var awaitingTrainer: Bool = false
    /// Virtual power was used before the summit (on the climb or on the way
    /// to it, which sets the speed it starts at), so the climb can't be a
    /// personal best.
    @Published private(set) var climbUsedVirtualPower: Bool = false
    /// `start()` was refused because a workout is counting down, running
    /// or paused and holds the trainer.
    @Published private(set) var trainerHeldByWorkout: Bool = false
    /// Average power over the ride so far (moving time).
    @Published private(set) var avgPowerW: Int = 0
    /// The trainer's gear and its last shift (direction, run length, time),
    /// for the HUD's gear badge. Unavailable, so hidden, unless the trainer
    /// reports gears (a Wattbike). It belongs to the bike, not the ride, so
    /// starting, discarding or resetting a ride leaves it alone.
    let gears = GearFeed()

    /// Between climbs of a series, or paused there.
    var isRecovering: Bool { phase == .recovering || (phase == .paused && pausedFrom == .recovering) }

    /// The course after this recovery (or after the current climb).
    var nextCourseID: String? {
        guard let plan else { return nil }
        let next = isRecovering ? legResults.count : legIndex + 1
        return plan.courseIDs.indices.contains(next) ? plan.courseIDs[next] : nil
    }

    /// Development only: distance along the route at which `start()`
    /// places the rider, for screenshots of later parts of the course.
    var debugStartS: Double = 0 {
        didSet { if phase == .ready { resetRide(now: CACurrentMediaTime()) } }
    }

    /// Power used when no trainer is connected (and in the Simulator).
    @Published var virtualPowerW: Int = 200 {
        // Touching the control after a trainer drop is the rider choosing
        // to carry on with virtual power.
        didSet { if awaitingTrainer, virtualPowerW != oldValue { useVirtualPower() } }
    }
    /// The cadence the virtual rider shifts gear to hold; on ramps too steep
    /// for the bottom gear it drops with the speed (`virtualCadence`).
    @Published var virtualCadenceRpm: Int = 85
    /// True while no trainer powers the ride, so the HUD offers the virtual
    /// power control. Power comes from `virtualPowerW` then, except after a
    /// trainer drop (`awaitingTrainer`).
    @Published private(set) var usingVirtualPower: Bool = true

    /// Read by the 3D view every frame.
    let stateBox = RideStateBox()

    /// History rows for course rides use `"course_<course id>"`.
    static let workoutIDPrefix = "course_"
    static func workoutID(courseID: String) -> String { workoutIDPrefix + courseID }

    // MARK: Tuning

    private static let tickInterval = 1.0 / 30
    /// Longest stretch integrated in one tick. A longer gap means the app
    /// was suspended with nothing to wake it; that time is dropped (as if
    /// paused) rather than flinging the rider down the road.
    private static let maxTickDt = 2.0
    private static let livePublishInterval = 0.2
    /// Trainer readings older than this count as no power (link dropped
    /// or the trainer went quiet).
    private static let trainerDataTimeout = 3.0
    /// Riding line, metres right of the centreline: near the middle on
    /// asphalt, the smoother edge on cobbles.
    private static let lateralAsphaltM = 0.4
    private static let lateralRoughM = 0.6

    /// Asphalt and concrete are ridden on the asphalt line, but on a road
    /// wide enough for painted lines (6 m, see `RoadBuilder.buildMarkings`)
    /// in the middle of the right-hand lane, inside its edge line.
    static func ridingLine(surface: String, width: Double) -> Double {
        guard surface == "asphalt" || surface == "concrete" else { return lateralRoughM }
        guard surface == "asphalt", width >= 6 else { return lateralAsphaltM }
        let half = width / 2
        return (half - (half >= 4.5 ? 1.45 : 0.35)) / 2
    }
    private static let lateralDriftMps = 0.15
    /// The last seconds of a recovery count down to the next climb.
    static let recoveryCountdownSec = 3.0
    /// Rolling resistance of the flat road ridden between climbs.
    private static let recoveryCrr = 0.004

    // MARK: Inputs

    private weak var trainer: FTMSManager?
    private weak var hr: HRManager?
    private var cancellables = Set<AnyCancellable>()
    private var trainerLinkUp = false
    private var trainerInControl = false
    private var trainerPower = 0
    private var trainerCadence = 0
    private var trainerHR = 0
    private var lastTrainerDataTime: CFTimeInterval = -.infinity
    private var hrmConnected = false
    private var hrmBPM = 0

    // MARK: Ride state

    private let bridge = TrainerSimBridge()
    private let recorder = CourseRideRecorder()
    private var timer: Timer?
    private var loadGeneration = 0
    private var countdownGeneration = 0
    private var params = RidePhysics.Parameters(massKg: AppSettings.defaultRiderWeightKg + AppSettings.defaultBikeWeightKg)
    private var physics = RidePhysics.State(distanceM: 0, speedMps: 0)
    private var rideStartS: Double = 0
    private var lastTick: CFTimeInterval = 0
    private var lastLivePublish: CFTimeInterval = -.infinity
    /// Moving time, seconds.
    private var elapsed: Double = 0
    private var workJ: Double = 0
    private var gainM: Double = 0
    private var rolling = RollingAverage(windowSec: 3)
    private var instantPower: Double = 0
    private var instantCadence: Double = 0
    private var lateralM = lateralAsphaltM
    private var peakPower = 0
    private var peakCadence = 0
    private var peakHR = 0
    private var climb: ClimbTimer?
    private var pbSplits: [Double]?
    private var summitWasPB = false
    /// This ride's PBs by course, written to `AppSettings` only when the
    /// ride is saved.
    private var pendingPBs: [String: (seconds: Double, splits: [Double])] = [:]
    private var savedModel: RideSessionModel?
    /// Wall-clock start, for History and exports.
    private var rideStartDate = Date()
    /// A trainer has powered this ride, so losing it coasts on 0 W rather
    /// than switching to virtual power.
    private var hadTrainerThisRide = false
    /// The rider chose virtual power after the trainer dropped.
    private var virtualPowerOptIn = false
    /// The phase a pause returns to.
    private var pausedFrom: Phase = .riding

    // MARK: Series state

    /// Ride distance at the current course's `s` = 0: along the whole ride,
    /// so the recorded distance keeps rising from one climb to the next.
    private var legOffsetM: Double = 0
    /// Where the first course was started (`rideStartS` of leg 0).
    private var firstLegStartS: Double = 0
    /// Each course's start in ride distance, for the saved samples.
    private var legStarts: [(courseID: String, offsetM: Double)] = []
    /// The current leg is in `legResults`.
    private var legRecorded = false
    /// The flat road between climbs: distance from where the spin began.
    private var recovery = RidePhysics.State(distanceM: 0, speedMps: 0)
    private var recoveryBaseM: Double = 0
    private var recoveryEndElapsed: Double = 0
    private var recoveryStartElapsed: Double = 0
    /// The recorded altitude eases from one summit down to the next start.
    private var recoveryElevation: (from: Double, to: Double) = (0, 0)
    /// The next course's world is built and showing.
    private var legSceneReady = false
    private var nextLegTask: Task<Void, Never>?

    // MARK: Setup

    /// Subscribes to the trainer and HR monitor. Never touches their
    /// `onData` / `onHR` closures, which belong to `RideController`.
    func bind(trainer: FTMSManager, hr: HRManager) {
        self.trainer = trainer
        self.hr = hr
        bridge.target = trainer
        cancellables.removeAll()

        // Skip the replayed current value: only fresh notifications count.
        trainer.$liveData.dropFirst()
            .sink { [weak self] data in
                MainActor.assumeIsolated { self?.handleTrainerData(data, now: CACurrentMediaTime()) }
            }
            .store(in: &cancellables)
        trainer.$connectionState
            .sink { [weak self] state in MainActor.assumeIsolated { self?.handleTrainerLink(state == .connected) } }
            .store(in: &cancellables)
        // @Published emits before the value is stored; hop a turn so the
        // trainer already reports control when we resend.
        trainer.$hasControl
            .receive(on: DispatchQueue.main)
            .sink { [weak self] has in MainActor.assumeIsolated { self?.handleTrainerControl(has) } }
            .store(in: &cancellables)
        trainer.$slopeReply
            .sink { [weak self] reply in MainActor.assumeIsolated { self?.handleSlopeReply(reply) } }
            .store(in: &cancellables)
        gears.bind(trainer)
        hr.$heartRate
            .sink { [weak self] bpm in MainActor.assumeIsolated { self?.handleHR(bpm) } }
            .store(in: &cancellables)
        hr.$connectionState
            .sink { [weak self] state in
                MainActor.assumeIsolated {
                    self?.hrmConnected = state == .connected
                    self?.publishHeartRate()
                }
            }
            .store(in: &cancellables)
    }

    /// Manual reconnect from a disconnect banner.
    func reconnectTrainer() {
        trainer?.reconnectLast()
    }

    /// After a trainer drop, ride on `virtualPowerW` until the trainer is
    /// back. The climb then can't be a personal best.
    func useVirtualPower() {
        guard awaitingTrainer else { return }
        virtualPowerOptIn = true
        awaitingTrainer = false
    }

    /// Loads the course off the main thread. Phase goes loading → ready.
    func load(courseID: String) async {
        await load(plan: .single(courseID))
    }

    /// Loads the plan's first course. Phase goes loading → ready.
    func load(plan: CourseRidePlan) async {
        endRide()
        self.plan = plan
        legIndex = 0
        resetSeries()
        let courseID = plan.courseIDs[0]
        loadGeneration += 1
        let generation = loadGeneration
        phase = .loading
        loadError = nil
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try CourseBundle.load(id: courseID)
            }.value
            guard generation == loadGeneration else { return }
            bundle = loaded
            loadPersonalBest()
            resetRide(now: CACurrentMediaTime())
            phase = .ready
        } catch {
            guard generation == loadGeneration else { return }
            loadError = error.localizedDescription
            phase = .idle
        }
    }

    // MARK: Flow

    /// 3-2-1 countdown, then riding.
    func start() async {
        guard phase == .ready, bundle != nil else { return }
        // A workout is counting down, running or paused: it drives the trainer.
        trainerHeldByWorkout = !TrainerOwnership.isAvailable(to: self)
        guard !trainerHeldByWorkout else { return }
        countdownGeneration += 1
        let generation = countdownGeneration
        phase = .countdown
        for n in stride(from: 3, through: 1, by: -1) {
            countdownNumber = n
            AudioCues.shared.countdownTick(secondsRemaining: n)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if phase != .countdown || generation != countdownGeneration { return }
            // The calling view went away mid-countdown: back to the line
            // rather than racing through the remaining seconds.
            if Task.isCancelled {
                phase = .ready
                return
            }
        }
        countdownNumber = 0
        AudioCues.shared.countdownTick(secondsRemaining: 0)
        beginRiding(now: CACurrentMediaTime())
        startTimer()
    }

    func pauseOrResume(now: CFTimeInterval = CACurrentMediaTime()) {
        switch phase {
        case .riding, .recovering:
            pausedFrom = phase
            phase = .paused
            physics.speedMps = 0
            recovery.speedMps = 0
            bridge.hold(now: now)
        case .paused:
            phase = pausedFrom
            lastTick = now
            bridge.resume()
        default:
            return
        }
        publishLive(now: now)
        publishSnapshot(now: now)
    }

    /// Ends the ride where it is (rider stopped early). The result is
    /// marked not completed; `saveRide` records it as partial unless the
    /// summit was already reached.
    func finishEarly() {
        guard isLive else { return }
        finishRide(completed: false, now: CACurrentMediaTime())
    }

    /// Saves the ride to History (partial if it ended before the summit)
    /// and, once saved, stores a new personal best. Safe to call more than
    /// once; later calls return the same model. Called mid-ride, it ends
    /// the ride first.
    func saveRide(context: ModelContext) -> RideSessionModel? {
        if let savedModel { return savedModel }
        switch phase {
        case .riding, .recovering, .paused: finishRide(completed: false, now: CACurrentMediaTime())
        case .finished: break
        default: return nil
        }
        guard let bundle, elapsed >= 1 else { return nil }

        let ftp = AppSettings.ftp
        let perSecond = recorder.samples
        let power = perSecond.map(\.power)
        func mean(_ values: [Int]) -> Int { values.isEmpty ? 0 : values.reduce(0, +) / values.count }
        let durationSec = max(1, Int(elapsed.rounded()))
        let np = PowerMetrics.normalizedPower(power)
        let snapshot = recorder.snapshot()
        var samples = snapshot.samples
        let series = plan?.isSeries ?? false
        let finishedClimb: Bool
        if series {
            samples.segments = legStarts.enumerated().map { i, start in
                CourseSegment(courseID: start.courseID, offsetM: start.offsetM,
                              climbOnVirtualPower: legResults.indices.contains(i)
                                ? legResults[i].climbOnVirtualPower : climbUsedVirtualPower)
            }
            samples.climbOnVirtualPower = samples.segments?.contains(where: \.climbOnVirtualPower)
            // Every climb of the plan up to its summit.
            finishedClimb = legResults.count == plan?.legCount && legResults.allSatisfy { $0.climbTimeSec != nil }
        } else {
            samples.climbOnVirtualPower = climbUsedVirtualPower
            // Reaching the summit is the climb done, even if the rider
            // stopped short of the end of the route.
            finishedClimb = (result?.completed ?? false) || (climb?.isComplete ?? false)
        }

        let model = RideSessionModel(
            date: rideStartDate,
            workoutId: series ? BergSeries.workoutID : Self.workoutID(courseID: bundle.id),
            workoutName: series ? BergSeries.name(legCount: plan?.legCount ?? 0) : bundle.name,
            category: "Climb",
            durationSec: durationSec,
            ftp: ftp,
            avgPower: Int((workJ / elapsed).rounded()),
            avgCadence: mean(perSecond.map(\.cadence).filter { $0 > 0 }),
            avgHR: mean(perSecond.map(\.hr).filter { $0 > 0 }),
            peakPower: peakPower,
            peakHR: peakHR,
            peakCadence: peakCadence,
            np: np,
            intensityFactor: PowerMetrics.intensityFactor(np: np, ftp: ftp),
            tss: PowerMetrics.tss(durationSec: durationSec, np: np, ftp: ftp),
            partial: !finishedClimb,
            sampleInterval: snapshot.interval,
            samplesJSON: try? JSONEncoder().encode(samples)
        )
        context.insert(model)
        let saved = (try? context.save()) != nil
        // The PBs belong to a ride in History: only now do they count.
        if saved {
            for (courseID, pb) in pendingPBs {
                AppSettings.setPersonalBest(seconds: pb.seconds, splits: pb.splits, courseID: courseID, sessionID: model.id)
            }
            pendingPBs = [:]
        }
        savedModel = model
        return model
    }

    /// Ends the ride without saving; a PB it set is dropped with it.
    func discard() {
        endRide()
        resetSeries()
        // A series discarded after its first climb starts over from it.
        if legIndex > 0, let plan {
            phase = .loading
            Task { await load(plan: plan) }
            return
        }
        phase = bundle == nil ? .idle : .ready
        // A ride saved before this one may have set a new PB.
        loadPersonalBest()
        resetRide(now: CACurrentMediaTime())
    }

    /// Forgets the loaded course's personal best (time and splits).
    func clearPersonalBest() {
        guard let id = bundle?.id else { return }
        AppSettings.clearPersonalBest(courseID: id)
        personalBestSec = nil
        pbSplits = nil
        pbDeltaSec = nil
    }

    /// Releases the course when leaving the ride screen.
    func reset() {
        endRide()
        loadGeneration += 1
        bundle = nil
        legIndex = 0
        resetSeries()
        phase = .idle
        personalBestSec = nil
        pbSplits = nil
        resetRide(now: CACurrentMediaTime())
    }

    // MARK: Simulation

    /// Puts the rider on the road and starts the clock. Internal so tests
    /// can skip the countdown and drive `tick(now:)` themselves.
    func beginRiding(now: CFTimeInterval) {
        guard let bundle else { return }
        trainerHeldByWorkout = !TrainerOwnership.isAvailable(to: self)
        if trainerHeldByWorkout {
            if phase == .countdown { phase = .ready }
            return
        }
        countdownGeneration += 1
        loadPersonalBest()
        resetRide(now: now)
        rideStartDate = Date()
        params = .rider(weightKg: AppSettings.riderWeightKg, bikeKg: AppSettings.bikeWeightKg)
        climb = ClimbTimer(startS: bundle.climb.startS, endS: bundle.climb.endS, rideStartS: rideStartS)
        resetSeries()
        firstLegStartS = rideStartS
        legStarts = [(bundle.id, 0)]
        bridge.config.difficultyPct = AppSettings.trainerDifficultyPct
        bridge.begin()
        phase = .riding
        lastTick = now
        publishLive(now: now)
        publishSnapshot(now: now)
    }

    /// One physics step up to `now` (`CACurrentMediaTime()` in the app).
    /// Runs from the 30 Hz timer and from trainer notifications, which keep
    /// arriving while iOS holds the timer in the background.
    func tick(now: CFTimeInterval) {
        guard let bundle, phase == .riding || phase == .recovering else { return }
        let rawDt = now - lastTick
        guard rawDt > 0 else { return }
        lastTick = now
        let dt = min(rawDt, Self.maxTickDt)
        if phase == .recovering {
            recoveryTick(dt: dt, now: now)
            return
        }
        let route = bundle.route

        let input = powerInput(now: now)
        instantPower = input.power
        instantCadence = input.cadence
        let bpm = currentHeartRate(now: now)

        let s0 = physics.distanceM
        let t0 = elapsed
        physics = RidePhysics.step(physics, powerW: input.power, dt: dt, params: params) { s in
            RidePhysics.Terrain(gradePct: route.grade(at: s), crr: bundle.crr(surfaceIndex: route.surfaceIndex(at: s)))
        }
        let reachedEnd = physics.distanceM >= route.length
        if reachedEnd { physics.distanceM = route.length }
        let s1 = physics.distanceM
        elapsed += dt

        if var climbTimer = climb {
            let wasComplete = climbTimer.isComplete
            climbTimer.advance(fromS: s0, toS: s1, t0: t0, t1: elapsed, powerW: input.power)
            climb = climbTimer
            if input.virtual, !wasComplete, !climbUsedVirtualPower { climbUsedVirtualPower = true }
            if !wasComplete, climbTimer.isComplete { reachedSummit(climbTimer) }
        }

        let e1 = route.elevation(at: s1)
        gainM += max(0, e1 - route.elevation(at: s0))
        workJ += input.power * dt
        rolling.add(input.power, dt: dt)
        peakPower = max(peakPower, Int(input.power.rounded()))
        peakCadence = max(peakCadence, Int(input.cadence.rounded()))
        peakHR = max(peakHR, bpm)
        recorder.record(dt: dt, powerW: input.power, cadenceRpm: input.cadence, hr: bpm,
                        distanceM: legOffsetM + s1, altitudeM: e1, speedMps: physics.speedMps)

        // Drift towards the riding line for this surface.
        let line = Self.ridingLine(surface: route.surfaceName(at: s1), width: route.width(at: s1))
        let drift = Self.lateralDriftMps * dt
        lateralM += min(max(line - lateralM, -drift), drift)
        lateralM = min(lateralM, max(0, route.width(at: s1) / 2 - 0.5))

        let ahead = TrainerSimBridge.lookAheadM(speedMps: physics.speedMps)
        bridge.update(
            courseGradePct: route.averageGrade(from: s1, ahead: ahead),
            crr: bundle.crr(surfaceIndex: route.surfaceIndex(at: s1 + ahead / 2)),
            now: now
        )

        if reachedEnd {
            if let plan, legIndex + 1 < plan.legCount {
                beginRecovery(now: now)
            } else {
                finishRide(completed: true, now: now)
            }
            return
        }
        publishSnapshot(now: now)
        if now - lastLivePublish >= Self.livePublishInterval { publishLive(now: now) }
    }

    private func reachedSummit(_ timer: ClimbTimer) {
        guard let time = timer.climbTimeSec, let id = bundle?.id else { return }
        // Virtual power before the summit never counts.
        summitWasPB = !climbUsedVirtualPower && (personalBestSec.map { time < $0 } ?? true)
        // Held until the ride is saved, so a discarded ride leaves no PB.
        pendingPBs[id] = summitWasPB ? (time, timer.splits) : nil
    }

    /// The climb so far (or done) into `legResults`, once per course.
    private func recordLeg() {
        guard let bundle, !legRecorded else { return }
        legRecorded = true
        let time = climb?.climbTimeSec
        legResults.append(CourseLegResult(
            courseID: bundle.id,
            name: bundle.name,
            climbTimeSec: time,
            previousBestSec: personalBestSec,
            isPersonalBest: time != nil && summitWasPB,
            climbAvgPowerW: climb?.avgPowerW.map { Int($0.rounded()) },
            climbOnVirtualPower: climbUsedVirtualPower
        ))
    }

    // MARK: Series

    /// A series climb's route is done: spin easy on a flat road while the
    /// next course loads and its world is built.
    private func beginRecovery(now: CFTimeInterval) {
        guard let bundle, let plan else { return }
        recordLeg()
        let nextID = plan.courseIDs[legIndex + 1]
        recoveryBaseM = legOffsetM + physics.distanceM
        recovery = RidePhysics.State(distanceM: 0, speedMps: physics.speedMps)
        recoveryStartElapsed = elapsed
        recoveryEndElapsed = elapsed + max(plan.recoverySec, Self.recoveryCountdownSec)
        recoveryCountdown = nil
        let nextStart = CourseCatalog.summary(id: nextID)?.elevation(at: 0)
        let summitEnd = bundle.route.elevation(at: physics.distanceM)
        recoveryElevation = (summitEnd, nextStart ?? summitEnd)
        climb = nil
        summitWasPB = false
        // The spin is the way to the next climb: virtual power on it counts
        // against that climb.
        climbUsedVirtualPower = false
        legSceneReady = false
        phase = .recovering
        publishLive(now: now)
        publishSnapshot(now: now)

        let generation = loadGeneration
        nextLegTask = Task { [weak self] in
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try CourseBundle.load(id: nextID)
                }.value
                guard let self, generation == self.loadGeneration, self.isRecovering else { return }
                self.showNextCourse(loaded)
            } catch {
                guard let self, generation == self.loadGeneration, self.isRecovering else { return }
                self.loadError = error.localizedDescription
                self.finishRide(completed: false, now: CACurrentMediaTime())
            }
        }
    }

    /// The next course takes over the view (its world builds) while the
    /// rider waits at its start: parked, so the camera circles them.
    private func showNextCourse(_ next: CourseBundle) {
        bundle = next
        legIndex += 1
        loadPersonalBest()
        pbDeltaSec = nil
        physics = RidePhysics.State(distanceM: 0, speedMps: 0)
        lateralM = Self.ridingLine(surface: next.route.surfaceName(at: 0), width: next.route.width(at: 0))
        // On the ride's clock, which the next tick carries on from.
        publishLive(now: lastTick)
        publishSnapshot(now: lastTick)
    }

    /// The view shows the next course's world: the countdown may run out.
    func legSceneDidBecomeReady(courseID: String) {
        guard isRecovering, bundle?.id == courseID, legIndex == legResults.count else { return }
        legSceneReady = true
    }

    /// Ends the spin now, after the usual 3-2-1.
    func skipRecovery() {
        guard isRecovering else { return }
        recoveryEndElapsed = min(recoveryEndElapsed, elapsed + Self.recoveryCountdownSec)
        if phase == .paused { pauseOrResume() }
        publishLive(now: lastTick)
    }

    /// A minute more of easy spinning.
    func extendRecovery(bySec extra: Double = 60) {
        guard isRecovering else { return }
        recoveryEndElapsed += extra
        if let n = recoveryCountdown, recoveryEndElapsed - elapsed > Double(n) { recoveryCountdown = nil }
        publishLive(now: lastTick)
    }

    /// One tick of the spin: flat-road physics for the speed and distance,
    /// a flat road on the trainer, and the countdown to the next climb.
    private func recoveryTick(dt: Double, now: CFTimeInterval) {
        let input = powerInput(now: now)
        instantPower = input.power
        instantCadence = input.cadence
        let bpm = currentHeartRate(now: now)
        let crr = Self.recoveryCrr
        recovery = RidePhysics.step(recovery, powerW: input.power, dt: dt, params: params) { _ in
            RidePhysics.Terrain(gradePct: 0, crr: crr)
        }
        elapsed += dt
        if input.virtual, !climbUsedVirtualPower { climbUsedVirtualPower = true }
        workJ += input.power * dt
        rolling.add(input.power, dt: dt)
        peakPower = max(peakPower, Int(input.power.rounded()))
        peakCadence = max(peakCadence, Int(input.cadence.rounded()))
        peakHR = max(peakHR, bpm)
        recorder.record(dt: dt, powerW: input.power, cadenceRpm: input.cadence, hr: bpm,
                        distanceM: recoveryBaseM + recovery.distanceM, altitudeM: recoveryAltitude,
                        speedMps: recovery.speedMps)
        bridge.update(courseGradePct: 0, crr: crr, now: now)

        // Never run out before the next world is showing.
        if !legSceneReady {
            recoveryEndElapsed = max(recoveryEndElapsed, elapsed + Self.recoveryCountdownSec)
        }
        let remaining = recoveryEndElapsed - elapsed
        if remaining <= 0 {
            AudioCues.shared.countdownTick(secondsRemaining: 0)
            beginNextLeg(now: now)
            return
        }
        // The 3-2-1 waits for the world it counts down to.
        let n = Int(remaining.rounded(.up))
        if legSceneReady, Double(n) <= Self.recoveryCountdownSec, n != recoveryCountdown {
            recoveryCountdown = n
            AudioCues.shared.countdownTick(secondsRemaining: n)
        }
        publishSnapshot(now: now)
        if now - lastLivePublish >= Self.livePublishInterval { publishLive(now: now) }
    }

    /// The recorded altitude on the spin: from the summit behind towards
    /// the next start, over the planned spin.
    private var recoveryAltitude: Double {
        let span = max(recoveryEndElapsed - recoveryStartElapsed, 1)
        let f = min(max((elapsed - recoveryStartElapsed) / span, 0), 1)
        return recoveryElevation.from + (recoveryElevation.to - recoveryElevation.from) * f
    }

    /// The spin is over: on to the next course's start at the speed the
    /// rider was spinning at.
    private func beginNextLeg(now: CFTimeInterval) {
        guard let bundle else { return }
        legOffsetM = recoveryBaseM + recovery.distanceM
        legStarts.append((bundle.id, legOffsetM))
        rideStartS = 0
        physics = RidePhysics.State(distanceM: 0, speedMps: recovery.speedMps)
        climb = ClimbTimer(startS: bundle.climb.startS, endS: bundle.climb.endS, rideStartS: 0)
        summitWasPB = false
        legRecorded = false
        recoveryCountdown = nil
        lateralM = Self.ridingLine(surface: bundle.route.surfaceName(at: 0), width: bundle.route.width(at: 0))
        phase = .riding
        lastTick = now
        publishLive(now: now)
        publishSnapshot(now: now)
    }

    /// Ride distance of the rider's current position.
    private var rideCoordinateM: Double {
        isRecovering ? recoveryBaseM + recovery.distanceM : legOffsetM + physics.distanceM
    }

    /// Back to no climbs ridden.
    private func resetSeries() {
        nextLegTask?.cancel()
        nextLegTask = nil
        legResults = []
        legStarts = []
        legOffsetM = 0
        firstLegStartS = 0
        legRecorded = false
        pendingPBs = [:]
        recovery = RidePhysics.State(distanceM: 0, speedMps: 0)
        recoveryBaseM = 0
        recoveryEndElapsed = 0
        recoveryStartElapsed = 0
        recoveryCountdown = nil
        legSceneReady = false
        pausedFrom = .riding
    }

    /// Waits for the next course to load (tests).
    func waitForNextCourse() async {
        await nextLegTask?.value
    }

    private func finishRide(completed: Bool, now: CFTimeInterval) {
        stopTimer()
        bridge.end()
        let route = bundle?.route
        let recovering = isRecovering
        recorder.flush(
            hr: currentHeartRate(now: now), distanceM: rideCoordinateM,
            altitudeM: recovering ? recoveryAltitude : (route?.elevation(at: physics.distanceM) ?? 0),
            speedMps: recovering ? recovery.speedMps : physics.speedMps
        )
        let ridden = max(0, rideCoordinateM - firstLegStartS)
        // A spin cut short already holds its climb.
        if !recovering { recordLeg() }
        nextLegTask?.cancel()
        recoveryCountdown = nil
        physics.speedMps = 0
        recovery.speedMps = 0
        instantPower = 0
        instantCadence = 0

        let climbTime = recovering ? legResults.last?.climbTimeSec : climb?.climbTimeSec
        var climbSpeedKph: Double?
        if let climb, let climbTime, climbTime > 0 { climbSpeedKph = climb.lengthM / climbTime * 3.6 }
        // Result before phase, so anything reacting to `.finished` has it.
        result = CourseRideResult(
            climbTimeSec: climbTime,
            totalTimeSec: Int(elapsed.rounded()),
            distanceM: ridden,
            avgPowerW: elapsed > 0 ? Int((workJ / elapsed).rounded()) : 0,
            climbAvgPowerW: climb?.avgPowerW.map { Int($0.rounded()) },
            previousBestSec: personalBestSec,
            isPersonalBest: plan?.isSeries == true
                ? legResults.contains(where: \.isPersonalBest)
                : climbTime != nil && summitWasPB,
            completed: completed,
            elevationGainM: gainM,
            climbAvgSpeedKph: climbSpeedKph,
            legs: legResults
        )
        phase = .finished
        publishLive(now: now)
        publishSnapshot(now: now)
    }

    /// Stops the clock and hands the trainer back (flat road, stop training).
    private func endRide() {
        countdownGeneration += 1
        stopTimer()
        bridge.end()
    }

    /// Counting the ride: riding, spinning between climbs, or paused.
    private var isLive: Bool { phase == .riding || phase == .recovering || phase == .paused }

    // MARK: Inputs

    private func trainerDataFresh(now: CFTimeInterval) -> Bool {
        now - lastTrainerDataTime < Self.trainerDataTimeout
    }

    /// Rider power and cadence for this tick; `virtual` when they came from
    /// the virtual power control.
    private func powerInput(now: CFTimeInterval) -> (power: Double, cadence: Double, virtual: Bool) {
        refreshPowerSource(now: now)
        if trainerConnected {
            guard trainerDataFresh(now: now) else { return (0, 0, false) }
            return (Double(max(0, trainerPower)), Double(max(0, trainerCadence)), false)
        }
        // The ride's trainer dropped: coast rather than invent power.
        if awaitingTrainer { return (0, 0, false) }
        let watts = Double(max(0, virtualPowerW))
        let speed = phase == .recovering ? recovery.speedMps : physics.speedMps
        let cadence = Self.virtualCadence(speedMps: speed, preferredRpm: Double(max(0, virtualCadenceRpm)))
        return (watts, watts > 0 ? cadence : 0, true)
    }

    /// Cadence of a virtual rider on 50/34 × 11–34 road gearing, shifting to
    /// stay near `preferredRpm`: at 6 km/h on 20 % even the bottom gear only
    /// turns the cranks at about 50 rpm.
    static func virtualCadence(speedMps: Double, preferredRpm: Double) -> Double {
        guard speedMps > 0.05, preferredRpm > 0 else { return 0 }
        // Metres per crank turn: wheel circumference (700 × 25c) × ratio.
        let wheelM = 2.105
        let lowest = wheelM * 34 / 34, highest = wheelM * 50 / 11
        let development = min(max(speedMps * 60 / preferredRpm, lowest), highest)
        return speedMps * 60 / development
    }

    private func currentHeartRate(now: CFTimeInterval) -> Int {
        if hrmConnected, hrmBPM > 0 { return hrmBPM }
        if trainerConnected, trainerHR > 0, trainerDataFresh(now: now) { return trainerHR }
        return 0
    }

    /// Trainer power counts once the trainer is connected and either
    /// granted control or is sending readings (a trainer another app
    /// controls still measures power honestly). Once a trainer has powered
    /// the ride, losing it means 0 W until it's back (`awaitingTrainer`).
    private func refreshPowerSource(now: CFTimeInterval) {
        let connected = trainerLinkUp && (trainerInControl || trainerDataFresh(now: now))
        if trainerConnected != connected { trainerConnected = connected }
        let granted = trainerLinkUp && trainerInControl
        if trainerControlGranted != granted { trainerControlGranted = granted }
        let live = isLive
        if connected, live {
            hadTrainerThisRide = true
            // Back: a later drop coasts again.
            virtualPowerOptIn = false
        }
        let awaiting = live && hadTrainerThisRide && !connected && !virtualPowerOptIn
        if awaitingTrainer != awaiting { awaitingTrainer = awaiting }
        if usingVirtualPower == connected { usingVirtualPower = !connected }
    }

    // Trainer and HR monitor events. Internal so tests can drive them with
    // their own clock.

    func handleTrainerData(_ data: TrainerData, now: CFTimeInterval) {
        // A trainer may split one reading across notifications: a field
        // this one doesn't carry keeps its last value rather than reading 0.
        if let cadence = data.cadence { trainerCadence = cadence }
        if let bpm = data.heartRate { trainerHR = bpm }
        // Only power readings keep the trainer fresh.
        guard let power = data.power else { return }
        trainerPower = power
        lastTrainerDataTime = now
        refreshPowerSource(now: now)
        // BLE notifications keep coming while iOS suspends the timer in the
        // background; use them as a heartbeat, like RideController does.
        if phase == .riding || phase == .recovering { tick(now: now) }
    }

    func handleTrainerLink(_ connected: Bool, now: CFTimeInterval = CACurrentMediaTime()) {
        trainerLinkUp = connected
        if !connected { trainerInControl = false }
        refreshPowerSource(now: now)
    }

    func handleTrainerControl(_ has: Bool, now: CFTimeInterval = CACurrentMediaTime()) {
        let regained = has && !trainerInControl
        trainerInControl = has
        refreshPowerSource(now: now)
        if regained, isLive {
            bridge.resync(now: now)
        }
    }

    func handleSlopeReply(_ reply: FTMSManager.SlopeReply) {
        var refusal: String?
        if case .refused(let code) = reply { refusal = FTMSManager.refusalReason(code: code) }
        if trainerSlopeRefusal != refusal { trainerSlopeRefusal = refusal }
    }

    private func handleHR(_ bpm: Int) {
        hrmBPM = bpm
        publishHeartRate()
    }

    /// Outside a ride the HUD still shows heart rate as it arrives.
    private func publishHeartRate() {
        guard phase != .riding, phase != .recovering else { return }
        let bpm = currentHeartRate(now: CACurrentMediaTime())
        if heartRate != bpm { heartRate = bpm }
    }

    /// Holds the trainer against a workout while this ride counts down,
    /// runs or is paused.
    private func syncTrainerClaim() {
        switch phase {
        case .countdown, .riding, .recovering, .paused: TrainerOwnership.claim(self)
        case .idle, .loading, .ready, .finished: TrainerOwnership.release(self)
        }
    }

    // MARK: Publishing

    private func loadPersonalBest() {
        guard let id = bundle?.id else { return }
        personalBestSec = AppSettings.personalBestSeconds(courseID: id)
        pbSplits = AppSettings.personalBestSplits(courseID: id)
    }

    /// Back to the start line with every value zeroed.
    private func resetRide(now: CFTimeInterval) {
        let length = bundle?.route.length ?? 0
        rideStartS = min(max(debugStartS, 0), max(0, length - 1))
        physics = RidePhysics.State(distanceM: rideStartS, speedMps: 0)
        elapsed = 0; workJ = 0; gainM = 0
        rolling.reset()
        instantPower = 0; instantCadence = 0
        peakPower = 0; peakCadence = 0; peakHR = 0
        climb = nil
        summitWasPB = false
        pendingPBs = [:]
        climbUsedVirtualPower = false
        hadTrainerThisRide = false
        virtualPowerOptIn = false
        savedModel = nil
        recorder.reset()
        result = nil
        lateralM = bundle.map {
            Self.ridingLine(surface: $0.route.surfaceName(at: rideStartS), width: $0.route.width(at: rideStartS))
        } ?? Self.lateralAsphaltM
        publishLive(now: now)
        publishSnapshot(now: now)
    }

    private func publishLive(now: CFTimeInterval) {
        lastLivePublish = now
        refreshPowerSource(now: now)
        bridge.config.difficultyPct = AppSettings.trainerDifficultyPct
        let s = physics.distanceM
        let riding = phase == .riding || phase == .recovering
        let recovering = isRecovering

        distanceM = s
        rideDistanceM = max(0, rideCoordinateM - firstLegStartS)
        recoveryRemainingSec = recovering ? max(0, recoveryEndElapsed - elapsed) : 0
        speedKph = (recovering ? recovery.speedMps : physics.speedMps) * 3.6
        powerW = riding ? Int(rolling.mean.rounded()) : 0
        cadenceRpm = riding ? Int(instantCadence.rounded()) : 0
        heartRate = currentHeartRate(now: now)
        elapsedSec = Int(elapsed)
        elevationGainM = gainM
        avgPowerW = elapsed > 0 ? Int((workJ / elapsed).rounded()) : 0
        wattsPerKg = Double(powerW) / AppSettings.riderWeightKg
        trainerGradePct = bridge.lastSentGradePct

        guard let bundle else {
            gradePct = 0; elevationM = 0; distanceToSummitM = 0; surfaceName = "asphalt"
            climbElapsedSec = nil; climbProgress = 0; pbDeltaSec = nil
            return
        }
        let route = bundle.route
        let range = bundle.climb
        gradePct = recovering ? 0 : route.grade(at: s)
        elevationM = recovering ? recoveryAltitude : route.elevation(at: s)
        surfaceName = recovering ? "asphalt" : route.surfaceName(at: s)
        distanceToSummitM = max(0, range.endS - s)
        climbProgress = range.lengthM > 0 ? min(max((s - range.startS) / range.lengthM, 0), 1) : 0
        climbElapsedSec = climb?.elapsed(at: elapsed)
        pbDeltaSec = personalBestDelta(at: s)
    }

    private func personalBestDelta(at s: Double) -> Double? {
        guard let pb = personalBestSec, let climb, let climbTime = climb.elapsed(at: elapsed) else { return nil }
        let reference = ClimbTimer.referenceTime(
            atDistance: s - climb.startS, splits: pbSplits, totalSec: pb,
            lengthM: climb.lengthM, spacingM: climb.splitSpacingM
        )
        return climbTime - reference
    }

    private func publishSnapshot(now: CFTimeInterval) {
        let riding = phase == .riding
        stateBox.write(RideSnapshot(
            s: physics.distanceM,
            speedMps: riding ? physics.speedMps : 0,
            cadenceRpm: riding ? instantCadence : 0,
            powerW: riding ? instantPower : 0,
            gradePct: bundle?.route.grade(at: physics.distanceM) ?? 0,
            lateralM: lateralM,
            timestamp: now,
            isRunning: riding
        ))
    }

    // MARK: Timer

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.tick(now: CACurrentMediaTime())
            }
        }
        t.tolerance = 0.004
        // .common keeps the ride running while a scroll view is tracking.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
