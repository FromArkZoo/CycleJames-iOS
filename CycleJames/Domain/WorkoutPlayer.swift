import Foundation
import Combine
import UIKit

@MainActor
final class WorkoutPlayer: ObservableObject {
    enum State: Equatable {
        case idle, ready, countdown, running, paused, completed
    }

    @Published var workout: Workout?
    @Published var ftp: Int = AppSettings.defaultFTP
    @Published var state: State = .idle
    @Published var elapsedSeconds: Int = 0

    var totalDuration: Int { workout?.totalDuration ?? 0 }
    var remainingSeconds: Int { max(0, totalDuration - elapsedSeconds) }

    var currentContext: IntervalContext? {
        workout?.intervalContext(forElapsed: elapsedSeconds)
    }

    var currentTargetWatts: Int {
        guard let ctx = currentContext else { return 0 }
        let pct = ctx.interval.powerPercent(atElapsed: ctx.elapsed)
        return Int((pct / 100.0 * Double(ftp)).rounded())
    }

    /// Fired on every 1Hz tick while running.
    var onTick: ((IntervalContext?) -> Void)?
    /// Fired when the active interval index changes.
    var onIntervalChange: ((IntervalContext) -> Void)?
    /// Fired with seconds-remaining at 3, 2, 1, 0 around an interval transition.
    var onIntervalWarning: ((Int) -> Void)?
    /// Fired when the workout reaches totalDuration.
    var onComplete: (() -> Void)?

    private var timer: Timer?

    // Wall-clock elapsed: `accumulatedRunTime` records seconds spent running
    // before the most recent resume; `runStartDate` anchors the active run.
    // Reading wall-clock means a backgrounded ride doesn't lose time when iOS
    // suspends our 1Hz timer.
    private var runStartDate: Date?
    private var accumulatedRunTime: TimeInterval = 0
    private var lastWarnedRemaining: Int = -1
    private var foregroundObserver: NSObjectProtocol?

    init() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDidBecomeActive() }
        }
    }

    deinit {
        if let obs = foregroundObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func load(_ workout: Workout, ftp: Int) {
        stopTimer()
        self.workout = workout
        self.ftp = ftp
        self.elapsedSeconds = 0
        self.runStartDate = nil
        self.accumulatedRunTime = 0
        self.lastWarnedRemaining = -1
        self.state = .ready
    }

    /// Swap the active workout in-place, preserving elapsedSeconds and timer
    /// state. Used for live edits — power tweaks and interval insertions —
    /// during a running ride.
    func updateWorkout(_ newWorkout: Workout) {
        self.workout = newWorkout
    }

    func start() {
        guard workout != nil, state != .running else { return }
        stopTimer()
        state = .running
        accumulatedRunTime = 0
        runStartDate = Date()
        elapsedSeconds = 0
        lastWarnedRemaining = -1
        startTimer()
        onTick?(currentContext)
    }

    func pause() {
        guard state == .running else { return }
        if let s = runStartDate {
            accumulatedRunTime += Date().timeIntervalSince(s)
        }
        runStartDate = nil
        state = .paused
        stopTimer()
    }

    func resume() {
        guard state == .paused else { return }
        runStartDate = Date()
        state = .running
        startTimer()
    }

    func stop() {
        stopTimer()
        runStartDate = nil
        accumulatedRunTime = 0
        elapsedSeconds = 0
        lastWarnedRemaining = -1
        state = .idle
    }

    func skipForward() {
        guard let ctx = currentContext, let workout else { return }
        let nextStart = ctx.intervalStart + ctx.interval.duration
        if nextStart < workout.totalDuration {
            setElapsed(nextStart)
        }
    }

    func skipBackward() {
        guard let ctx = currentContext, let workout else { return }
        if elapsedSeconds - ctx.intervalStart > 2 {
            setElapsed(ctx.intervalStart)
        } else if ctx.index > 0 {
            var start = 0
            for i in 0..<(ctx.index - 1) {
                start += workout.intervals[i].duration
            }
            setElapsed(start)
        } else {
            setElapsed(0)
        }
    }

    /// External heartbeat — call when something delivers fresh state outside
    /// the 1Hz timer (BLE data callback, scene-active notification). Recomputes
    /// elapsed from wall-clock and fires lifecycle callbacks for any missed
    /// transitions, so the trainer/UI catch up immediately after a background
    /// suspend.
    func refresh() {
        guard state == .running else { return }
        tick()
    }

    /// Jump to the start of an arbitrary interval index. Used by the
    /// upcoming-intervals "Skip to" action.
    func seekToInterval(at index: Int) {
        guard let workout else { return }
        guard workout.intervals.indices.contains(index) else { return }
        var start = 0
        for i in 0..<index { start += workout.intervals[i].duration }
        setElapsed(start)
    }

    /// Compute current elapsed seconds from wall-clock. Source of truth while
    /// running.
    private func computeElapsedSeconds() -> Int {
        let active: TimeInterval = runStartDate.map { Date().timeIntervalSince($0) } ?? 0
        return Int((accumulatedRunTime + active).rounded(.down))
    }

    /// Re-anchor wall-clock to `secs` — used by skip controls.
    private func setElapsed(_ secs: Int) {
        let clamped = max(0, min(secs, totalDuration))
        accumulatedRunTime = TimeInterval(clamped)
        runStartDate = (state == .running) ? Date() : nil
        elapsedSeconds = clamped
        lastWarnedRemaining = -1
    }

    private func handleDidBecomeActive() {
        guard state == .running else { return }
        // Reschedule timer in case iOS killed it during suspend, then catch up.
        if timer == nil || !(timer?.isValid ?? false) {
            startTimer()
        }
        tick()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard state == .running else { return }
        let prev = currentContext
        let newElapsed = computeElapsedSeconds()

        if newElapsed >= totalDuration {
            elapsedSeconds = totalDuration
            accumulatedRunTime = TimeInterval(totalDuration)
            runStartDate = nil
            stopTimer()
            state = .completed
            onComplete?()
            return
        }

        elapsedSeconds = newElapsed
        let now = currentContext

        if let p = prev, let n = now, p.index != n.index {
            onIntervalChange?(n)
            onIntervalWarning?(0)
            lastWarnedRemaining = -1
        }

        if let n = now {
            let r = n.remaining
            if (r == 3 || r == 2 || r == 1) && r != lastWarnedRemaining {
                onIntervalWarning?(r)
                lastWarnedRemaining = r
            } else if r > 3 || r == 0 {
                lastWarnedRemaining = -1
            }
        }

        onTick?(now)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
