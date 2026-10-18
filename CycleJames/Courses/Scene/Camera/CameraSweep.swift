import Foundation
import SceneKit
import simd

// Development check used by the preview host (`-courseCameraSweep`): no
// part of a normal ride calls it.

/// Rides a fresh camera rig over the whole route in every mode (and parks
/// for the idle orbit every 20 m) without drawing, and reports how close the
/// camera came to the ground, buildings and the road, and how often the line
/// to the rider was blocked.
@MainActor
enum CameraSweep {
    static func run(world: CourseWorld, aspect: Float) async -> String {
        let route = world.route
        var out = ["Camera sweep, \(world.bundle.id), aspect \(aspect)", ""]
        let modes: [CameraMode?] = CameraMode.allCases + [nil]
        for mode in modes {
            let rig = CameraRig(world: world)
            rig.viewportAspect = aspect
            rig.mode = mode ?? .chase
            var stats = Stats()
            var frames = 0
            func frame(s: Double, running: Bool, dt: Double) {
                let speed = running ? 3.0 : 0
                let snap = RideSnapshot(
                    s: s, speedMps: speed, cadenceRpm: running ? 80 : 0, powerW: 0,
                    gradePct: route.grade(at: s), lateralM: 0.4, timestamp: 0, isRunning: running
                )
                let pose = route.pose(at: s, lateral: 0.4)
                rig.update(riderPose: pose, s: s, route: route, snapshot: snap, deltaTime: dt)
                stats.record(rig: rig, s: s, pose: pose, checkSight: mode != .firstPerson)
                frames += 1
            }
            if mode != nil {
                let dt = 1.0 / 30
                var s = 0.0
                frame(s: s, running: true, dt: 0)
                while s < route.length {
                    s = min(s + 3.0 * dt, route.length)
                    frame(s: s, running: true, dt: dt)
                    if frames % 300 == 0 { await Task.yield() }
                }
            } else {
                // Parked every 20 m for a full turn of the orbit.
                var s = 0.0
                while s <= route.length {
                    frame(s: s, running: false, dt: 0)
                    for _ in 0..<500 { frame(s: s, running: false, dt: 0.1) }
                    await Task.yield()
                    s += 20
                }
            }
            out.append(stats.summary(name: mode?.rawValue ?? "orbit (idle)", frames: frames))
        }
        return out.joined(separator: "\n")
    }

    private struct Stats {
        var minGround: (Float, Double) = (.infinity, 0)
        var minRoad: (Float, Double) = (.infinity, 0)
        var minTerrain: (Float, Double) = (.infinity, 0)
        var insideBlock = 0
        var groundViolations = 0
        var sightBlocked = 0
        var sightBlockedAt: [Int] = []
        var maxRaise: (Float, Double) = (0, 0)
        var minPull: (Float, Double) = (1, 0)
        var distance590: [Float] = []
        var height590: [Float] = []

        mutating func record(rig: CameraRig, s: Double, pose: RoutePose, checkSight: Bool) {
            let c = rig.clearance
            let eye = rig.node.simdWorldPosition
            let local = CourseSpace.local(eye)
            let rp = c.road(east: local.east, north: local.north, near: s)
            // Ground under the camera, as the rig models it.
            let ground = eye.y - c.groundTop(east: local.east, north: local.north, near: rp.s)
            if ground < minGround.0 { minGround = (ground, s) }
            if ground < 0.3 { groundViolations += 1 }
            // Above the road surface wherever the camera is over the carriageway.
            if abs(rp.lateral) <= Double(rp.halfWidth) {
                let road = eye.y - rp.elevation
                if road < minRoad.0 { minRoad = (road, s) }
            } else if abs(rp.lateral) > Double(rp.halfWidth) + 0.6 {
                // Off the road: the bare LiDAR terrain, independent of the road model.
                let t = c.terrain(east: local.east, north: local.north)
                if !t.isNaN, eye.y - t < minTerrain.0 { minTerrain = (eye.y - t, s) }
            }
            if c.isInsideBlock(eye) { insideBlock += 1 }
            let d = rig.debugState
            if d.raise > maxRaise.0 { maxRaise = (d.raise, s) }
            if d.pull < minPull.0 { minPull = (d.pull, s) }
            if checkSight {
                // Straight line from the rider's chest to the lens, no margin.
                let focus = pose.position + SIMD3(0, 1.05, 0)
                let v = eye - focus
                let n = max(4, Int(simd_length(v) / 0.25))
                for k in 1..<n {
                    let u = Float(k) / Float(n)
                    let p = focus + v * u
                    if c.solidTop(p, near: s + Double(u) * Double(simd_dot(v, pose.forward))) > p.y {
                        sightBlocked += 1
                        let bucket = Int(s / 10) * 10
                        if sightBlockedAt.last != bucket { sightBlockedAt.append(bucket) }
                        break
                    }
                }
            }
            if abs(s - 590) < 3 {
                distance590.append(simd_distance(eye, pose.position + SIMD3(0, 1.05, 0)))
                height590.append(eye.y - pose.position.y)
            }
        }

        func summary(name: String, frames: Int) -> String {
            func f(_ x: Float) -> String { x.isFinite ? String(format: "%.2f", x) : "-" }
            func range(_ a: [Float]) -> String {
                guard let lo = a.min(), let hi = a.max() else { return "-" }
                return "\(f(lo))–\(f(hi))"
            }
            return """
            [\(name)] \(frames) frames
              min above ground model \(f(minGround.0)) m at s=\(Int(minGround.1)); frames < 0.30 m: \(groundViolations)
              min above road surface \(f(minRoad.0)) m at s=\(Int(minRoad.1))
              min above bare terrain off-road \(f(minTerrain.0)) m at s=\(Int(minTerrain.1))
              inside building/trunk: \(insideBlock) frames
              sight line blocked: \(sightBlocked) frames, at s ≈ \(sightBlockedAt.prefix(30).map(String.init).joined(separator: ","))
              max raise \(f(maxRaise.0)) m at s=\(Int(maxRaise.1)); min pull \(f(minPull.0)) at s=\(Int(minPull.1))
              at s≈590: distance to rider \(range(distance590)) m, height over rider's road \(range(height590)) m

            """
        }
    }
}
