import Foundation
import SwiftUI
import SwiftData
import QuartzCore

/// Outcome of a course ride, shown on the finish screen.
struct CourseRideResult: Equatable, Sendable {
    /// Time from crossing the climb start to the summit; nil if not reached.
    let climbTimeSec: Double?
    let totalTimeSec: Int
    let distanceM: Double
    let avgPowerW: Int
    let climbAvgPowerW: Int?
    let previousBestSec: Double?
    let isPersonalBest: Bool
    /// True when the rider reached the end of the route.
    let completed: Bool
}

/// Runs one 3D course ride: load → countdown → riding ⇄ paused → finished.
///
/// SKELETON: the public API is final; the internals are a stand-in (steady
/// state speed from power, no trainer control, no recording) so the scene and
/// HUD can be built against it. The full implementation (RidePhysics,
/// TrainerSimBridge, recording to History, personal bests) replaces the body.
@MainActor
final class CourseRideController: ObservableObject {
    enum Phase: Equatable { case idle, loading, ready, countdown, riding, paused, finished }

    @Published private(set) var phase: Phase = .idle
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

    /// Power used when no trainer is connected (and in the Simulator).
    @Published var virtualPowerW: Int = 200
    @Published var virtualCadenceRpm: Int = 85
    /// True while power comes from `virtualPowerW` rather than a trainer.
    @Published private(set) var usingVirtualPower: Bool = true

    /// Read by the 3D view every frame.
    let stateBox = RideStateBox()

    private weak var trainer: FTMSManager?
    private weak var hr: HRManager?
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var speedMps: Double = 0
    private var elapsed: Double = 0

    func bind(trainer: FTMSManager, hr: HRManager) {
        self.trainer = trainer
        self.hr = hr
    }

    /// Loads the course off the main thread. Phase goes loading → ready.
    func load(courseID: String) async {
        phase = .loading
        loadError = nil
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try CourseBundle.load(id: courseID)
            }.value
            bundle = loaded
            resetLiveValues()
            phase = .ready
        } catch {
            loadError = error.localizedDescription
            phase = .idle
        }
    }

    /// 3-2-1 countdown, then riding.
    func start() async {
        guard phase == .ready, bundle != nil else { return }
        phase = .countdown
        for n in stride(from: 3, through: 1, by: -1) {
            countdownNumber = n
            AudioCues.shared.countdownTick(secondsRemaining: n)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if phase != .countdown { return }
        }
        countdownNumber = 0
        AudioCues.shared.countdownTick(secondsRemaining: 0)
        phase = .riding
        lastTick = CACurrentMediaTime()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func pauseOrResume() {
        switch phase {
        case .riding: phase = .paused
        case .paused: phase = .riding; lastTick = CACurrentMediaTime()
        default: break
        }
        publishSnapshot()
    }

    /// Saves the ride to History (partial if the route wasn't finished).
    /// Safe to call more than once; later calls return the same model.
    func saveRide(context: ModelContext) -> RideSessionModel? {
        nil
    }

    /// Ends the ride without saving.
    func discard() {
        stopTimer()
        phase = bundle == nil ? .idle : .ready
        resetLiveValues()
    }

    /// Releases the course when leaving the ride screen.
    func reset() {
        stopTimer()
        bundle = nil
        phase = .idle
        resetLiveValues()
    }

    // MARK: Stand-in simulation

    private func tick() {
        guard let bundle, phase == .riding else { return }
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.25)
        lastTick = now
        elapsed += dt

        let route = bundle.route
        let grade = route.grade(at: distanceM)
        let power = Double(virtualPowerW)
        speedMps = Self.steadySpeed(powerW: power, gradePct: grade, massKg: AppSettings.riderWeightKg + AppSettings.bikeWeightKg)
        distanceM = min(distanceM + speedMps * dt, route.length)

        speedKph = speedMps * 3.6
        powerW = virtualPowerW
        cadenceRpm = virtualCadenceRpm
        gradePct = grade
        elevationM = route.elevation(at: distanceM)
        elapsedSec = Int(elapsed)
        distanceToSummitM = max(0, bundle.climb.endS - distanceM)
        surfaceName = route.surfaceName(at: distanceM)
        wattsPerKg = power / AppSettings.riderWeightKg
        if distanceM >= bundle.climb.startS {
            climbElapsedSec = (climbElapsedSec ?? 0) + dt
        }
        publishSnapshot()

        if distanceM >= route.length {
            stopTimer()
            phase = .finished
            result = CourseRideResult(
                climbTimeSec: climbElapsedSec, totalTimeSec: elapsedSec, distanceM: distanceM,
                avgPowerW: virtualPowerW, climbAvgPowerW: virtualPowerW,
                previousBestSec: nil, isPersonalBest: false, completed: true
            )
            publishSnapshot()
        }
    }

    /// Speed at which `powerW` balances gravity, rolling and air resistance.
    private static func steadySpeed(powerW: Double, gradePct: Double, massKg: Double) -> Double {
        let theta = atan(gradePct / 100)
        let resist = massKg * 9.81 * (sin(theta) + 0.006 * cos(theta))
        var v = 5.0
        for _ in 0..<30 {
            let f = 0.5 * 1.2 * 0.32 * v * v * v + resist * v - powerW * 0.976
            let df = 1.5 * 1.2 * 0.32 * v * v + resist
            guard df > 1e-6 else { break }
            v = max(0.3, v - f / df)
        }
        return v
    }

    private func publishSnapshot() {
        stateBox.write(RideSnapshot(
            s: distanceM, speedMps: phase == .riding ? speedMps : 0,
            cadenceRpm: phase == .riding ? Double(cadenceRpm) : 0,
            powerW: Double(powerW), gradePct: gradePct, lateralM: 0.4,
            timestamp: CACurrentMediaTime(), isRunning: phase == .riding
        ))
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func resetLiveValues() {
        distanceM = 0; speedMps = 0; elapsed = 0
        speedKph = 0; powerW = 0; cadenceRpm = 0; heartRate = 0
        gradePct = bundle?.route.grade(at: 0) ?? 0
        elevationM = bundle?.route.elevation(at: 0) ?? 0
        elevationGainM = 0; elapsedSec = 0; climbElapsedSec = nil
        distanceToSummitM = bundle.map { $0.climb.endS } ?? 0
        surfaceName = bundle?.route.surfaceName(at: 0) ?? "asphalt"
        wattsPerKg = 0; result = nil
        publishSnapshot()
    }
}
