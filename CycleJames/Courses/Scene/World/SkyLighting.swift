import SceneKit
import UIKit

/// Sky, sun, image-based light, haze and the camera's look.
enum SkyLighting {
    /// The camera's exposure offset (stops). Kept at zero: SceneKit clamps
    /// the HDR colour to the white point before applying the offset, so a
    /// negative offset caps the brightest white at 87 % (measured with the
    /// calibration chart in WorldDebugShots). The lights are scaled instead.
    static let exposureOffset: Double = 0
    /// The background faces store linear radiance / skyScale
    /// (bake_materials.py `SKY_SCALE`), so sunlit cloud tops brighter than
    /// 1 fit in 8 bits. The lighting environment's faces are stored at 1.
    static let skyScale: Double = 1.6

    /// All-round sky colour just above the horizon, linear, as the bake
    /// wrote it to scripts/courses/textures/cj_sky_horizon.json; the far
    /// terrain fades to it. SkyBakeTests checks it against the faces.
    static let horizonLinear = SIMD3<Double>(0.5374, 0.6032, 0.6896)

    /// Fog colour: the horizon haze as the background shows it.
    static var horizon: UIColor { horizon(scale: 1) }

    /// The haze `scale` times brighter (the lane exposure), at most until
    /// its brightest channel reaches 1, so it whitens without shifting hue.
    static func horizon(scale: Double) -> UIColor {
        let base = horizonLinear * pow(2, -exposureOffset)
        let c = base * min(scale, 1 / max(base.x, base.y, base.z))
        func enc(_ x: Double) -> CGFloat {
            let v = min(max(x, 0), 1)
            return CGFloat(v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055)
        }
        return UIColor(red: enc(c.x), green: enc(c.y), blue: enc(c.z), alpha: 1)
    }

    /// The six cube faces in SceneKit's order (+x, -x, +y, -y, +z, -z)
    /// and the scale they are stored at, baked or, failing that, a simple
    /// gradient (at 1). `prefix` "cj_sky" is the background (at
    /// 1 / `skyScale`), "cj_skyenv" the lighting environment (at 1: the same
    /// sky without the background's photo look and with dimmer clouds, and
    /// a hemisphere of sunlit fields below the horizon), which falls back to
    /// the background.
    static func skyFaces(textures: WorldTextures, prefix: String = "cj_sky") -> (faces: [UIImage], scale: Double) {
        let names = ["px", "nx", "py", "ny", "pz", "nz"].map { "\(prefix)_\($0)" }
        let baked = names.compactMap { textures.image($0) }
        if baked.count == 6 { return (baked, prefix == "cj_sky" ? 1 / skyScale : 1) }
        if prefix != "cj_sky" { return skyFaces(textures: textures) }
        return (gradientFaces(size: 64), 1)
    }

    static func install(in scene: SCNScene, config: WorldConfig, textures: WorldTextures) -> SCNNode {
        let sky = skyFaces(textures: textures)
        scene.background.contents = sky.faces
        scene.background.intensity = CGFloat(pow(2, -exposureOffset) / sky.scale)
        // Image-based light from the sky (the rider's metals, clear coat
        // and lenses rely on it too), at its stored radiance: the
        // calibrated ambient (WorldDebugShots `litchart`).
        let env = skyFaces(textures: textures, prefix: "cj_skyenv")
        scene.lightingEnvironment.contents = env.faces
        scene.lightingEnvironment.intensity = CGFloat(pow(2, -exposureOffset) / env.scale)

        // Aerial perspective: roughly 1 - exp(-d / 21 km) out to the far
        // hills, about half-way to the haze at 2.5 km on a summer afternoon.
        scene.fogColor = horizon
        scene.fogStartDistance = 0
        scene.fogEndDistance = 5600
        scene.fogDensityExponent = 1

        let light = SCNLight()
        light.type = .directional
        light.temperature = 5100
        light.intensity = sunIntensity
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

    /// The key light at exposure 0.
    static let sunIntensity: CGFloat = 1970

    /// The share of the lane exposure's stops that the sky and the haze
    /// take. A phone camera opening up for a lane's shade holds its sky
    /// back (its tone curve rolls highlights off; ours, at white point 1,
    /// clipped the pale sky at the horizon to white at the full +0.75 EV,
    /// and left it washed out at half): the sky pales a touch, keeps its blue.
    static let skyExposureShare: Double = 0.25

    /// Exposure as light, for the camera opening up in a sunken lane
    /// (`LaneExposure`): the sun, the image-based light and the leaves'
    /// light through them brighten by 2^ev before the tone curve, the sky
    /// and the haze by `skyExposureShare` of that, so the calibrated camera
    /// (white point, `exposureOffset`) stays as it is and nothing
    /// recompiles. `glow` are the materials whose emission stands for
    /// light (argument `exposureGain`). Takes the installed levels as
    /// exposure 0. Render thread, or before the scene is shown.
    static func exposure(scene: SCNScene, sun: SCNLight, glow: [SCNMaterial]) -> (Float) -> Void {
        let env = scene.lightingEnvironment.intensity, sky = scene.background.intensity
        var share = skyExposureShare
        #if DEBUG
        // -laneSkyShare 1: the sky exposed with everything else.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-laneSkyShare"), i + 1 < args.count, let v = Double(args[i + 1]) { share = v }
        #endif
        return { [share] ev in
            let k = pow(2, Double(ev)), kSky = pow(2, Double(ev) * share)
            sun.intensity = sunIntensity * CGFloat(k)
            scene.lightingEnvironment.intensity = env * CGFloat(k)
            scene.background.intensity = sky * CGFloat(kSky)
            scene.fogColor = horizon(scale: kSky)
            let gain = NSNumber(value: k)
            for m in glow { m.setValue(gain, forKey: "exposureGain") }
        }
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
        // Light: phone and broadcast cameras correct most vignetting.
        camera.vignettingIntensity = 0.14
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
