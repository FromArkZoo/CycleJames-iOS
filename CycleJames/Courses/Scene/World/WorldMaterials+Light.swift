import SceneKit
import UIKit
import Metal

/// The course's baked light raster on the ground, the road, the setts and
/// the house walls (`WorldShaders+Light`): sky visibility as ambient occlusion, the sun's
/// shade past the shadow map, the setts' micro-shadows off in shade.
extension WorldMaterials {
    /// scripts/courses/textures/bake_light_maps.py: R sky visibility, G sun
    /// visibility, B canopy height / 40 m, A ground height, 1 px per metre
    /// over the near terrain grid. Kept at that above the battery tier, like
    /// the splat map (battery drops the top mips: 2-4 m per pixel, plenty
    /// for occlusion). Open, sunlit, flat ground when the course has none.
    /// Uploaded from the pixels the world build decoded for the plants and
    /// the lane meter (`WorldTextures.adopt`), or else from the file.
    func makeLightRaster() -> MTLTexture? {
        // Alpha 1, not 0: a transparent 1 x 1 would come out premultiplied,
        // (0, 0, 0, 0), which reads as "no sky" and turns the ambient black.
        let open = { self.textures.metal(image: WorldTextures.solid(UIColor(red: 1, green: 1, blue: 0, alpha: 1)), srgb: false) }
        #if DEBUG
        // -lightRasterOff: open, sunlit ground everywhere, to judge the
        // raster against none in the same build.
        if ProcessInfo.processInfo.arguments.contains("-lightRasterOff") { return open() }
        #endif
        return textures.metal("\(bundle.id)_light", srgb: false, cap: textures.limit > 1024 ? 4096 : nil) ?? open()
    }

    /// World (x, z) to raster uv as `xz * xy + zw` (scene z points south),
    /// as `orthoTransform` maps the photo over the same footprint.
    var lightUV: SCNVector4 {
        let t = bundle.terrainNear
        let sx = Float(1 / t.widthM), sy = Float(1 / t.heightM)
        return SCNVector4(sx, sy, Float(-t.originEast) * sx, Float(t.originNorth) * sy)
    }

    /// x: the sun-to-sky irradiance ratio for a surface facing the sun
    /// (`litchart` after the sky re-bake: a 0.18 board 3.67 times brighter
    /// in sun than in shade, so (3.67 - 1) / sin 34 deg = 4.8). y, z: the
    /// camera depths over which the baked sun shade takes over from the
    /// shadow map, which ends at `shadowDistance`. w: the floor on sky
    /// visibility, for the bounce light the bake leaves out, and high
    /// enough that a sunken lane's shade still reads on a phone: at 0.6 the
    /// Koppenberg's shaded setts at s 590 sit at about sRGB 37 (0.45 took
    /// them to 28, murky), with sunflecks 5.5 times brighter (4.1 without
    /// the raster); the lane exposure (`LaneExposure`, +0.75 EV there)
    /// lifts that shade to about sRGB 50. Measured at 0.5 with the
    /// exposure: 46, sunflecks 6.5 times brighter, and no visible gain, so
    /// it stays. Lower on high, which adds SSAO; higher on battery, which
    /// has the least shade.
    static func lightK(_ config: WorldConfig) -> SCNVector4 {
        var minSky: Float = switch config.quality {
        case .high: 0.55
        case .balanced: 0.6
        case .battery: 0.65
        }
        #if DEBUG
        // -lightFloor 0.5: try another floor without a rebuild.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-lightFloor"), i + 1 < args.count, let v = Float(args[i + 1]) { minSky = v }
        #endif
        return SCNVector4(4.8, Float(config.shadowDistance * 0.88), Float(config.shadowDistance), minSky)
    }

    /// `lightK`'s floor on sky visibility, for the plants (`SkyRaster`).
    static func skyFloor(_ config: WorldConfig) -> Float { Float(lightK(config).w) }

    /// Every material whose surface splices `WorldShaders.lightArgs` must
    /// get all of these, copies included (`setValue` after `copy()`
    /// doesn't reach the copy): an unset texture samples 0 (black ambient),
    /// an unset float is 0.
    func bindLight(_ m: SCNMaterial) {
        bind(m, "lightTex", lightRaster)
        m.setValue(NSValue(scnVector4: lightUV), forKey: "lightUV")
        m.setValue(NSValue(scnVector4: Self.lightK(config)), forKey: "lightK")
        let s = WorldSun.toSun
        m.setValue(NSValue(scnVector3: SCNVector3(s.x, s.y, s.z)), forKey: "lightSun")
    }

    /// The materials carrying the light raster, draped and other copies
    /// included.
    var lit: [SCNMaterial] {
        [terrain, verge, cobbles, sideCobbles, pavementSetts, asphalt, sideAsphalt, kerb, concrete, gutter, cycleLane, walls]
    }

    /// A live tier step: the baked sun shade starts where the new tier's
    /// shadow map ends, so no band is left without shadow.
    func applyLight(_ live: WorldConfig) {
        let k = NSValue(scnVector4: Self.lightK(live))
        for m in lit { m.setValue(k, forKey: "lightK") }
    }
}
