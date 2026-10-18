import SceneKit
import UIKit

/// Sky, sun, image-based light, haze and the camera's look.
enum SkyLighting {
    /// The camera's exposure offset (stops). Kept at zero: SceneKit clamps
    /// the HDR colour to the white point before applying the offset, so a
    /// negative offset caps the brightest white at 87 % (measured with the
    /// calibration chart in WorldDebugShots). The lights are scaled instead.
    static let exposureOffset: Double = 0
    /// The background is drawn this much brighter than its texture, to
    /// cancel any exposure offset so the sky shows as baked.
    static var backgroundIntensity: Double { pow(2, -exposureOffset) }

    /// All-round sky colour just above the horizon, linear, as printed by
    /// bake_materials.py (`horizon_haze`); the far terrain fades to it.
    static let horizonLinear = SIMD3<Double>(0.3868, 0.4342, 0.4964)

    /// Fog colour: the horizon haze as the background shows it.
    static var horizon: UIColor {
        let c = horizonLinear * backgroundIntensity
        func enc(_ x: Double) -> CGFloat {
            let v = min(max(x, 0), 1)
            return CGFloat(v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055)
        }
        return UIColor(red: enc(c.x), green: enc(c.y), blue: enc(c.z), alpha: 1)
    }

    /// The six cube faces in SceneKit's order (+x, -x, +y, -y, +z, -z),
    /// baked or, failing that, a simple gradient. `prefix` "cj_sky" is the
    /// background, "cj_skyenv" the lighting environment (same sky, with a
    /// hemisphere of sunlit fields below the horizon).
    static func skyFaces(textures: WorldTextures, prefix: String = "cj_sky") -> [UIImage] {
        let names = ["px", "nx", "py", "ny", "pz", "nz"].map { "\(prefix)_\($0)" }
        let baked = names.compactMap { textures.image($0) }
        if baked.count == 6 { return baked }
        if prefix != "cj_sky" { return skyFaces(textures: textures) }
        return gradientFaces(size: 64)
    }

    static func install(in scene: SCNScene, config: WorldConfig, textures: WorldTextures) -> SCNNode {
        scene.background.contents = skyFaces(textures: textures)
        scene.background.intensity = CGFloat(backgroundIntensity)
        // Image-based light from the sky (the rider's metals, clear coat
        // and lenses rely on it too).
        scene.lightingEnvironment.contents = skyFaces(textures: textures, prefix: "cj_skyenv")
        // As bright as the visible sky, so reflections match it.
        scene.lightingEnvironment.intensity = CGFloat(backgroundIntensity)

        // Aerial perspective: roughly 1 - exp(-d / 21 km) out to the far
        // hills, about half-way to the haze at 2.5 km on a summer afternoon.
        scene.fogColor = horizon
        scene.fogStartDistance = 0
        scene.fogEndDistance = 5600
        scene.fogDensityExponent = 1

        let light = SCNLight()
        light.type = .directional
        light.temperature = 5100
        light.intensity = 1970
        light.castsShadow = true
        light.shadowMode = .forward
        light.shadowColor = UIColor(white: 0, alpha: 1)
        light.shadowCascadeSplittingFactor = 0.55
        light.automaticallyAdjustsShadowProjection = true
        applyShadows(light, config: config)
        light.shadowBias = 0.6
        light.forcesBackFaceCasters = false
        light.categoryBitMask = 1

        let sun = SCNNode()
        sun.name = "sun"
        sun.light = light
        orient(sun)
        scene.rootNode.addChildNode(sun)
        return sun
    }

    /// The sun's shadow quality for a tier. Also used live, from the render
    /// thread, when an automatic tier steps down mid-ride.
    static func applyShadows(_ light: SCNLight, config: WorldConfig) {
        let size = CGSize(width: config.shadowMapSize, height: config.shadowMapSize)
        if light.shadowMapSize != size { light.shadowMapSize = size }
        if light.shadowCascadeCount != config.shadowCascades { light.shadowCascadeCount = config.shadowCascades }
        light.maximumShadowDistance = CGFloat(config.shadowDistance)
        light.shadowSampleCount = config.shadowSamples
        light.shadowRadius = config.quality == .battery ? 1 : 2.5
    }

    /// Points the light's −z along the sunlight.
    static func orient(_ sun: SCNNode) {
        let toSun = WorldSun.toSun
        sun.simdLook(at: sun.simdPosition - toSun, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
    }

    /// The camera look for this tier.
    static func configure(_ camera: SCNCamera, config: WorldConfig) {
        camera.zNear = 0.08
        camera.zFar = 7000
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = CGFloat(exposureOffset)
        camera.averageGray = 0.18
        camera.whitePoint = 1.0
        camera.minimumExposure = -3
        camera.maximumExposure = 3
        camera.vignettingIntensity = 0.22
        camera.vignettingPower = 0.55
        camera.saturation = 1.06
        camera.contrast = 0.05
        applyEffects(camera, config: config)
        // No lookup-table grade: SceneKit applies colorGrading in a space
        // that lifts black to navy and crushes the darks (measured with the
        // calibration chart in WorldDebugShots), so the grade is just the
        // gentle contrast and saturation above.
        camera.colorGrading.contents = nil
    }

    /// The tier's costly post-process passes (bloom, SSAO). Also used live
    /// when an automatic tier steps down mid-ride.
    static func applyEffects(_ camera: SCNCamera, config: WorldConfig) {
        if config.bloom {
            camera.bloomIntensity = 0.18
            camera.bloomThreshold = 1.0
            camera.bloomBlurRadius = 7
            camera.bloomIterationCount = 2
        } else {
            camera.bloomIntensity = 0
        }
        if config.ssao {
            camera.screenSpaceAmbientOcclusionIntensity = 0.75
            camera.screenSpaceAmbientOcclusionRadius = 0.9
            camera.screenSpaceAmbientOcclusionBias = 0.04
            camera.screenSpaceAmbientOcclusionDepthThreshold = 0.25
            camera.screenSpaceAmbientOcclusionNormalThreshold = 0.35
        } else {
            camera.screenSpaceAmbientOcclusionIntensity = 0
        }
    }

    // MARK: - Fallbacks

    private static func gradientFaces(size: Int) -> [UIImage] {
        // Directions per face for pixel (u, v), standard cube-map layout.
        let dirs: [(Double, Double) -> (Double, Double, Double)] = [
            { u, v in (1, -v, -u) }, { u, v in (-1, -v, u) },
            { u, v in (u, 1, v) }, { u, v in (u, -1, -v) },
            { u, v in (u, -v, 1) }, { u, v in (-u, -v, -1) },
        ]
        let zenith = (0.42, 0.58, 0.84), hz = (0.70, 0.72, 0.74), ground = (0.42, 0.46, 0.40)
        return dirs.map { dir in
            var px = [UInt8](repeating: 255, count: size * size * 4)
            for y in 0..<size {
                for x in 0..<size {
                    let u = (Double(x) + 0.5) / Double(size) * 2 - 1
                    let v = (Double(y) + 0.5) / Double(size) * 2 - 1
                    let d = dir(u, v)
                    let l = sqrt(d.0 * d.0 + d.1 * d.1 + d.2 * d.2)
                    let up = d.1 / l
                    let c: (Double, Double, Double)
                    if up >= 0 {
                        let t = pow(up, 0.45)
                        c = (hz.0 + (zenith.0 - hz.0) * t, hz.1 + (zenith.1 - hz.1) * t, hz.2 + (zenith.2 - hz.2) * t)
                    } else {
                        let t = min(-up * 4, 1)
                        c = (hz.0 + (ground.0 - hz.0) * t, hz.1 + (ground.1 - hz.1) * t, hz.2 + (ground.2 - hz.2) * t)
                    }
                    let k = (y * size + x) * 4
                    px[k] = UInt8(c.0 * 255); px[k + 1] = UInt8(c.1 * 255); px[k + 2] = UInt8(c.2 * 255)
                }
            }
            return image(rgba: px, width: size, height: size)
        }
    }

    static func image(rgba: [UInt8], width: Int, height: Int) -> UIImage {
        let data = Data(rgba) as CFData
        let provider = CGDataProvider(data: data)!
        let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                         bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return UIImage(cgImage: cg)
    }
}
