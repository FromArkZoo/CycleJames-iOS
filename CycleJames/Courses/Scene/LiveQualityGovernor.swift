import Foundation
import QuartzCore

/// Steps an automatic graphics tier down mid-ride when the phone can't hold
/// its frame rate or turns hot, without rebuilding the world. Each rung
/// sheds what can change live: one tier's shadows, grass reach, SSAO, bloom,
/// MSAA and frame rate, or the render scale. It never steps back up within a
/// ride; a phone that struggled once tends to again as it warms.
///
/// `frameRendered(at:)` runs on the render thread and returns a rung to
/// apply; the owner applies the scene parts there and the view parts on the
/// main thread. Only for an automatic tier: an explicit choice is kept.
final class LiveQualityGovernor: @unchecked Sendable {
    enum Rung: Equatable, CustomStringConvertible {
        /// That tier's live knobs (see `CourseSceneView.Coordinator.apply`).
        case tier(GraphicsQuality)
        /// Pixels per point to draw at (down from a 3x screen's native).
        case renderScale(Double)

        var description: String {
            switch self {
            case .tier(let q): "\(q.rawValue) effects"
            case .renderScale(let s): "render scale \(s)"
            }
        }
    }

    /// Seconds ignored after the world appears and after each step, while
    /// shaders compile and streaming settles.
    static let graceSeconds = 6.0
    /// Frame-rate sample length.
    static let windowSeconds = 3.0
    /// Consecutive slow windows that trigger a step.
    static let slowWindows = 2
    /// "Well below target": under this share of the target frame rate.
    static let slowShare = 0.72

    private let lock = NSLock()
    private var ladder: [Rung]
    private var targetFps: Double
    private var stepRequested: String?
    // Render thread only.
    private var lastFrame: CFTimeInterval = 0
    private var windowStart: CFTimeInterval = 0
    private var windowFrames = 0
    private var slowCount = 0
    private var quietUntil: CFTimeInterval

    private var _taken: [Rung] = []

    /// Rungs taken so far, newest last (development read-outs).
    var taken: [Rung] {
        lock.lock(); defer { lock.unlock() }
        return _taken
    }

    init(built quality: GraphicsQuality, screenScale: Double, targetFps: Int, now: CFTimeInterval = CACurrentMediaTime()) {
        var rungs: [Rung] = []
        var q = quality
        while let next = q.lower {
            // Fewer pixels before the last, plainest tier.
            if next == .battery, screenScale > 2.01 { rungs.append(.renderScale(2)) }
            rungs.append(.tier(next))
            q = next
        }
        ladder = rungs
        self.targetFps = Double(targetFps)
        quietUntil = now + Self.graceSeconds
    }

    /// The frame rate the view is asking for now (after any thermal cap).
    func setTargetFps(_ fps: Int) {
        lock.lock(); targetFps = Double(fps); lock.unlock()
    }

    /// Asks for a step at the next frame (the thermal state rose).
    func requestStep(reason: String) {
        lock.lock(); stepRequested = reason; lock.unlock()
    }

    /// Call once per rendered frame. Returns the rung to apply now, if any.
    func frameRendered(at now: CFTimeInterval) -> Rung? {
        lock.lock()
        let target = targetFps
        let requested = stepRequested
        stepRequested = nil
        let hasRungs = !ladder.isEmpty
        lock.unlock()
        guard hasRungs else { return nil }
        if let requested { return step(now: now, reason: requested) }

        // A long gap is a pause (backgrounded, covered), not slowness.
        if lastFrame == 0 || now - lastFrame > 0.5 { restartWindow(now) }
        lastFrame = now
        guard now >= quietUntil else { restartWindow(now); return nil }
        windowFrames += 1
        let elapsed = now - windowStart
        guard elapsed >= Self.windowSeconds else { return nil }
        let fps = Double(windowFrames) / elapsed
        restartWindow(now)
        if fps < target * Self.slowShare {
            slowCount += 1
        } else {
            slowCount = 0
        }
        guard slowCount >= Self.slowWindows else { return nil }
        return step(now: now, reason: String(format: "%.1f fps against %.0f", fps, target))
    }

    private func restartWindow(_ now: CFTimeInterval) {
        windowStart = now
        windowFrames = 0
    }

    private func step(now: CFTimeInterval, reason: String) -> Rung? {
        lock.lock()
        guard !ladder.isEmpty else { lock.unlock(); return nil }
        let rung = ladder.removeFirst()
        _taken.append(rung)
        lock.unlock()
        slowCount = 0
        quietUntil = now + Self.graceSeconds
        restartWindow(now)
        #if DEBUG
        Self.log("live quality: \(reason) -> \(rung)")
        #endif
        return rung
    }

    #if DEBUG
    /// Development aid: appended to the app's temporary directory
    /// (cj_live_quality.txt).
    static func log(_ text: String) {
        let line = String(format: "t %.2f ", CACurrentMediaTime()) + text + "\n"
        print(line, terminator: "")
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cj_live_quality.txt")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    #endif
}
