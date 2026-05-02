import Foundation
import SwiftUI
import SwiftData
import Combine

/// Orchestrates a single ride session: workout selection → countdown → riding → save/discard.
@MainActor
final class RideController: ObservableObject {
    enum AppState: Equatable {
        case setup, ready, countdown, riding, paused, completed
    }

    @Published var selectedWorkout: Workout?
    @Published var state: AppState = .setup

    @Published var currentPower: Int = 0
    @Published var currentCadence: Int = 0
    @Published var currentHR: Int = 0
    @Published var currentTarget: Int = 0
    @Published var elapsed: Int = 0
    @Published var remaining: Int = 0
    @Published var currentZone: Zone = Zones.all[0]
    @Published var currentIntervalContext: IntervalContext?
    @Published var rolling3sPower: Int = 0
    @Published var np: Int = 0
    @Published var intensityFactor: Double = 0
    @Published var tss: Int = 0
    @Published var countdownNumber: Int = 5

    let player = WorkoutPlayer()
    let recorder = RideRecorder()

    private var ftp: Int { AppSettings.ftp }
    private var powerBuffer: [Int] = []
    private let powerBufferSize = 3
    private var statPower: [Int] = []
    private var statCadence: [Int] = []
    private var statHR: [Int] = []
    private var lastHR: Int = 0
    private var tssTickCounter = 0

    private var cancellables = Set<AnyCancellable>()
    private weak var trainer: FTMSManager?
    private weak var hr: HRManager?

    init() {
        player.onTick = { [weak self] ctx in self?.handleTick(ctx) }
        player.onIntervalChange = { _ in /* no-op for now */ }
        player.onIntervalWarning = { sec in AudioCues.shared.intervalWarning(secondsRemaining: sec) }
        player.onComplete = { [weak self] in self?.handleComplete() }
    }

    func bind(trainer: FTMSManager, hr: HRManager) {
        self.trainer = trainer
        self.hr = hr

        trainer.onData = { [weak self] data in
            Task { @MainActor in self?.handleTrainerData(data) }
        }
        hr.onHR = { [weak self] bpm in
            Task { @MainActor in self?.handleHR(bpm) }
        }
    }

    // MARK: Selection / state transitions

    func select(_ workout: Workout) {
        selectedWorkout = workout
        player.load(workout, ftp: ftp)
        state = .ready
        resetMetrics()
    }

    func deselect() {
        selectedWorkout = nil
        player.stop()
        state = .setup
        resetMetrics()
    }

    /// Begin countdown → riding flow. Returns when riding starts.
    func startRide() async {
        guard selectedWorkout != nil else { return }
        state = .countdown
        for n in stride(from: 5, through: 1, by: -1) {
            countdownNumber = n
            AudioCues.shared.countdownTick(secondsRemaining: n)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        countdownNumber = 0
        AudioCues.shared.countdownTick(secondsRemaining: 0)
        try? await Task.sleep(nanoseconds: 800_000_000)
        beginRiding()
    }

    private func beginRiding() {
        state = .riding
        player.start()
        trainer?.startTraining()
        trainer?.autoReconnectEnabled = true
        recorder.start()
        statPower.removeAll(); statCadence.removeAll(); statHR.removeAll()
        tssTickCounter = 0
    }

    /// Manual reconnect from the disconnect banner.
    func reconnectTrainer() {
        trainer?.reconnectLast()
    }

    func pauseOrResume() {
        switch state {
        case .riding:
            player.pause()
            state = .paused
        case .paused:
            player.resume()
            state = .riding
        default: break
        }
    }

    func skipForward() { player.skipForward() }
    func skipBackward() { player.skipBackward() }

    // MARK: Live edits

    /// Adjust the power of the currently active interval by a fixed watts delta.
    /// Takes effect on the next 1Hz tick.
    func adjustCurrentInterval(byWatts delta: Int) {
        guard let workout = selectedWorkout, let ctx = currentIntervalContext else { return }
        let updated = workout.adjustingInterval(at: ctx.index, byWatts: delta, ftp: ftp)
        selectedWorkout = updated
        player.updateWorkout(updated)
    }

    /// Insert a new interval into the active workout, immediately after the
    /// currently playing one. If there is no current interval (e.g. ride is in
    /// .ready), append to the end.
    func insertIntervalAfterCurrent(_ interval: Interval) {
        guard let workout = selectedWorkout else { return }
        let insertAt: Int
        if let ctx = currentIntervalContext {
            insertAt = min(ctx.index + 1, workout.intervals.count)
        } else {
            insertAt = workout.intervals.count
        }
        var newIntervals = workout.intervals
        newIntervals.insert(interval, at: insertAt)
        let updated = Workout(
            id: workout.id,
            name: workout.name,
            description: workout.description,
            category: workout.category,
            intervals: newIntervals,
            isCustom: workout.isCustom
        )
        selectedWorkout = updated
        player.updateWorkout(updated)
        remaining = max(0, updated.totalDuration - elapsed)
    }

    func requestStop() {
        if state == .riding { player.pause(); state = .paused }
    }

    /// Save partial ride and end.
    func saveAndStop(context: ModelContext) -> RideSessionModel? {
        recorder.stop()
        let model = persist(context: context, partial: true)
        player.stop()
        trainer?.autoReconnectEnabled = false
        trainer?.stopTraining()
        state = .completed
        return model
    }

    func discardAndStop() {
        player.stop()
        trainer?.autoReconnectEnabled = false
        trainer?.stopTraining()
        recorder.stop()
        recorder.reset()
        state = .ready
        resetMetrics()
    }

    /// Called on natural workout completion.
    private func handleComplete() {
        trainer?.autoReconnectEnabled = false
        trainer?.stopTraining()
        recorder.stop()
        state = .completed
    }

    func savedSessionAndDismiss(context: ModelContext) -> RideSessionModel? {
        let model = persist(context: context, partial: false)
        recorder.reset()
        return model
    }

    func dismissCompletion() {
        recorder.reset()
        deselect()
    }

    // MARK: Live data ingestion

    private func handleTrainerData(_ data: TrainerData) {
        powerBuffer.append(data.power)
        if powerBuffer.count > powerBufferSize { powerBuffer.removeFirst() }
        rolling3sPower = powerBuffer.reduce(0, +) / max(powerBuffer.count, 1)

        currentPower = data.power
        currentCadence = data.cadence

        if data.heartRate > 0, hr?.connectionState != .connected {
            currentHR = data.heartRate
            lastHR = data.heartRate
        }

        let zone = Zones.zone(forWatts: rolling3sPower, ftp: ftp)
        currentZone = zone

        if state == .riding {
            // BLE callbacks fire while backgrounded (we hold `bluetooth-central`
            // background mode); use them as a heartbeat so elapsed/target stay
            // accurate even when iOS suspends our 1Hz Timer.
            player.refresh()

            statPower.append(data.power)
            if data.cadence > 0 { statCadence.append(data.cadence) }
            if data.heartRate > 0 { statHR.append(data.heartRate) }
            recorder.record(power: data.power, cadence: data.cadence, hr: data.heartRate > 0 ? data.heartRate : lastHR, target: currentTarget)
        }
    }

    private func handleHR(_ bpm: Int) {
        currentHR = bpm
        lastHR = bpm
        if state == .riding { statHR.append(bpm) }
    }

    // MARK: Player tick

    private func handleTick(_ ctx: IntervalContext?) {
        guard let workout = selectedWorkout else { return }
        elapsed = player.elapsedSeconds
        remaining = max(0, workout.totalDuration - elapsed)
        currentIntervalContext = ctx

        if let ctx {
            let pct = ctx.interval.powerPercent(atElapsed: ctx.elapsed)
            currentTarget = Int((pct / 100.0 * Double(ftp)).rounded())
            // Send to trainer
            if trainer?.connectionState == .connected {
                trainer?.setTargetPower(currentTarget)
            }
        }

        tssTickCounter += 1
        if tssTickCounter >= 5 && !statPower.isEmpty {
            tssTickCounter = 0
            np = PowerMetrics.normalizedPower(statPower)
            intensityFactor = PowerMetrics.intensityFactor(np: np, ftp: ftp)
            tss = PowerMetrics.tss(durationSec: elapsed, np: np, ftp: ftp)
        }
    }

    // MARK: Persistence

    @discardableResult
    private func persist(context: ModelContext, partial: Bool) -> RideSessionModel? {
        guard let w = selectedWorkout else { return nil }
        let avg: ([Int]) -> Int = { arr in
            arr.isEmpty ? 0 : arr.reduce(0, +) / arr.count
        }
        let avgPower = avg(statPower)
        let avgCadence = avg(statCadence)
        let avgHR = avg(statHR)
        let np = PowerMetrics.normalizedPower(statPower)
        let intF = PowerMetrics.intensityFactor(np: np, ftp: ftp)
        let tss = PowerMetrics.tss(durationSec: elapsed, np: np, ftp: ftp)

        let snapshot = recorder.snapshot()
        let samplesData = try? JSONEncoder().encode(snapshot.samples)

        let model = RideSessionModel(
            workoutId: w.id,
            workoutName: w.name,
            category: w.category.rawValue,
            durationSec: elapsed > 0 ? elapsed : w.totalDuration,
            ftp: ftp,
            avgPower: avgPower,
            avgCadence: avgCadence,
            avgHR: avgHR,
            np: np,
            intensityFactor: intF,
            tss: tss,
            partial: partial,
            sampleInterval: snapshot.interval,
            samplesJSON: samplesData
        )
        context.insert(model)
        try? context.save()
        return model
    }

    // MARK: Reset

    private func resetMetrics() {
        currentPower = 0; currentCadence = 0; currentHR = 0; currentTarget = 0
        elapsed = 0; remaining = selectedWorkout?.totalDuration ?? 0
        currentZone = Zones.all[0]
        currentIntervalContext = nil
        rolling3sPower = 0
        np = 0; intensityFactor = 0; tss = 0
        powerBuffer.removeAll()
        statPower.removeAll(); statCadence.removeAll(); statHR.removeAll()
        tssTickCounter = 0
    }
}
