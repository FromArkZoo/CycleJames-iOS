import Foundation
import simd

// Critically damped springs for the camera rig. Each step uses the exact
// closed-form solution for a target held still over the step, so the motion
// is the same at 30, 60 or 120 fps and never overshoots.

/// Spring for a position or offset.
struct CameraSpring3 {
    var value: SIMD3<Float>
    var velocity: SIMD3<Float> = .zero

    init(_ value: SIMD3<Float> = .zero) {
        self.value = value
    }

    /// `omega` is the natural frequency in rad/s: the spring covers ~63 % of
    /// a step change in about `1.7 / omega` seconds.
    mutating func step(toward target: SIMD3<Float>, omega: Float, dt: Float) {
        guard dt > 0 else { return }
        let x = value - target
        let decay = exp(-omega * dt)
        let temp = (velocity + omega * x) * dt
        velocity = (velocity - omega * temp) * decay
        value = target + (x + temp) * decay
    }

    mutating func snap(to target: SIMD3<Float>) {
        value = target
        velocity = .zero
    }
}

/// Spring for a single value, optionally faster in one direction (e.g. pull
/// the camera in quickly when the view is blocked, let it out slowly).
struct CameraSpring1 {
    var value: Float
    var velocity: Float = 0

    init(_ value: Float = 0) {
        self.value = value
    }

    mutating func step(toward target: Float, omega: Float, dt: Float) {
        guard dt > 0 else { return }
        let x = value - target
        let decay = exp(-omega * dt)
        let temp = (velocity + omega * x) * dt
        velocity = (velocity - omega * temp) * decay
        value = target + (x + temp) * decay
    }

    /// Uses `rising` while the target is above the value, `falling` below.
    mutating func step(toward target: Float, rising: Float, falling: Float, dt: Float) {
        step(toward: target, omega: target > value ? rising : falling, dt: dt)
    }

    mutating func snap(to target: Float) {
        value = target
        velocity = 0
    }
}

/// Small helpers shared by the camera files (namespaced so they can't clash
/// with extensions elsewhere in the app).
enum CameraMath {
    /// 0 → 0, 1 → 1, with zero slope and curvature at both ends.
    @inline(__always)
    static func smootherstep(_ x: Float) -> Float {
        let t = min(max(x, 0), 1)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    @inline(__always)
    static func radians(_ degrees: Float) -> Float { degrees * .pi / 180 }

    @inline(__always)
    static func degrees(_ radians: Float) -> Float { radians * 180 / .pi }

    /// Horizontal part of a vector, normalised; `nil` when it is too short.
    @inline(__always)
    static func horizontalUnit(_ v: SIMD3<Float>, minLength: Float = 1e-4) -> SIMD3<Float>? {
        let h = SIMD3(v.x, 0, v.z)
        let len = simd_length(h)
        return len > minLength ? h / len : nil
    }

    /// Rotates a vector about the world vertical by `angle` radians
    /// (positive turns east towards south, i.e. clockwise seen from above).
    @inline(__always)
    static func rotateAboutUp(_ v: SIMD3<Float>, _ angle: Float) -> SIMD3<Float> {
        let c = cos(angle), s = sin(angle)
        return SIMD3(v.x * c - v.z * s, v.y, v.x * s + v.z * c)
    }

    /// Wraps an angle into (−π, π].
    @inline(__always)
    static func wrap(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: 2 * .pi)
        if x > .pi { x -= 2 * .pi }
        if x <= -.pi { x += 2 * .pi }
        return x
    }
}
