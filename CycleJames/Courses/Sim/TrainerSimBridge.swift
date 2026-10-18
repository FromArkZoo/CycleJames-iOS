import Foundation

/// The trainer commands a course ride needs. `FTMSManager` provides them;
/// tests use a recording fake.
@MainActor
protocol TrainerSimControl: AnyObject {
    var autoReconnectEnabled: Bool { get set }
    /// False when nothing was written (the app doesn't hold control).
    @discardableResult
    func setSimulation(grade: Double, crr: Double, cw: Double) -> Bool
    func startTraining()
    func stopTraining()
    func requestControlIfNeeded()
}

extension FTMSManager: TrainerSimControl {}

/// Drives a smart trainer in simulation mode from the rider's position on
/// the course: the gradient just ahead (covers the trainer's response lag),
/// scaled by the trainer-difficulty setting (descents at half of it, as
/// Zwift does), clamped, rate limited, plus the road surface's rolling
/// resistance so cobbles feel harder. Only the trainer sees this gradient;
/// the ride physics always uses the real one.
@MainActor
final class TrainerSimBridge {
    struct Config: Equatable, Sendable {
        /// 100 sends the real gradient, 0 a flat road.
        var difficultyPct: Int = 100
        /// Extra scale on descents, on top of the difficulty.
        var descentFactor: Double = 0.5
        /// Trainers clamp further to their own limits.
        var gradeRange: ClosedRange<Double> = -10...25
        /// At most 2 commands a second.
        var minSendInterval: TimeInterval = 0.5
        /// Smaller gradient changes aren't worth a BLE write.
        var minGradeChangePct: Double = 0.1
        /// Wind-resistance coefficient, kg/m (FTMS default).
        var cw: Double = 0.51
    }

    weak var target: TrainerSimControl?
    var config: Config

    /// Gradient of the last command the trainer took, after difficulty
    /// scaling and clamping. Unchanged by commands it wasn't sent because
    /// the app lacks control.
    private(set) var lastSentGradePct: Double = 0
    private(set) var lastSentCrr: Double?
    /// Between `begin()` and `end()`.
    private(set) var isActive = false
    /// Paused: resistance held at a flat road until `resume()`.
    private(set) var isHolding = false

    private var lastSendTime: TimeInterval = -.infinity
    private var forceNext = true

    init(target: TrainerSimControl? = nil, config: Config = Config()) {
        self.target = target
        self.config = config
    }

    /// Gradient to send for a course gradient.
    nonisolated static func trainerGrade(courseGradePct grade: Double, config: Config) -> Double {
        let scale = Double(config.difficultyPct.clamped(to: 0...100)) / 100
        let scaled = grade >= 0 ? grade * scale : grade * scale * config.descentFactor
        return scaled.clamped(to: config.gradeRange)
    }

    /// Distance ahead of the rider over which the gradient is averaged:
    /// about a second of riding, 3–5 m.
    nonisolated static func lookAheadM(speedMps: Double) -> Double {
        min(max(speedMps, 3), 5)
    }

    /// Ride started: take the trainer into training and arm reconnects.
    func begin() {
        isActive = true
        isHolding = false
        forceNext = true
        lastSendTime = -.infinity
        target?.autoReconnectEnabled = true
        target?.requestControlIfNeeded()
        target?.startTraining()
    }

    /// Called every physics tick while riding with the look-ahead course
    /// gradient and the surface's Crr. Returns true when a command went out.
    /// Without control nothing goes out, and the next tick tries again.
    @discardableResult
    func update(courseGradePct: Double, crr: Double, now: TimeInterval) -> Bool {
        guard isActive, !isHolding else { return false }
        let grade = Self.trainerGrade(courseGradePct: courseGradePct, config: config)
        if !forceNext {
            guard now - lastSendTime >= config.minSendInterval else { return false }
            let gradeMoved = abs(grade - lastSentGradePct) >= config.minGradeChangePct - 1e-9
            guard gradeMoved || crr != lastSentCrr else { return false }
        }
        return send(grade: grade, crr: crr, now: now)
    }

    /// Paused: a flat road until `resume()`.
    func hold(now: TimeInterval) {
        guard isActive, !isHolding else { return }
        isHolding = true
        send(grade: 0, crr: lastSentCrr ?? 0.004, now: now)
    }

    func resume() {
        guard isActive else { return }
        isHolding = false
        forceNext = true
    }

    /// The trainer (re)gained control mid-ride, e.g. after a reconnect:
    /// restart training and resend the current state.
    func resync(now: TimeInterval) {
        guard isActive else { return }
        target?.startTraining()
        if isHolding {
            send(grade: 0, crr: lastSentCrr ?? 0.004, now: now)
        } else {
            forceNext = true
        }
    }

    /// Ride over (finished, discarded or abandoned): flat road, stop training.
    func end() {
        guard isActive else { return }
        target?.setSimulation(grade: 0, crr: lastSentCrr ?? 0.004, cw: config.cw)
        target?.autoReconnectEnabled = false
        target?.stopTraining()
        isActive = false
        isHolding = false
        lastSentGradePct = 0
        lastSentCrr = nil
        lastSendTime = -.infinity
        forceNext = true
    }

    /// Records the command only when the trainer took it; otherwise the
    /// next update sends regardless of the rate limit.
    @discardableResult
    private func send(grade: Double, crr: Double, now: TimeInterval) -> Bool {
        // No trainer attached (tests, the Simulator): nothing can refuse it.
        let written = target?.setSimulation(grade: grade, crr: crr, cw: config.cw) ?? true
        guard written else {
            forceNext = true
            return false
        }
        lastSentGradePct = grade
        lastSentCrr = crr
        lastSendTime = now
        forceNext = false
        return true
    }
}
