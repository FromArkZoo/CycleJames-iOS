import Foundation
import CoreGraphics
import simd

/// Each region's sky, haze, sun and far view, as `SkyLighting`, the sea and
/// the far terrain read them. Flanders keeps the constants it was
/// calibrated with; the Riviera has the same sun (WorldSun: about 15:10
/// CET in late March at Sanremo) in clearer, drier air.
extension WorldLook {
    /// Base names of the baked background cube faces and of the lighting
    /// environment's: Flanders from scripts/courses/textures/
    /// bake_materials.py `bake_sky`, the Riviera from bake_sky_hdr.py,
    /// which also writes the HDR cube of the same name
    /// (`WorldTextures.hdrCube`) that `SkyLighting.install` prefers when
    /// the camera pass is there (`CoursePost.isAvailable`).
    var skyPrefix: String { isRiviera ? "cj_sky_lig" : "cj_sky" }
    var skyEnvPrefix: String { isRiviera ? "cj_skyenv_lig" : "cj_skyenv" }

    /// The colour below the horizon, linear, as the bake wrote it to
    /// scripts/courses/textures/cj_sky_horizon*.json: what the fog fades
    /// everything to. On the Riviera it is the far coast's and the sea
    /// horizon's blue-grey, a little darker than the haze band above it
    /// (look.md section 2), averaged all round: its air's light varies with
    /// the direction (`airBase`, `airGlow`). SkyBakeTests checks both.
    var horizonLinear: SIMD3<Double> {
        isRiviera ? SIMD3(0.3681, 0.4877, 0.6273) : SkyLighting.horizonLinear
    }

    /// Aerial perspective. Flanders: linear to the haze at 5.6 km, a hazy
    /// summer afternoon. The Riviera's air is clear, 20-40 km visibility:
    /// at exponent 0.75 the haze takes 7 % at 600 m (the sea below the
    /// road), 20 % at 2.5 km, 55 % at 10 km (the Alpi Liguri ridges,
    /// #85a3bb-#969daa), 93 % at 20 km (Capo Berta, Bordighera, faded to
    /// #9fb3c8) and all of it from 22 km, well short of the sea horizon
    /// (45-49 km out from 160 m). Out to 10 km that is about the real
    /// 1 - exp(-d / 12 km) of 30 km visibility.
    var fogEndDistance: CGFloat { isRiviera ? 22_000 : 5600 }
    var fogExponent: CGFloat { isRiviera ? 0.75 : 1 }

    /// The Riviera's air (`WorldShaders.aerialFragment`): the horizon's
    /// haze below the sky by direction, `airBase + airGlow * ((1 + cos a) /
    /// 2)^airPower`, a the azimuth from the sun's, linear, as the sky bake
    /// fitted it to the clear sky a degree up and wrote it to
    /// scripts/courses/textures/cj_sky_horizon_lig.json (bake_sky_hdr.py;
    /// SkyBakeTests checks the faces against it); the distance over which
    /// the air at sea level takes all but 1 / e of what is seen (about 40 km
    /// visibility); and the height over which it thins by e.
    var airBase: SIMD3<Double> { SIMD3(0.2773, 0.374, 0.4874) }
    var airGlow: SIMD3<Double> { SIMD3(0.3778, 0.4729, 0.582) }
    var airPower: Double { 5.25 }
    var airLengthM: Double { 10_000 }
    var airScaleHeightM: Double { 1500 }

    /// The camera's far clip: past the far terrain (Flanders), or past the
    /// sea horizon (the Riviera's sea reaches 62 km; from 160 m the earth's
    /// curve hides it beyond about 49 km). Depth precision near the camera
    /// is set by the near clip, so the longer reach costs nothing there.
    var zFar: CGFloat { isRiviera ? 64_000 : 7000 }

    /// The sun's shadow penumbra (`SCNLight.shadowRadius`) above the
    /// battery tier. Flemish late-summer haze softens the edges; on the
    /// Riviera's dry air the sun's half-degree disc leaves them nearly
    /// hard (about 3 cm at 3 m from the wall, look.md section 2).
    var shadowRadius: CGFloat { isRiviera ? 1.1 : 2.5 }

    /// The Riviera's land beyond the far grid's photo and its own sea
    /// (`TerrainBuilder.buildHorizon`, `SeaBuilder`) bends down with the
    /// earth, refraction included (k = 0.13, radius x 1.15): 7 m at 10 km,
    /// 27 m at 20 km, so the sea's horizon dips as it should.
    static let earthRadiusM: Double = 6_371_000 * 1.15
}
