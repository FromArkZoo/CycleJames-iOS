import Foundation
import QuartzCore

/// The latest physics state, handed from the ride controller (main thread)
/// to the 3D renderer (SceneKit's render thread). The renderer extrapolates
/// `s` by `speedMps` between physics updates so motion stays smooth at the
/// display's frame rate.
struct RideSnapshot: Sendable, Equatable {
    /// Distance along the route at `timestamp`, metres.
    var s: Double = 0
    var speedMps: Double = 0
    var cadenceRpm: Double = 0
    var powerW: Double = 0
    var gradePct: Double = 0
    /// Lateral offset from the centreline, metres, positive = right.
    var lateralM: Double = 0
    /// `CACurrentMediaTime()` when this state was computed.
    var timestamp: CFTimeInterval = 0
    /// False before the start, while paused and after the finish.
    var isRunning: Bool = false

    /// Distance at `time`, extrapolated at constant speed for at most
    /// `maxAhead` seconds so a stalled producer can't run the rider away.
    func extrapolatedS(at time: CFTimeInterval, maxAhead: Double = 0.25, routeLength: Double) -> Double {
        guard isRunning else { return s }
        let dt = min(max(time - timestamp, 0), maxAhead)
        return min(s + speedMps * dt, routeLength)
    }
}

/// Lock-protected mailbox for `RideSnapshot`. Written on the main thread,
/// read every frame on the render thread.
final class RideStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = RideSnapshot()

    func write(_ new: RideSnapshot) {
        lock.lock(); snapshot = new; lock.unlock()
    }

    func read() -> RideSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }
}
