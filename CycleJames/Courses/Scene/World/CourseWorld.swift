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
    /// Called every frame on the render thread with the camera's position
    /// and the way it looks, for streaming detail (grass, LOD swaps) and
    /// placing the sun's shadow map.
    let onFrame: (_ cameraPosition: SIMD3<Float>, _ cameraForward: SIMD3<Float>, _ time: TimeInterval) -> Void
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
    /// The region's camera response (`CoursePost`), for whatever draws the
    /// scene: the ride's view, a snapshot renderer. Nil where SceneKit's
    /// own camera is the look (the Flemish climbs).
    let post: SCNTechnique?
    /// The region the world is drawn as.
    let look: WorldLook
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
        onFrame: @escaping (SIMD3<Float>, SIMD3<Float>, TimeInterval) -> Void = { _, _, _ in },
        applyLiveConfig: @escaping (WorldConfig) -> Void = { _ in },
        light: LightProfile = .open,
        setExposure: @escaping (Float) -> Void = { _ in },
        post: SCNTechnique? = nil,
        look: WorldLook = .flanders
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
        self.post = post
        self.look = look
    }
}
