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
}

/// Runs one 3D course ride: load → countdown → riding ⇄ paused → finished.
///
/// A 30 Hz timer integrates `RidePhysics` with the rider's power (the
/// trainer's when one is connected, `virtualPowerW` otherwise), hands the
/// result to the 3D view through `stateBox` every tick and refreshes the
/// published HUD values at ~5 Hz. `TrainerSimBridge` feeds the gradient
/// ahead to the trainer; `ClimbTimer` times the climb against the personal
/// best; `CourseRideRecorder` keeps per-second samples for History.
@MainActor
final class CourseRideController: ObservableObject {
    enum Phase: Equatable { case idle, loading, ready, countdown, riding, paused, finished }

    @Published private(set) var phase: Phase = .idle {
        didSet { syncTrainerClaim() }
    }
    @Published private(set) var bundle: CourseBundle?
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
    /// This ride's PB, written to `AppSettings` only when the ride is saved.
    private var pendingPB: (seconds: Double, splits: [Double])?
    private var savedModel: RideSessionModel?
    /// Wall-clock start, for History and exports.
    private var rideStartDate = Date()
    /// A trainer has powered this ride, so losing it coasts on 0 W rather
    /// than switching to virtual power.
    private var hadTrainerThisRide = false
    /// The rider chose virtual power after the trainer dropped.
    private var virtualPowerOptIn = false

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
        endRide()
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

    func pauseOrResume() {
        let now = CACurrentMediaTime()
        switch phase {
        case .riding:
            phase = .paused
            physics.speedMps = 0
            bridge.hold(now: now)
        case .paused:
            phase = .riding
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
        guard phase == .riding || phase == .paused else { return }
        finishRide(completed: false, now: CACurrentMediaTime())
    }

    /// Saves the ride to History (partial if it ended before the summit)
    /// and, once saved, stores a new personal best. Safe to call more than
    /// once; later calls return the same model. Called mid-ride, it ends
    /// the ride first.
    func saveRide(context: ModelContext) -> RideSessionModel? {
        if let savedModel { return savedModel }
        switch phase {
        case .riding, .paused: finishRide(completed: false, now: CACurrentMediaTime())
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
        samples.climbOnVirtualPower = climbUsedVirtualPower
        // Reaching the summit is the climb done, even if the rider stopped
        // short of the end of the route.
        let finishedClimb = (result?.completed ?? false) || (climb?.isComplete ?? false)

        let model = RideSessionModel(
            date: rideStartDate,
            workoutId: Self.workoutID(courseID: bundle.id),
            workoutName: bundle.name,
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
        // The PB belongs to a ride in History: only now does it count.
        if saved, let pb = pendingPB {
            AppSettings.setPersonalBest(seconds: pb.seconds, splits: pb.splits, courseID: bundle.id, sessionID: model.id)
            pendingPB = nil
        }
        savedModel = model
        return model
    }

    /// Ends the ride without saving; a PB it set is dropped with it.
    func discard() {
        endRide()
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
        guard let bundle, phase == .riding else { return }
        let rawDt = now - lastTick
        guard rawDt > 0 else { return }
        lastTick = now
        let dt = min(rawDt, Self.maxTickDt)
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
                        distanceM: s1, altitudeM: e1, speedMps: physics.speedMps)

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
            finishRide(completed: true, now: now)
            return
        }
        publishSnapshot(now: now)
        if now - lastLivePublish >= Self.livePublishInterval { publishLive(now: now) }
    }

    private func reachedSummit(_ timer: ClimbTimer) {
        guard let time = timer.climbTimeSec else { return }
        // Virtual power before the summit never counts.
        summitWasPB = !climbUsedVirtualPower && (personalBestSec.map { time < $0 } ?? true)
        // Held until the ride is saved, so a discarded ride leaves no PB.
        pendingPB = summitWasPB ? (time, timer.splits) : nil
    }

    private func finishRide(completed: Bool, now: CFTimeInterval) {
        stopTimer()
        bridge.end()
        let route = bundle?.route
        recorder.flush(
            hr: currentHeartRate(now: now), distanceM: physics.distanceM,
            altitudeM: route?.elevation(at: physics.distanceM) ?? 0, speedMps: physics.speedMps
        )
        physics.speedMps = 0
        instantPower = 0
        instantCadence = 0

        let climbTime = climb?.climbTimeSec
        var climbSpeedKph: Double?
        if let climb, let climbTime, climbTime > 0 { climbSpeedKph = climb.lengthM / climbTime * 3.6 }
        // Result before phase, so anything reacting to `.finished` has it.
        result = CourseRideResult(
            climbTimeSec: climbTime,
            totalTimeSec: Int(elapsed.rounded()),
            distanceM: max(0, physics.distanceM - rideStartS),
            avgPowerW: elapsed > 0 ? Int((workJ / elapsed).rounded()) : 0,
            climbAvgPowerW: climb?.avgPowerW.map { Int($0.rounded()) },
            previousBestSec: personalBestSec,
            isPersonalBest: climbTime != nil && summitWasPB,
            completed: completed,
            elevationGainM: gainM,
            climbAvgSpeedKph: climbSpeedKph
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
        let cadence = Self.virtualCadence(speedMps: physics.speedMps, preferredRpm: Double(max(0, virtualCadenceRpm)))
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
        let live = phase == .riding || phase == .paused
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
        if phase == .riding { tick(now: now) }
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
        if regained, phase == .riding || phase == .paused {
            bridge.resync(now: now)
        }
    }

    private func handleHR(_ bpm: Int) {
        hrmBPM = bpm
        publishHeartRate()
    }

    /// Outside a ride the HUD still shows heart rate as it arrives.
    private func publishHeartRate() {
        guard phase != .riding else { return }
        let bpm = currentHeartRate(now: CACurrentMediaTime())
        if heartRate != bpm { heartRate = bpm }
    }

    /// Holds the trainer against a workout while this ride counts down,
    /// runs or is paused.
    private func syncTrainerClaim() {
        switch phase {
        case .countdown, .riding, .paused: TrainerOwnership.claim(self)
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
        pendingPB = nil
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
        let riding = phase == .riding

        distanceM = s
        speedKph = physics.speedMps * 3.6
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
        gradePct = route.grade(at: s)
        elevationM = route.elevation(at: s)
        surfaceName = route.surfaceName(at: s)
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
