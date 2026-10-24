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
    /// Applies a cheaper tier's live scene knobs (sun shadows, grass reach)
    /// without rebuilding anything. Render thread.
    let applyLiveConfig: (WorldConfig) -> Void
    /// Sky visibility along the route (the light raster's), for the lane
    /// exposure and the rider's sky light.
    let light: LightProfile
    /// Brightens the world's lights by 2^ev (`SkyLighting.exposure`) for
    /// the camera opening up in a sunken lane (`LaneExposure`). Render
    /// thread, or before the world is shown.
    let setExposure: (Float) -> Void
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
        onFrame: @escaping (SIMD3<Float>, TimeInterval) -> Void = { _, _ in },
        applyLiveConfig: @escaping (WorldConfig) -> Void = { _ in },
        light: LightProfile = .open,
        setExposure: @escaping (Float) -> Void = { _ in }
    ) {
        self.scene = scene
        self.bundle = bundle
        self.quality = quality
        self.dynamicRoot = dynamicRoot
        self.sun = sun
        self.preferredFramesPerSecond = preferredFramesPerSecond
        self.configureCamera = configureCamera
        self.onFrame = onFrame
        self.applyLiveConfig = applyLiveConfig
        self.light = light
        self.setExposure = setExposure
    }
}
