import SceneKit

enum CameraMode: String, CaseIterable, Sendable {
    /// Behind and above the rider, like Zwift's default view.
    case chase
    /// Low and tight behind the rear wheel.
    case close
    /// Rider's eye view over the bars.
    case firstPerson
    /// Side-on, slightly ahead, like a race moto camera.
    case broadcast

    var label: String {
        switch self {
        case .chase: "Chase"
        case .close: "Close"
        case .firstPerson: "Rider view"
        case .broadcast: "Broadcast"
        }
    }

    var next: CameraMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Follows the rider.
///
/// PLACEHOLDER: a rigid chase camera. The full rig (spring-smoothed follow
/// that looks up the road, per-mode framing, cuts between modes) replaces
/// this file; keep the public API.
final class CameraRig {
    let node = SCNNode()
    var mode: CameraMode = .chase

    init(world: CourseWorld) {
        let camera = SCNCamera()
        world.configureCamera(camera)
        node.camera = camera
        node.name = "camera"
    }

    /// Called every frame on the render thread after the rider has moved.
    func update(riderPose: RoutePose, s: Double, route: CourseRoute, snapshot: RideSnapshot, deltaTime: Double) {
        let ahead = route.pose(at: s + 12).position + SIMD3(0, 1.2, 0)
        let eye = riderPose.position - riderPose.forward * 5 + SIMD3(0, 2.2, 0)
        node.simdPosition = eye
        node.simdLook(at: ahead, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
    }
}
