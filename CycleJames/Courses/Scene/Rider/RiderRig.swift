import SceneKit
import UIKit

/// The rider and bike, posed on the road every frame.
///
/// PLACEHOLDER: a box-and-capsule stand-in with a spinning wheel so the scene
/// view can be wired up. The full procedural cyclist (pedalling legs on the
/// crank, standing on steep ramps, spinning spoked wheels) replaces this file;
/// keep the public API.
final class RiderRig {
    let node = SCNNode()
    private let wheel: SCNNode
    private var wheelAngle: Float = 0

    init(quality: GraphicsQuality) {
        let body = SCNNode(geometry: SCNCapsule(capRadius: 0.18, height: 1.2))
        body.geometry?.firstMaterial?.diffuse.contents = UIColor(red: 1, green: 0.55, blue: 0.18, alpha: 1)
        body.position = SCNVector3(0, 1.15, 0)
        body.eulerAngles.x = -0.9
        node.addChildNode(body)

        wheel = SCNNode(geometry: SCNTorus(ringRadius: 0.33, pipeRadius: 0.02))
        wheel.geometry?.firstMaterial?.diffuse.contents = UIColor(white: 0.1, alpha: 1)
        wheel.eulerAngles.z = .pi / 2
        wheel.position = SCNVector3(0, 0.34, -0.5)
        node.addChildNode(wheel)
    }

    /// Called every frame on the render thread.
    func update(pose: RoutePose, snapshot: RideSnapshot, deltaTime: Double) {
        node.simdTransform = pose.transform
        wheelAngle += Float(snapshot.speedMps / 0.34 * deltaTime)
        wheel.eulerAngles.y = wheelAngle
    }
}
