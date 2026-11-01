import SceneKit

/// The materials as a whole: made up front while the textures upload, and
/// kept in step with the live quality tier.
extension WorldMaterials {
    /// Touched once while the textures upload (`CourseWorldBuilder`), so
    /// their textures are made, and checked for a failed upload, before the
    /// meshes need them. Draped and other `copy()`-made variants included.
    var warmUp: [SCNMaterial] {
        [terrain, verge, cobbles, sideCobbles, pavementSetts, asphalt, sideAsphalt, kerb, concrete, gutter,
         cycleLane, leaves, bark, impostor, grass, walls, signFace] + roofParts + roadsideProps
    }

    /// A live fallback step (render thread): the material uniforms that
    /// depend on the tier. The grass reach is `FrameUpdater`'s.
    func applyLive(_ live: WorldConfig) {
        applySettTier(live.quality)
        applyLight(live)
    }
}
