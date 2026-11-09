import XCTest
import SceneKit
import Metal
@testable import CycleJames

/// The Riviera's camera response (`CoursePost`), its high-dynamic-range sky
/// (`WorldTextures.hdrCube`, bake_sky_hdr.py) and its air
/// (`WorldShaders.aerialFragment`): the pass compiles, undoes SceneKit's
/// curve exactly, and only the Riviera is drawn through any of it.
final class CoursePostTests: XCTestCase {
    private func bundle(_ id: String) throws -> CourseBundle {
        do {
            return try CourseBundle.load(id: id)
        } catch {
            throw XCTSkip("\(id) data not in the test host bundle: \(error)")
        }
    }

    /// The Metal source compiles on this GPU and SceneKit takes the pass.
    func test_thePassCompiles() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        XCTAssertNotNil(CoursePost.technique(CoursePost.Settings()))
    }

    /// The pass's inverse of SceneKit's curve gives the radiance back, from
    /// near black (where the plain quadratic formula loses its digits) to
    /// the white point.
    func test_theCurveIsUndoneExactly() {
        for x in [0.0, 1e-4, 0.003, 0.05, 0.18, 0.6, 1, 2.5, 8, 15.9] {
            let y = CoursePost.sceneKitCurve(x)
            XCTAssertLessThanOrEqual(y, 1, "\(x) fits under the display's white")
            XCTAssertEqual(CoursePost.radiance(y), x, accuracy: max(x, 1e-4) * 1e-6, "\(x)")
        }
        // At a white point of 1 SceneKit's curve is the identity: the
        // camera the Flemish climbs keep.
        XCTAssertEqual(CoursePost.sceneKitCurve(0.37, w: 1), 0.37, accuracy: 1e-12)
        // The curve as measured from the chart at white points 4 and 16
        // (`WorldDebugShots` chart-raw: 1.0 read 0.533 and 0.503, 2.5 read
        // 0.823 and 0.723).
        XCTAssertEqual(CoursePost.sceneKitCurve(1, w: 4), 0.533, accuracy: 0.004)
        XCTAssertEqual(CoursePost.sceneKitCurve(2.5, w: 4), 0.823, accuracy: 0.004)
        XCTAssertEqual(CoursePost.sceneKitCurve(1, w: 16), 0.503, accuracy: 0.004)
        XCTAssertEqual(CoursePost.sceneKitCurve(2.5, w: 16), 0.723, accuracy: 0.004)
    }

    /// AgX: middle grey lands in the middle of the display's range, the
    /// curve rises all the way, and it tops out at the camera's white
    /// point, so SceneKit's encoding clips nothing the display could show.
    func test_agxPutsMiddleGreyInTheMiddle() {
        XCTAssertEqual(CoursePost.agxEncoded(0.18), 0.5, accuracy: 0.01)
        XCTAssertEqual(CoursePost.agxEncoded(0), 0, accuracy: 0.01)
        XCTAssertEqual(CoursePost.agxEncoded(CoursePost.whitePoint), 1, accuracy: 0.01)
        XCTAssertEqual(pow(2, CoursePost.agxMaxEV), CoursePost.whitePoint, accuracy: 0.5)
        var last = -1.0
        for stop in stride(from: -12.0, through: 4.0, by: 0.25) {
            let v = CoursePost.agxEncoded(pow(2, stop))
            XCTAssertGreaterThan(v, last, "at \(stop) stops")
            last = v
        }
        // A sunlit white wall (about 1.6 in the scene's units) keeps a
        // tenth of the range above it for the sky round the sun and glints.
        XCTAssertEqual(CoursePost.agxEncoded(1.6), 0.85, accuracy: 0.02)
    }

    /// The Riviera's camera encodes at the pass's white point and leaves
    /// nothing after SceneKit's curve that the pass couldn't undo; the
    /// Flemish camera is as it was.
    func test_onlyTheRivierasCameraEncodesForThePass() {
        let riviera = SCNCamera(), flemish = SCNCamera()
        SkyLighting.configure(riviera, config: .make(.high), look: .riviera)
        SkyLighting.configure(flemish, config: .make(.high), look: .flanders)
        XCTAssertEqual(Double(riviera.whitePoint), CoursePost.whitePoint)
        XCTAssertEqual(riviera.contrast, 0)
        XCTAssertEqual(riviera.saturation, 1)
        XCTAssertEqual(riviera.vignettingIntensity, 0)
        XCTAssertGreaterThan(riviera.bloomThreshold, 1.6, "a sunlit white wall doesn't bloom")
        XCTAssertEqual(flemish.whitePoint, 1)
        XCTAssertEqual(flemish.contrast, 0.05, accuracy: 1e-6)
        XCTAssertEqual(flemish.saturation, 1.06, accuracy: 1e-6)
        XCTAssertEqual(flemish.bloomThreshold, 1)
    }

    /// Every material of the Poggio draws the air (one that didn't would
    /// stand out unhazed at any distance), once; no Flemish material does,
    /// and the Flemish scene keeps SceneKit's fog.
    func test_everyRivieraMaterialDrawsTheAirAndNoFlemishOne() throws {
        let poggio = try bundle("poggio")
        let p = WorldMaterials(config: .make(.balanced), textures: WorldTextures(limit: 2048), bundle: poggio,
                               art: CourseArt.make(bundle: poggio))
        XCTAssertTrue(p.drawsAir)
        let sea = p.makeSea()
        p.airEverything()
        p.airEverything()
        p.air(sea)
        for m in p.everyMaterial + [sea] {
            let fragment = m.shaderModifiers?[.fragment] ?? ""
            XCTAssertEqual(fragment.components(separatedBy: "float cjAd").count, 2,
                           "\(m.shaderModifiers?[.surface]?.prefix(50) ?? "plain"): the air, once")
        }
        let kop = try bundle("koppenberg")
        let k = WorldMaterials(config: .make(.balanced), textures: WorldTextures(limit: 2048), bundle: kop,
                               art: CourseArt.make(bundle: kop))
        XCTAssertFalse(k.drawsAir)
        k.airEverything()
        for m in k.everyMaterial {
            XCTAssertFalse(m.shaderModifiers?[.fragment]?.contains("cjAd") ?? false)
        }
        let scene = SCNScene()
        _ = SkyLighting.install(in: scene, config: .make(.balanced), textures: WorldTextures(limit: 2048), look: .flanders)
        XCTAssertEqual(scene.fogEndDistance, WorldLook.flanders.fogEndDistance)
        let coast = SCNScene()
        _ = SkyLighting.install(in: coast, config: .make(.balanced), textures: WorldTextures(limit: 2048), look: .riviera)
        XCTAssertEqual(coast.fogEndDistance, 0, "the Riviera's materials draw its air")
    }

    /// The air's light at the horizon: what the shader fades to, by
    /// compass azimuth (radians), as `WorldShaders.aerialFragment` has it.
    private func air(azimuth: Double) -> SIMD3<Double> {
        let look = WorldLook.riviera
        let c = cos(azimuth - WorldSun.azimuthDeg * .pi / 180)
        return look.airBase + look.airGlow * pow(0.5 + 0.5 * c, look.airPower)
    }

    /// The baked sky below the horizon is the air's light in each
    /// direction, so the far sea and land fade into it without a seam: the
    /// HDR cube's side faces along their bottom rows (45 degrees down).
    /// The bake mirrors z (SceneKit looks its cubes up that way round), so
    /// the +z face holds the north.
    func test_theHdrSkyBelowTheHorizonIsTheAirsLight() throws {
        guard let cube = WorldTextures.hdrCubeTexels(WorldLook.riviera.skyPrefix) else {
            throw XCTSkip("the HDR sky is not in the test host bundle")
        }
        let n = cube.size
        XCTAssertEqual(n, 1024)
        func texel(face: Int, row: Int, col: Int) -> SIMD3<Double> {
            cube.texels.withUnsafeBytes { b in
                WorldTextures.rgb9e5(b.loadUnaligned(fromByteOffset: ((face * n + row) * n + col) * 4, as: UInt32.self).littleEndian)
            }
        }
        // (face, compass azimuth of its middle column): +x east, -x west,
        // +z north (mirrored), -z south.
        for (face, azimuth) in [(0, 90.0), (1, 270.0), (4, 0.0), (5, 180.0)] {
            let got = texel(face: face, row: n - 1, col: n / 2)
            let want = air(azimuth: azimuth * .pi / 180)
            for c in 0..<3 {
                XCTAssertEqual(got[c], want[c], accuracy: want[c] * 0.03, "face \(face) channel \(c): \(got) against \(want)")
            }
        }
        // Towards the sun the haze is brighter than away from it.
        XCTAssertGreaterThan(air(azimuth: WorldSun.azimuthDeg * .pi / 180).y, 1.8 * air(azimuth: (WorldSun.azimuthDeg + 180) * .pi / 180).y)
        // The sky itself keeps its radiance: somewhere on the faces the sun
        // is hundreds of times white.
        var peak = 0.0
        for face in [0, 1, 2, 4, 5] {
            for row in stride(from: 0, to: n, by: 2) {
                for col in stride(from: 0, to: n, by: 2) { peak = max(peak, texel(face: face, row: row, col: col).y) }
            }
        }
        XCTAssertGreaterThan(peak, 300, "the sun's disc")
    }

    /// All round, the air's light averages to the region's `horizonLinear`.
    func test_theAirAveragesToTheHorizonColour() {
        var sum = SIMD3<Double>(0, 0, 0)
        let steps = 720
        for k in 0..<steps { sum += air(azimuth: Double(k) / Double(steps) * 2 * .pi) }
        let mean = sum / Double(steps), want = WorldLook.riviera.horizonLinear
        for c in 0..<3 { XCTAssertEqual(mean[c], want[c], accuracy: want[c] * 0.03, "channel \(c)") }
    }

    /// One shared-exponent texel decodes to its colour.
    func test_sharedExponentTexelsDecode() {
        // Mantissas 256, 128 and 64 of 512 at exponent 16 (2^(16 - 15) = 2).
        let v: UInt32 = 256 | (128 << 9) | (64 << 18) | (16 << 27)
        let c = WorldTextures.rgb9e5(v)
        XCTAssertEqual(c.x, 1.0, accuracy: 1e-9)
        XCTAssertEqual(c.y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.z, 0.25, accuracy: 1e-9)
    }
}
