import SceneKit
import simd

/// Frame geometry of a 56 cm endurance-race road bike (stack 565, reach 390,
/// head 73°, seat 73.5°, chainstays 405, BB drop 72, wheelbase 990) on 700c
/// wheels. Points are in the rig frame: x right, y up from the road, −z
/// forward, with the wheelbase centred on the origin. `f` is metres forward
/// of the bottom bracket, `u` metres above the road.
enum BikeGeometry {
    static let wheelRadius: Float = 0.335
    static let crankLength: Float = 0.1725
    static let bbHeight: Float = 0.263
    static let rearAxleF: Float = -0.3985
    static let frontAxleF: Float = 0.5915
    /// The bottom bracket sits this far behind the rig origin.
    static let zBB: Float = 0.0965

    @inline(__always)
    static func p(_ f: Float, _ u: Float, _ x: Float = 0) -> SIMD3<Float> { SIMD3(x, u, zBB - f) }

    static var bb: SIMD3<Float> { p(0, bbHeight) }
    static var rearAxle: SIMD3<Float> { p(rearAxleF, wheelRadius) }
    static var frontAxle: SIMD3<Float> { p(frontAxleF, wheelRadius) }

    /// Along the seat tube from the BB centre, metres.
    static func seatTube(_ l: Float, _ x: Float = 0) -> SIMD3<Float> {
        p(-0.2840 * l, bbHeight + 0.9588 * l, x)
    }
    /// Along the steering axis from the top of the head tube (positive up).
    static func steerer(_ l: Float) -> SIMD3<Float> { p(0.390 - 0.2924 * l, 0.828 + 0.9563 * l) }

    /// Centre of the cleat / foot over each pedal, laterally.
    static let pedalLateral: Float = 0.105
    static let crankFace: Float = 0.060
    /// Wrist joint and the top of the hood under the palm, per side (±1).
    static func wrist(_ sx: Float) -> SIMD3<Float> { p(0.497, 0.950, sx * 0.214) }
    static func hoodTop(_ sx: Float) -> SIMD3<Float> { p(0.566, 0.916, sx * 0.212) }
    /// Saddle: top of the shell where the seat tube line meets it.
    static let saddleTop = seatTube(0.750)
    static let bigRingPitchRadius: Float = 0.1011
}

/// Meshes for the bike. Static parts are merged into one geometry; parts
/// that move (wheels, crankset, pedals, chain) are built in their own frames.
enum RiderBikeMeshes {
    enum Slot: Int, CaseIterable { case paint, carbon, rubber, alloy, steel, glove, bottle }

    struct Detail {
        let around: Int
        let wheelAround: Int
        let spokes: Int
        let cogs: Int
        let teethSamples: Int

        init(_ q: GraphicsQuality) {
            switch q {
            case .high: around = 18; wheelAround = 96; spokes = 24; cogs = 12; teethSamples = 6
            case .balanced: around = 14; wheelAround = 72; spokes = 24; cogs = 12; teethSamples = 4
            case .battery: around = 10; wheelAround = 48; spokes = 16; cogs = 6; teethSamples = 3
            }
        }
    }

    private typealias B = BikeGeometry

    // MARK: Frame and everything bolted to it

    static func frame(_ d: Detail, body: RiderBodyLayout, bodyDetail: RiderBodyMeshes.Detail) -> RiderMesh {
        var m = RiderMesh(slots: Slot.allCases.count)
        let paint = Slot.paint.rawValue, carbon = Slot.carbon.rawValue, rubber = Slot.rubber.rawValue
        let alloy = Slot.alloy.rawValue, steel = Slot.steel.rawValue
        let n = d.around
        func paintUV(_ r: RiderMaterials.PaintRegion) -> (Float, Float) -> SIMD2<Float> {
            { t, th in RiderMaterials.paintUV(r, th, t) }
        }
        func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
        let side = SIMD3<Float>(1, 0, 0)

        // Head tube, tapered 1⅛" → 1½".
        m.tube(slot: paint, path: RiderPath([B.p(0.3865, 0.840), B.p(0.4425, 0.656)]), along: 6, around: n, side: side,
               exponent: 2.2, caps: true, uv: paintUV(.badge)) { t in SIMD2(lerp(0.0215, 0.0275, t), lerp(0.024, 0.031, t)) }
        // Top tube, gently sloping.
        m.tube(slot: paint, path: RiderPath([B.p(-0.152, 0.772), B.p(0.12, 0.793), B.p(0.392, 0.810)]), along: 12, around: n,
               side: side, exponent: 2.4, uv: paintUV(.plain)) { t in SIMD2(lerp(0.0195, 0.0215, t), lerp(0.0170, 0.0215, t)) }
        // Down tube.
        m.tube(slot: paint, path: RiderPath([B.p(0.010, 0.282), B.p(0.437, 0.690)]), along: 12, around: n, side: side,
               exponent: 2.6, uv: paintUV(.band)) { t in SIMD2(lerp(0.031, 0.025, t), lerp(0.025, 0.028, t)) }
        // Seat tube.
        m.tube(slot: paint, path: RiderPath([B.seatTube(0.0), B.seatTube(0.545)]), along: 10, around: n, side: side,
               exponent: 2.2, caps: true, uv: paintUV(.plain)) { t in SIMD2(lerp(0.024, 0.0175, t), lerp(0.027, 0.0195, t)) }
        // Bottom-bracket shell.
        m.tube(slot: paint, path: RiderPath([B.p(0, B.bbHeight, -0.043), B.p(0, B.bbHeight, 0.043)]), along: 2, around: n,
               side: SIMD3(0, 1, 0), caps: true, uv: paintUV(.plain)) { _ in SIMD2(0.0235, 0.0235) }
        for sx: Float in [-1, 1] {
            // Dropped seat stays and chainstays.
            m.tube(slot: paint, path: RiderPath([B.p(-0.392, 0.352, sx * 0.064), B.p(-0.262, 0.530, sx * 0.055), B.p(-0.130, 0.700, sx * 0.018)]),
                   along: 12, around: n, side: side, uv: paintUV(.fade)) { t in SIMD2(lerp(0.0075, 0.0095, t), lerp(0.0090, 0.0120, t)) }
            m.tube(slot: paint, path: RiderPath([B.p(-0.394, 0.333, sx * 0.064), B.p(-0.210, 0.300, sx * 0.068), B.p(-0.030, 0.262, sx * 0.037)]),
                   along: 12, around: n, side: side, uv: paintUV(.plain)) { t in SIMD2(lerp(0.0095, 0.0150, t), lerp(0.0110, 0.0220, t)) }
            // Rear dropout.
            m.tube(slot: paint, path: RiderPath([B.p(-0.408, 0.322, sx * 0.066), B.p(-0.390, 0.358, sx * 0.065)]), along: 3, around: 8,
                   side: side, exponent: 3, caps: true, uv: paintUV(.plain)) { _ in SIMD2(0.0055, 0.016) }
            // Fork blade and front dropout.
            m.tube(slot: paint, path: RiderPath([B.p(0.442, 0.668, sx * 0.043), B.p(0.520, 0.500, sx * 0.052), B.p(0.5915, 0.330, sx * 0.057)]),
                   along: 12, around: n, side: side, caps: true, uv: paintUV(.fade)) { t in SIMD2(lerp(0.0125, 0.0080, t), lerp(0.0230, 0.0130, t)) }
        }
        // Fork crown.
        m.tube(slot: paint, path: RiderPath([B.p(0.443, 0.665, -0.050), B.p(0.443, 0.665, 0.050)]), along: 4, around: n,
               side: SIMD3(0, 1, 0), exponent: 2.4, caps: true, uv: paintUV(.fade)) { _ in SIMD2(0.020, 0.028) }

        // Thru-axles (fixed; the hubs turn on them).
        m.tube(slot: alloy, path: RiderPath([B.p(B.rearAxleF, 0.335, -0.080), B.p(B.rearAxleF, 0.335, 0.079)]), along: 1, around: 10,
               side: SIMD3(0, 1, 0), caps: true) { _ in SIMD2(0.0075, 0.0075) }
        m.tube(slot: alloy, path: RiderPath([B.p(B.frontAxleF, 0.335, -0.066), B.p(B.frontAxleF, 0.335, 0.064)]), along: 1, around: 10,
               side: SIMD3(0, 1, 0), caps: true) { _ in SIMD2(0.0075, 0.0075) }

        // Seatpost, clamp and saddle.
        m.tube(slot: carbon, path: RiderPath([B.seatTube(0.48), B.seatTube(0.705)]), along: 3, around: n, side: side, caps: true) { _ in
            SIMD2(0.0136, 0.0136)
        }
        m.tube(slot: alloy, path: RiderPath([B.seatTube(0.712, -0.022), B.seatTube(0.712, 0.022)]), along: 1, around: 10,
               side: SIMD3(0, 1, 0), caps: true) { _ in SIMD2(0.010, 0.016) }
        saddle(&m, slot: carbon, around: n)
        for sx: Float in [-1, 1] {
            m.tube(slot: steel, path: RiderPath([B.p(-0.095, 0.956, sx * 0.010), B.p(-0.150, 0.942, sx * 0.022),
                                                 B.p(-0.270, 0.946, sx * 0.030), B.p(-0.300, 0.962, sx * 0.036)]),
                   along: 10, around: 6, side: side) { _ in SIMD2(0.0035, 0.0035) }
        }

        // Steerer spacers, stem, bar.
        m.tube(slot: carbon, path: RiderPath([B.steerer(-0.004), B.steerer(0.022)]), along: 1, around: n, side: side, caps: true) { _ in
            SIMD2(0.0195, 0.0195)
        }
        m.tube(slot: carbon, path: RiderPath([B.steerer(0.021), B.steerer(0.066)]), along: 2, around: n, side: side, exponent: 2.6, caps: true) { _ in
            SIMD2(0.0205, 0.0215)
        }
        m.tube(slot: carbon, path: RiderPath([B.steerer(0.044), B.p(0.486, 0.891)]), along: 4, around: n, side: side, exponent: 3, caps: true) { t in
            SIMD2(0.0175, lerp(0.0195, 0.0175, t))
        }
        m.tube(slot: carbon, path: RiderPath([B.p(0.487, 0.891, -0.024), B.p(0.487, 0.891, 0.024)]), along: 2, around: n,
               side: SIMD3(0, 1, 0), exponent: 2.6, caps: true) { _ in SIMD2(0.0215, 0.020) }
        m.tube(slot: carbon, path: RiderPath([B.p(0.485, 0.892, -0.080), B.p(0.485, 0.892, 0.080)]), along: 6, around: n,
               side: SIMD3(0, 1, 0), caps: true) { t in
            let e = abs(t - 0.5) * 2
            let r = lerp(0.0159, 0.0130, RiderMath.smoothstep(0.3, 1, e))
            return SIMD2(r, r)
        }
        for sx: Float in [-1, 1] {
            let bar = RiderPath([
                B.p(0.485, 0.892, sx * 0.075), B.p(0.486, 0.892, sx * 0.150), B.p(0.490, 0.892, sx * 0.188),
                B.p(0.506, 0.890, sx * 0.205), B.p(0.530, 0.886, sx * 0.212), B.p(0.552, 0.874, sx * 0.214),
                B.p(0.566, 0.848, sx * 0.216), B.p(0.562, 0.806, sx * 0.218), B.p(0.544, 0.779, sx * 0.219),
                B.p(0.512, 0.768, sx * 0.220), B.p(0.452, 0.770, sx * 0.221),
            ])
            m.tube(slot: rubber, path: bar, along: 40, around: n, side: SIMD3(-sx * 0.3, 1, 0.6), caps: true) { _ in SIMD2(0.0136, 0.0136) }
            hood(&m, slot: rubber, sx: sx, around: n)
            // Brake lever blade, in front of the drop.
            m.tube(slot: carbon, path: RiderPath([B.p(0.610, 0.885, sx * 0.212), B.p(0.618, 0.848, sx * 0.214),
                                                  B.p(0.608, 0.800, sx * 0.216), B.p(0.588, 0.768, sx * 0.217), B.p(0.570, 0.753, sx * 0.218)]),
                   along: 14, around: 8, side: side, exponent: 3, caps: true) { t in SIMD2(lerp(0.010, 0.006, t), lerp(0.008, 0.005, t)) }
            // Hands on the hoods.
            let hand = RiderBodyMeshes.hand(wrist: B.wrist(sx), hoodTop: B.hoodTop(sx), side: sx, wristRadius: body.wristRadius, bodyDetail)
            m.append(hand, slotMap: [Slot.glove.rawValue])
        }

        // Disc calipers.
        let rearCal = B.rearAxle + SIMD3(0, 0.072 * sin(0.42), -0.072 * cos(0.42))
        let rearTan = SIMD3<Float>(0, cos(0.42), sin(0.42))
        m.tube(slot: alloy, path: RiderPath([rearCal - rearTan * 0.026 + SIMD3(-0.053, 0, 0), rearCal + rearTan * 0.026 + SIMD3(-0.053, 0, 0)]),
               along: 2, around: 10, side: side, exponent: 3, caps: true) { _ in SIMD2(0.013, 0.016) }
        let frontAng: Float = 2.45
        let frontCal = B.frontAxle + SIMD3(0, 0.072 * sin(frontAng), -0.072 * cos(frontAng))
        let frontTan = SIMD3<Float>(0, cos(frontAng), sin(frontAng))
        m.tube(slot: alloy, path: RiderPath([frontCal - frontTan * 0.026 + SIMD3(-0.047, 0, 0), frontCal + frontTan * 0.026 + SIMD3(-0.047, 0, 0)]),
               along: 2, around: 10, side: side, exponent: 3, caps: true) { _ in SIMD2(0.013, 0.016) }

        // Front derailleur cage over the big ring, and its mount.
        for (x, h) in [(Float(0.061), Float(0.013)), (Float(0.041), Float(0.009))] {
            var pts = [SIMD3<Float>]()
            for k in 0...6 {
                let f = -0.050 + 0.090 * Float(k) / 6
                pts.append(B.p(f, B.bbHeight + sqrt(max(0.118 * 0.118 - f * f, 0)), x))
            }
            m.tube(slot: alloy, path: RiderPath(pts), along: 10, around: 6, side: side, exponent: 3, caps: true) { _ in SIMD2(0.0018, h) }
        }
        m.tube(slot: alloy, path: RiderPath([B.seatTube(0.135, 0.022), B.p(-0.046, 0.385, 0.050)]), along: 2, around: 8, side: SIMD3(0, 1, 0),
               exponent: 3, caps: true) { _ in SIMD2(0.010, 0.012) }

        // Rear derailleur: hanger, parallelogram body, cage plates and pulleys.
        let upperPulley = B.p(-0.366, 0.272, 0.040), lowerPulley = B.p(-0.402, 0.199, 0.040)
        m.tube(slot: alloy, path: RiderPath([B.p(-0.402, 0.322, 0.074), B.p(-0.414, 0.292, 0.084), B.p(-0.392, 0.276, 0.066), upperPulley + SIMD3(0.018, 0, 0)]),
               along: 10, around: 10, side: side, exponent: 2.6, caps: true) { t in SIMD2(lerp(0.010, 0.007, t), lerp(0.014, 0.011, t)) }
        for (x, w) in [(Float(0.052), Float(0.024)), (Float(0.029), Float(0.020))] {
            let a = SIMD3<Float>(x, upperPulley.y, upperPulley.z), b = SIMD3<Float>(x, lowerPulley.y, lowerPulley.z)
            m.tube(slot: alloy, path: RiderPath([a, b]), along: 4, around: 10, side: side, exponent: 2.2, caps: true) { t in
                SIMD2(0.0015, w * (0.92 + 0.16 * t))
            }
        }
        for c in [upperPulley, lowerPulley] {
            var pulley = RiderMesh()
            pulley.latheX(along: 6, around: 20) { t in
                let a = t * 2 * .pi
                return SIMD2(0.0035 * cos(a), 0.0185 + 0.0025 * sin(a))
            }
            pulley.annulusX(x: 0.0036, inner: 0.004, outer: 0.0186, around: 20, facing: 1)
            pulley.annulusX(x: -0.0036, inner: 0.004, outer: 0.0186, around: 20, facing: -1)
            m.append(pulley, transform: RiderMath.translation(c), slotMap: [Slot.carbon.rawValue])
        }

        // Bottle and cage on the down tube.
        let dtDir = normalize(B.p(0.437, 0.690) - B.p(0.010, 0.282))
        let dtUp = normalize(cross(dtDir, SIMD3(1, 0, 0)))
        let normal = dtUp.y > 0 ? dtUp : -dtUp
        let bottleMid = B.p(0.010, 0.282) + dtDir * 0.255 + normal * 0.066
        let bottle = RiderPath([bottleMid - dtDir * 0.105, bottleMid + dtDir * 0.105])
        let bp = RiderProfile([[0, 0.031], [0.04, 0.036], [0.38, 0.0335], [0.62, 0.036], [0.80, 0.036], [0.90, 0.026], [0.94, 0.018], [1, 0.017]])
        m.tube(slot: Slot.bottle.rawValue, path: bottle, along: 18, around: n + 6, side: side, caps: true,
               uv: { t, th in SIMD2(th / (2 * .pi), t) }) { t in SIMD2(bp(t, 0), bp(t, 0)) }
        for sx: Float in [-1, 1] {
            let off = SIMD3<Float>(sx * 0.0352, 0, 0) - normal * 0.006
            m.tube(slot: carbon, path: RiderPath([bottleMid - dtDir * 0.105 + off, bottleMid - dtDir * 0.045 + off, bottleMid + dtDir * 0.005 + off]),
                   along: 6, around: 6, side: side, caps: true) { _ in SIMD2(0.0032, 0.0032) }
        }
        m.tube(slot: carbon, path: RiderPath([bottleMid - dtDir * 0.112 + SIMD3(-0.03, 0, 0), bottleMid - dtDir * 0.112 + normal * 0.02,
                                              bottleMid - dtDir * 0.112 + SIMD3(0.03, 0, 0)]),
               along: 8, around: 6, side: dtDir, caps: true) { _ in SIMD2(0.0026, 0.0026) }
        return m
    }

    private static func saddle(_ m: inout RiderMesh, slot: Int, around: Int) {
        let prof = RiderProfile([
            [0.060, 0.012, 0.010], [0.080, 0.018, 0.013], [0.120, 0.021, 0.015], [0.160, 0.029, 0.016],
            [0.200, 0.046, 0.017], [0.240, 0.062, 0.018], [0.280, 0.070, 0.018], [0.310, 0.068, 0.017], [0.330, 0.058, 0.015],
        ])
        let top = B.saddleTop.y
        RiderBodyMeshes.domedLoft(&m, slot: slot, span: 0.06...0.33, domeStart: 0.008, domeEnd: 0.008, rings: 30, around: around + 6,
                                  exponent: 2.6,
                                  section: { w in
                                      let f = -w
                                      let uTop = top + max(0, -0.21 - f) * 0.075 - max(0, f + 0.21) * 0.035
                                      let b = prof(w, 1)
                                      return RiderBodyMeshes.Section(a: prof(w, 0), bNeg: b, bPos: b, cx: 0, cy: uTop - b)
                                  },
                                  place: { w, x, y in SIMD3(x, y, B.zBB + w) })
    }

    private static func hood(_ m: inout RiderMesh, slot: Int, sx: Float, around: Int) {
        let prof = RiderProfile([[0.530, 0.0150, 0.896, 0.017], [0.570, 0.0158, 0.900, 0.017], [0.600, 0.0160, 0.905, 0.020], [0.622, 0.0150, 0.901, 0.022]])
        RiderBodyMeshes.domedLoft(&m, slot: slot, span: 0.530...0.622, domeStart: 0.008, domeEnd: 0.010, rings: 14, around: around,
                                  exponent: 2.4,
                                  section: { f in
                                      RiderBodyMeshes.Section(a: prof(f, 0), bNeg: prof(f, 2), bPos: prof(f, 2), cx: sx * 0.212, cy: prof(f, 1))
                                  },
                                  place: { f, x, y in SIMD3(x, y, B.zBB - f) })
    }

    // MARK: Wheels (axle at the origin, turning about x)

    enum WheelSlot: Int, CaseIterable { case tyre, rim, alloy, steel }

    static func wheel(rear: Bool, _ d: Detail) -> RiderMesh {
        var m = RiderMesh(slots: WheelSlot.allCases.count)
        let tyre = WheelSlot.tyre.rawValue, rim = WheelSlot.rim.rawValue, alloy = WheelSlot.alloy.rawValue, steel = WheelSlot.steel.rawValue
        let n = d.wheelAround
        // 28 mm tyre with tan sidewalls; outer radius 0.335.
        m.latheX(slot: tyre, along: 14, around: n, uv: { t, th in SIMD2(th / (2 * .pi), t) }) { t in
            let a = t * 2 * .pi
            return SIMD2(0.0142 * cos(a), 0.3215 + 0.0135 * sin(a))
        }
        // 45 mm deep carbon rim.
        let rimProfile = RiderPath([
            SIMD3(0.0110, 0.3120, 0), SIMD3(0.0128, 0.3030, 0), SIMD3(0.0136, 0.2900, 0), SIMD3(0.0128, 0.2780, 0),
            SIMD3(0.0098, 0.2700, 0), SIMD3(0.0050, 0.2665, 0), SIMD3(0.0, 0.2660, 0), SIMD3(-0.0050, 0.2665, 0),
            SIMD3(-0.0098, 0.2700, 0), SIMD3(-0.0128, 0.2780, 0), SIMD3(-0.0136, 0.2900, 0), SIMD3(-0.0128, 0.3030, 0),
            SIMD3(-0.0110, 0.3120, 0), SIMD3(-0.0060, 0.3100, 0), SIMD3(0.0, 0.3090, 0), SIMD3(0.0060, 0.3100, 0),
        ], closed: true)
        m.latheX(slot: rim, along: 24, around: n) { t in
            let p = rimProfile.point(t)
            return SIMD2(p.x, p.y)
        }
        // Hub shell with flanges.
        let right: Float = rear ? 0.071 : 0.050
        let hub = RiderPath([
            SIMD3(-0.052, 0.0090, 0), SIMD3(-0.044, 0.0160, 0), SIMD3(-0.034, 0.0160, 0), SIMD3(-0.031, 0.0300, 0),
            SIMD3(-0.027, 0.0300, 0), SIMD3(-0.022, 0.0170, 0), SIMD3(0.022, 0.0165, 0), SIMD3(0.027, 0.0300, 0),
            SIMD3(0.031, 0.0300, 0), SIMD3(0.034, 0.0160, 0), SIMD3(right, 0.0140, 0), SIMD3(right + 0.002, 0.0090, 0),
        ])
        m.latheX(slot: alloy, along: 22, around: 24) { t in
            let p = hub.point(t)
            return SIMD2(p.x, p.y)
        }
        // Disc rotor on the left: steel braking ring on an alloy carrier.
        let rotorX: Float = rear ? -0.050 : -0.046
        let rOut: Float = rear ? 0.070 : 0.080, rIn: Float = rOut - 0.015
        for (x, f) in [(rotorX - 0.0009, Float(-1)), (rotorX + 0.0009, Float(1))] {
            m.annulusX(slot: steel, x: x, inner: rIn, outer: rOut, around: 48, facing: f)
            m.annulusX(slot: alloy, x: x + f * 0.0004, inner: 0.016, outer: rIn + 0.002, around: 24, facing: f)
        }
        m.latheX(slot: steel, along: 1, around: 48, orientation: .auto) { t in SIMD2(rotorX - 0.0009 + 0.0018 * t, rOut) }
        if rear {
            // Cassette, 11–34, largest cog inboard.
            let teeth: [Float] = [34, 30, 27, 24, 21, 19, 17, 15, 14, 13, 12, 11]
            let step = max(1, teeth.count / d.cogs)
            for i in stride(from: 0, to: teeth.count, by: step) {
                let r = teeth[i] * 0.0127 / (2 * .pi) + 0.0030
                let x = 0.0190 + Float(i) * 0.0037
                m.annulusX(slot: steel, x: x - 0.0008, inner: 0.017, outer: r, around: 36, facing: -1)
                m.annulusX(slot: steel, x: x + 0.0008, inner: 0.017, outer: r, around: 36, facing: 1)
                m.latheX(slot: steel, along: 1, around: 36) { t in SIMD2(x - 0.0008 + 0.0016 * t, r) }
            }
            m.latheX(slot: alloy, along: 1, around: 24) { t in SIMD2(0.017 + 0.050 * t, 0.0168) }
        }
        return m
    }

    /// Bladed spokes between the hub flanges and the rim, crossing in pairs.
    static func spokes(rear: Bool, _ d: Detail) -> RiderMesh {
        var m = RiderMesh()
        let count = d.spokes
        for k in 0..<count {
            let sx: Float = k % 2 == 0 ? 1 : -1
            let th = 2 * Float.pi * Float(k) / Float(count)
            let lead: Float = (k / 2) % 2 == 0 ? 0.32 : -0.32
            let hubTh = th + (rear || sx < 0 ? lead : 0)
            let hub = SIMD3<Float>(sx * 0.029, 0.028 * cos(hubTh), 0.028 * sin(hubTh))
            let rimP = SIMD3<Float>(sx * 0.0035, 0.2675 * cos(th), 0.2675 * sin(th))
            m.tube(path: RiderPath([hub, rimP]), along: 1, around: 4, side: SIMD3(1, 0, 0)) { _ in SIMD2(0.0009, 0.0017) }
        }
        return m
    }

    /// The translucent haze a spinning wheel's spokes make.
    static func spokeBlur(_ d: Detail) -> RiderMesh {
        var m = RiderMesh()
        m.surface(along: 1, around: d.wheelAround / 2, orientation: .natural, uv: { t, th in SIMD2(th / (2 * .pi), t) }) { t, th in
            let r = 0.030 + (0.266 - 0.030) * t
            return SIMD3(0, r * cos(th), r * sin(th))
        }
        return m
    }

    // MARK: Crankset (BB at the origin, right arm pointing up at zero angle)

    enum CrankSlot: Int, CaseIterable { case arms, rings }

    static func crankset(_ d: Detail) -> RiderMesh {
        var m = RiderMesh(slots: CrankSlot.allCases.count)
        let arms = CrankSlot.arms.rawValue, rings = CrankSlot.rings.rawValue
        let L = BikeGeometry.crankLength
        func hull(length: Float, r0: Float, r1: Float, angle: Float, samples: Int = 10) -> [SIMD2<Float>] {
            let a = acos(min(max((r0 - r1) / length, -1), 1))
            var pts = [SIMD2<Float>]()
            for k in 0...samples {
                let th = -a + 2 * a * Float(k) / Float(samples)
                pts.append(SIMD2(length + r1 * cos(th), r1 * sin(th)))
            }
            for k in 0...samples * 2 {
                let th = a + (2 * .pi - 2 * a) * Float(k) / Float(samples * 2)
                pts.append(SIMD2(r0 * cos(th), r0 * sin(th)))
            }
            let c = cos(angle), s = sin(angle)
            return pts.map { SIMD2($0.x * c - $0.y * s, $0.x * s + $0.y * c) }
        }
        // Arms: outline in (y, z); right arm along +y, left along −y.
        m.extrudeX(slot: arms, outline: hull(length: L, r0: 0.021, r1: 0.0125, angle: 0), x0: 0.060, x1: 0.074, shear: 0.008 / L)
        m.extrudeX(slot: arms, outline: hull(length: L, r0: 0.021, r1: 0.0125, angle: .pi), x0: -0.074, x1: -0.060, shear: 0.008 / L)
        // Spindle and the four-arm spider.
        m.tube(slot: arms, path: RiderPath([SIMD3(-0.072, 0, 0), SIMD3(0.072, 0, 0)]), along: 1, around: 14, side: SIMD3(0, 1, 0), caps: true) { _ in
            SIMD2(0.0125, 0.0125)
        }
        for k in 0..<4 {
            let ang = Float.pi / 4 + Float(k) * .pi / 2
            m.extrudeX(slot: arms, outline: hull(length: 0.090, r0: 0.017, r1: 0.008, angle: ang, samples: 6), x0: 0.049, x1: 0.056)
        }
        // Chainrings, 50/34.
        func teeth(_ count: Float, root: Float, tip: Float) -> (Float) -> Float {
            { th in
                let ph = th * count / (2 * .pi)
                let f = ph - floor(ph)
                let dd = abs(f - 0.5) * 2
                return root + (tip - root) * (1 - RiderMath.smoothstep(0.30, 0.85, dd))
            }
        }
        m.ringX(slot: rings, inner: 0.086, outer: teeth(50, root: 0.0985, tip: 0.1045), samples: 50 * d.teethSamples, x0: 0.0465, x1: 0.0505)
        m.ringX(slot: rings, inner: 0.058, outer: teeth(34, root: 0.0665, tip: 0.0725), samples: 34 * d.teethSamples, x0: 0.0395, x1: 0.0435)
        return m
    }

    // MARK: Pedal (spindle centre under the cleat at the origin; right side)

    enum PedalSlot: Int, CaseIterable { case body, spindle }

    static func pedal(_ d: Detail) -> RiderMesh {
        var m = RiderMesh(slots: PedalSlot.allCases.count)
        m.tube(slot: PedalSlot.spindle.rawValue, path: RiderPath([SIMD3(-0.040, 0, 0), SIMD3(0.014, 0, 0)]), along: 1, around: 10,
               side: SIMD3(0, 1, 0), caps: true) { _ in SIMD2(0.0075, 0.0075) }
        let prof = RiderProfile([[-0.032, 0.029, 0.002, -0.012], [0.0, 0.031, 0.002, -0.011], [0.030, 0.025, 0.001, -0.008], [0.044, 0.016, 0.000, -0.006]])
        RiderBodyMeshes.domedLoft(&m, slot: PedalSlot.body.rawValue, span: -0.032...0.044, domeStart: 0.006, domeEnd: 0.006, rings: 10,
                                  around: d.around, exponent: 3,
                                  section: { w in
                                      let top = prof(w, 1), bottom = prof(w, 2)
                                      return RiderBodyMeshes.Section(a: prof(w, 0), bNeg: (top - bottom) / 2, bPos: (top - bottom) / 2,
                                                                     cx: 0.002, cy: (top + bottom) / 2)
                                  },
                                  place: { w, x, y in SIMD3(x, y, -w) })
        return m
    }

    // MARK: Chain

    /// The chain loop on the 50 T ring and a 19 T cog, through the rear
    /// derailleur's S-bend. `v` counts 25.4 mm pitches along the loop.
    static func chain(_ d: Detail) -> RiderMesh {
        var pts = [SIMD3<Float>]()
        func arc(_ cf: Float, _ cu: Float, _ r: Float, _ x: Float, from a0: Float, to a1: Float, _ steps: Int) {
            for k in 0..<steps {
                let a = (a0 + (a1 - a0) * Float(k) / Float(steps)) * .pi / 180
                pts.append(B.p(cf + r * cos(a), cu + r * sin(a), x))
            }
        }
        let rc = B.bigRingPitchRadius, rCog: Float = 0.0384, rp: Float = 0.0185
        let xFront: Float = 0.0485, xRear: Float = 0.038
        arc(B.rearAxleF, B.wheelRadius, rCog, xRear, from: -90, to: -270, 16)        // cog, around the back
        arc(0, B.bbHeight, rc, xFront, from: 90, to: -90, 30)                         // chainring, around the front
        arc(-0.402, 0.199, rp, xRear + 0.002, from: -90, to: -270, 10)                // lower pulley, around the back
        arc(-0.366, 0.272, rp, xRear + 0.002, from: -90, to: 90, 10)                  // upper pulley, around the front
        let path = RiderPath(pts, closed: true)
        let pitches = path.length / 0.0254
        var m = RiderMesh()
        m.tube(path: path, along: pts.count * 2, around: 6, side: SIMD3(1, 0, 0), exponent: 3,
               uv: { t, th in SIMD2(th / (2 * .pi), t * pitches) }) { _ in SIMD2(0.0036, 0.0042) }
        return m
    }
}
