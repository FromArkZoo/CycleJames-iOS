import Foundation

/// Per-tier knobs for the course environment. Every distance is metres; the
/// "route" distances are measured from the centreline (the camera never
/// strays far from it), the "camera" ones from the point of view at render
/// time.
struct WorldConfig: Sendable {
    let quality: GraphicsQuality

    // Terrain grid: lattice spacing by distance from the route.
    var terrain1mRadius: Double
    var terrain2mRadius: Double
    var terrain4mRadius: Double
    /// Far (10 m) grid: spacing doubles at these distances from the near grid.
    var far10mRadius: Double
    var far20mRadius: Double
    /// Road-aligned verge mesh beside the carriageway, each side.
    var vergeWidth: Double

    // Shadows.
    var shadowDistance: Double
    var shadowCascades: Int
    var shadowMapSize: Int
    var shadowSamples: Int

    // Vegetation.
    /// Trees nearer the route than this get full branch-and-card geometry.
    var treeDetailRouteRadius: Double
    /// Camera distance at which full trees swap to the light version.
    var treeDetailCameraDistance: Double
    /// Camera distance at which light trees swap to impostors.
    var treeImpostorDistance: Double
    var shrubDetailRouteRadius: Double
    var shrubMaxRouteRadius: Double
    var bankPlantDensity: Double
    var grassDensity: Double
    /// Camera distance at which verge grass has shrunk away; it grows to
    /// full height over `WorldShaders.grassFadeLength` inside it.
    var grassRadius: Double
    /// The verge's sward (`VegetationBuilder`), streamed with the verge
    /// grass: the spacing along the road of its row of short tufts over the
    /// road's edge, metres (never under 0.3), which also sets how much
    /// rough-sward ribbon stands beyond the mown strip (about 4 m per metre
    /// of road and side at 0.33); 0 = no sward.
    var swardFinSpacing: Double { quality == .high ? 0.22 : quality == .balanced ? 0.33 : 0 }
    /// Share of the tall verge tufts beyond a metre from the road that
    /// flower (wild carrot, knapweed and yarrow, tansy).
    var flowerShare: Double { quality == .high ? 0.14 : quality == .balanced ? 0.1 : 0 }

    // Look.
    var ssao: Bool
    var bloom: Bool
    var terrainNormalDetail: Bool
    var textureLimit: Int
    var fps: Int

    static func make(_ q: GraphicsQuality) -> WorldConfig {
        switch q {
        case .high:
            return WorldConfig(
                quality: q,
                terrain1mRadius: 64, terrain2mRadius: 190, terrain4mRadius: 430,
                far10mRadius: 500, far20mRadius: 1400, vergeWidth: 13,
                shadowDistance: 150, shadowCascades: 3, shadowMapSize: 2048, shadowSamples: 4,
                treeDetailRouteRadius: 110, treeDetailCameraDistance: 95, treeImpostorDistance: 330,
                shrubDetailRouteRadius: 55, shrubMaxRouteRadius: 900,
                bankPlantDensity: 1.0, grassDensity: 5.0, grassRadius: 38,
                ssao: true, bloom: true, terrainNormalDetail: true, textureLimit: 4096, fps: 60
            )
        case .balanced:
            return WorldConfig(
                quality: q,
                terrain1mRadius: 36, terrain2mRadius: 130, terrain4mRadius: 330,
                far10mRadius: 350, far20mRadius: 1100, vergeWidth: 12,
                shadowDistance: 90, shadowCascades: 2, shadowMapSize: 2048, shadowSamples: 2,
                treeDetailRouteRadius: 80, treeDetailCameraDistance: 70, treeImpostorDistance: 240,
                shrubDetailRouteRadius: 35, shrubMaxRouteRadius: 450,
                bankPlantDensity: 0.8, grassDensity: 2.6, grassRadius: 28,
                ssao: false, bloom: true, terrainNormalDetail: true, textureLimit: 2048, fps: 60
            )
        case .battery:
            return WorldConfig(
                quality: q,
                terrain1mRadius: 16, terrain2mRadius: 70, terrain4mRadius: 220,
                far10mRadius: 250, far20mRadius: 800, vergeWidth: 9,
                shadowDistance: 45, shadowCascades: 1, shadowMapSize: 1024, shadowSamples: 1,
                treeDetailRouteRadius: 45, treeDetailCameraDistance: 45, treeImpostorDistance: 160,
                shrubDetailRouteRadius: 18, shrubMaxRouteRadius: 160,
                bankPlantDensity: 0.55, grassDensity: 0, grassRadius: 0,
                ssao: false, bloom: false, terrainNormalDetail: false, textureLimit: 1024, fps: 30
            )
        }
    }
}

/// Fixed light and atmosphere for the Flemish Ardennes on a late-summer
/// afternoon (late August, about 16:30 CEST). The baked sky textures were
/// rendered with the same sun, so keep the two in step with
/// scripts/courses/textures/bake_materials.py.
enum WorldSun {
    /// Compass azimuth of the sun, degrees clockwise from north (south-west).
    static let azimuthDeg: Double = 232
    static let elevationDeg: Double = 34

    /// Unit vector from the ground towards the sun, scene space.
    static var toSun: SIMD3<Float> {
        let az = azimuthDeg * .pi / 180, el = elevationDeg * .pi / 180
        let east = sin(az) * cos(el), north = cos(az) * cos(el), up = sin(el)
        return SIMD3(Float(east), Float(up), Float(-north))
    }
}
