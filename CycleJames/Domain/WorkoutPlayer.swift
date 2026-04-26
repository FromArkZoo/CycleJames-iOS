import Foundation
import Combine

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

    func load(_ workout: Workout, ftp: Int) {
        stopTimer()
        self.workout = workout
        self.ftp = ftp
        self.elapsedSeconds = 0
        self.state = .ready
    }

    func start() {
        guard workout != nil, state != .running else { return }
        stopTimer()
        state = .running
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        onTick?(currentContext)
    }

    func pause() {
        guard state == .running else { return }
        state = .paused
        stopTimer()
    }

    func resume() {
        guard state == .paused else { return }
        state = .running
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        stopTimer()
        elapsedSeconds = 0
        state = .idle
    }

    func skipForward() {
        guard let ctx = currentContext, let workout else { return }
        let nextStart = ctx.intervalStart + ctx.interval.duration
        if nextStart < workout.totalDuration {
            elapsedSeconds = nextStart
        }
    }

    func skipBackward() {
        guard let ctx = currentContext, let workout else { return }
        if elapsedSeconds - ctx.intervalStart > 2 {
            elapsedSeconds = ctx.intervalStart
        } else if ctx.index > 0 {
            var start = 0
            for i in 0..<(ctx.index - 1) {
                start += workout.intervals[i].duration
            }
            elapsedSeconds = start
        } else {
            elapsedSeconds = 0
        }
    }

    private func tick() {
        guard state == .running else { return }
        let prev = currentContext
        elapsedSeconds += 1

        if elapsedSeconds >= totalDuration {
            elapsedSeconds = totalDuration
            stopTimer()
            state = .completed
            onComplete?()
            return
        }

        let now = currentContext

        if let p = prev, let n = now, p.index != n.index {
            onIntervalChange?(n)
            onIntervalWarning?(0)
        }

        if let n = now {
            let r = n.remaining
            if r == 3 || r == 2 || r == 1 {
                onIntervalWarning?(r)
            }
        }

        onTick?(now)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
