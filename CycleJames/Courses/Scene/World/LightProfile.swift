import Foundation

/// Sky and sun visibility along the route, from the course's light raster
/// (`<id>_light.rgbz`, R and G; scripts/courses/textures/bake_light_maps.py):
/// one value a metre, the mean of the centreline and 1.5 m either side. It
/// meters the camera's exposure in sunken lanes (`LaneExposure`) and sets
/// the rider's share of the sky light (`RiderRig.setSkyVisibility`). Open
/// (1) everywhere when the course has no raster.
struct LightProfile: Sendable {
    static let stepM = 1.0
    /// How far the sun pulls the meter up from the sky: to 0.7 sky + 0.3
    /// sun where that is more. Sky alone took a sunlit road beside a few
    /// trees or a house (sky 0.35-0.55, sun 0.7-0.9: Koppenberg s 620-680,
    /// Paterberg s 260-290) for a lane and opened it up 0.5-0.7 EV; now
    /// they stay under 0.45. A shaded road in the open doesn't pull it
    /// down, so the fields stay at 0. The holle weg's shaded heart
    /// (s 570-600) keeps its full 0.75 EV, its sunlit mouth (s 500-545)
    /// gets about 0.5.
    static let sunShare: Float = 0.3
    /// Sky visibility every `stepM` from s = 0.
    let sky: [Float]
    /// Sun visibility, likewise.
    let sun: [Float]

    static let open = LightProfile(sky: [], sun: [])

    /// Sky visibility at `s`, linear between the metres.
    func sky(at s: Double) -> Float { Self.value(sky, at: s) }

    /// Sun visibility at `s`, linear between the metres.
    func sun(at s: Double) -> Float { Self.value(sun, at: s) }

    private static func value(_ a: [Float], at s: Double) -> Float {
        guard !a.isEmpty else { return 1 }
        let x = min(max(s / stepM, 0), Double(a.count - 1))
        let i = Int(x), j = min(i + 1, a.count - 1), f = Float(x - Double(i))
        return a[i] + (a[j] - a[i]) * f
    }

    /// What the camera frames, metered: the sky it sees, opened up where
    /// the sun reaches (`sunShare`), from 4 m behind the rider to 30 m
    /// ahead, the nearer metres weighted more (the road fills the lower
    /// half of the frame), so the exposure starts to open as a lane comes
    /// into view and the meter reads the place, not one gap in the trees.
    func metered(at s: Double) -> Float {
        guard !sky.isEmpty else { return 1 }
        var acc: Float = 0
        for tap in Self.meterTaps {
            let k = sky(at: s + tap.d)
            acc += tap.w * (k + Self.sunShare * max(sun(at: s + tap.d) - k, 0))
        }
        return acc
    }

    /// Metering offsets (m) and normalised weights.
    private static let meterTaps: [(d: Double, w: Float)] = {
        let taps = stride(from: -4.0, through: 30.0, by: 2.0).map { d in (d: d, w: Float(exp(-max(d, 0) / 14))) }
        let sum = taps.reduce(Float(0)) { $0 + $1.w }
        return taps.map { (d: $0.d, w: $0.w / sum) }
    }()

    /// Samples the raster's R and G channels along the route. `pixels`
    /// covers the near terrain grid's footprint (north row first), as the
    /// shaders map it (`WorldMaterials.lightUV`).
    static func make(route: CourseRoute, grid: HeightRaster, pixels: WorldTextures.Pixels) -> LightProfile {
        let (w, h) = (pixels.width, pixels.height)
        guard w > 0, h > 0, pixels.rgba.count >= w * h * 4 else { return .open }
        var sky: [Float] = [], sun: [Float] = []
        sky.reserveCapacity(Int(route.length / stepM) + 2)
        sun.reserveCapacity(Int(route.length / stepM) + 2)
        pixels.rgba.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            var s = 0.0
            while s <= route.length {
                let pose = route.pose(at: s)
                var r: Float = 0, g: Float = 0
                for lateral: Float in [-1.5, 0, 1.5] {
                    let p = pose.position + pose.right * lateral   // x east, z south; right is level
                    let u = (Double(p.x) - grid.originEast) / grid.widthM
                    let v = (grid.originNorth + Double(p.z)) / grid.heightM
                    let col = min(max(Int(u * Double(w)), 0), w - 1)
                    let row = min(max(Int(v * Double(h)), 0), h - 1)
                    r += Float(b[(row * w + col) * 4]) / 255
                    g += Float(b[(row * w + col) * 4 + 1]) / 255
                }
                sky.append(r / 3)
                sun.append(g / 3)
                s += stepM
            }
        }
        return LightProfile(sky: sky, sun: sun)
    }

    /// The course's profile from its light raster as the world build
    /// decodes it (once, off the main thread, for the plants and the GPU
    /// too: `CourseWorldBuilder`). Open without one.
    static func make(bundle: CourseBundle, pixels: WorldTextures.Pixels?) -> LightProfile {
        #if DEBUG
        // -laneExposureOff: no exposure in lanes, to judge it against none
        // in the same build; -lightRasterOff (open ground everywhere) too.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-laneExposureOff") || args.contains("-lightRasterOff") { return .open }
        #endif
        guard let pixels else { return .open }
        return make(route: bundle.route, grid: bundle.terrainNear, pixels: pixels)
    }
}

/// A camera opening up in a sunken lane, eased like an eye: up to +0.75 EV
/// where the route ahead sees little sky or sun. It is metered from the
/// light profile, not from the frame, so sunflecks and gaps in the trees
/// can't make it pump. About 2 s into the dark, 1 s back out, and never
/// faster than 0.5 EV a second. Applied as light (`SkyLighting.exposure`).
/// Render thread.
final class LaneExposure {
    /// Metered light at and above which the exposure stays at 0: villages
    /// and tree-lined roads open up a little, the open fields not at all.
    static let openRef: Float = 0.8
    /// EV per halving of the sky seen below `openRef`.
    static let gain: Float = 0.55
    static let maxEV: Float = 0.75
    /// Easing time constants (s): into the dark, back out.
    static let tauIn: Float = 2.0
    static let tauOut: Float = 1.0
    /// Hard limit after the easing, EV per second.
    static let maxRate: Float = 0.5

    private(set) var ev: Float = 0
    private var applied: Float = .nan

    /// The exposure a camera settles at for `metered` light.
    static func target(metered: Float) -> Float {
        min(max(gain * log2(openRef / max(metered, 0.05)), 0), maxEV)
    }

    /// The exposure a camera settles at, standing at `s`.
    static func target(at s: Double, profile: LightProfile) -> Float {
        target(metered: profile.metered(at: s))
    }

    /// One frame of easing from `ev` towards `target`.
    static func step(_ ev: Float, towards target: Float, dt: Float) -> Float {
        guard dt > 0 else { return ev }
        let tau = target > ev ? tauIn : tauOut
        var next = ev + (target - ev) * (1 - exp(-dt / tau))
        // Land exactly, so the open fields get back the calibrated look.
        if abs(target - next) < 0.002 { next = target }
        let limit = maxRate * dt
        return min(max(next, ev - limit), ev + limit)
    }

    /// Straight to the settled exposure at `s` (the first frame).
    func reset(s: Double, profile: LightProfile, apply: (Float) -> Void) {
        ev = Self.target(at: s, profile: profile)
        applied = ev
        apply(ev)
    }

    /// Eases towards the exposure for `s`; `apply` only when it has moved
    /// enough to see (each call writes the scene's lights).
    func update(s: Double, dt: Double, profile: LightProfile, apply: (Float) -> Void) {
        ev = Self.step(ev, towards: Self.target(at: s, profile: profile), dt: Float(dt))
        if applied.isNaN || abs(ev - applied) > 0.004 || (ev != applied && ev == 0) {
            applied = ev
            apply(ev)
        }
    }
}
