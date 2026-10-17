import SceneKit

/// A built, ready-to-render course environment. Produced by
/// `CourseWorldBuilder`, consumed by `CourseSceneView`, which adds the rider
/// and camera under `dynamicRoot`.
final class CourseWorld {
    let scene: SCNScene
    let bundle: CourseBundle
    let quality: GraphicsQuality
    /// Parent for the rider, camera and anything else that moves.
    let dynamicRoot: SCNNode
    /// The key light; the camera rig may move it to keep the shadow
    /// cascades centred on the rider.
    let sun: SCNNode?
    /// Applies the world's look (HDR, exposure, bloom, SSAO, colour grading,
    /// clipping planes) to whichever camera is rendering it.
    let configureCamera: (SCNCamera) -> Void
    /// Called every frame on the render thread with the camera position, for
    /// streaming detail (grass, LOD swaps, shadow re-centring).
    let onFrame: (_ cameraPosition: SIMD3<Float>, _ time: TimeInterval) -> Void
    let preferredFramesPerSecond: Int

    var route: CourseRoute { bundle.route }

    init(
        scene: SCNScene,
        bundle: CourseBundle,
        quality: GraphicsQuality,
        dynamicRoot: SCNNode,
        sun: SCNNode?,
        preferredFramesPerSecond: Int,
        configureCamera: @escaping (SCNCamera) -> Void,
        onFrame: @escaping (SIMD3<Float>, TimeInterval) -> Void = { _, _ in }
    ) {
        self.scene = scene
        self.bundle = bundle
        self.quality = quality
        self.dynamicRoot = dynamicRoot
        self.sun = sun
        self.preferredFramesPerSecond = preferredFramesPerSecond
        self.configureCamera = configureCamera
        self.onFrame = onFrame
    }
}
