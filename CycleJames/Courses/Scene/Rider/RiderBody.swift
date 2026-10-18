import SceneKit
import simd

/// Anthropometry of the rider: a 1.80 m, 75 kg road cyclist. Segment
/// lengths follow Winter's proportions (thigh 0.245 H, shank 0.24 H, upper
/// arm 0.18 H, forearm 0.14 H). Every limb is a capsule whose ends are
/// spheres centred on the joints, so neighbouring segments blend at any angle.
struct RiderBodyLayout {
    let thighLength: Float = 0.440
    let shankLength: Float = 0.435
    let upperArmLength: Float = 0.315
    let forearmLength: Float = 0.255
    let neckLength: Float = 0.100

    let hipRadius: Float = 0.080
    let kneeRadius: Float = 0.055
    let ankleRadius: Float = 0.034
    let shoulderRadius: Float = 0.052
    let elbowRadius: Float = 0.040
    let wristRadius: Float = 0.026
    let neckBaseRadius: Float = 0.058
    let neckTopRadius: Float = 0.052

    /// Hip joints in the pelvis frame (origin midway between them).
    let hipHalfWidth: Float = 0.088
    /// Waist joint (base of the torso) in the pelvis frame.
    let waist = SIMD3<Float>(0, 0.115, 0.012)
    /// Shoulder joints and the base of the neck in the torso frame.
    let shoulder = SIMD3<Float>(0.172, 0.392, -0.005)
    let neckBase = SIMD3<Float>(0, 0.462, 0.028)
    /// Eyes in the head frame (origin at the top of the neck).
    let eyes = SIMD3<Float>(0, 0.056, -0.098)

    /// Ankle relative to the pedal spindle, in the foot frame (−z = toes):
    /// cleat under the ball of the foot, 11 mm pedal stack.
    let ankleFromSpindle = SIMD3<Float>(0, 0.093, 0.140)

    /// Where the kit changes, in metres along each limb's texture (from the
    /// top of its proximal cap).
    var thighShortsEnd: Float { capArc(hipRadius) + 0.300 }
    var shankSockTop: Float { capArc(kneeRadius * 0.985) + shankLength - 0.160 }
    var sleeveEnd: Float { capArc(shoulderRadius) + 0.165 }

    var thighTotal: Float { capArc(hipRadius) + thighLength + capArc(kneeRadius) }
    var shankTotal: Float { capArc(kneeRadius * 0.985) + shankLength + capArc(ankleRadius) }
    var upperArmTotal: Float { capArc(shoulderRadius) + upperArmLength + capArc(elbowRadius) }

    func capArc(_ r: Float) -> Float { .pi / 2 * r }
}

/// Mesh builders for the body parts, each in its own segment frame:
/// limbs hang along −y from the proximal joint at the origin, −z is
/// anterior, +x is lateral for a right limb (left limbs are mirrored).
enum RiderBodyMeshes {
    struct Detail {
        let around: Int
        let along: Float   // rings per metre

        init(_ q: GraphicsQuality) {
            switch q {
            case .high: around = 28; along = 90
            case .balanced: around = 22; along = 70
            case .battery: around = 14; along = 45
            }
        }

        func rings(_ length: Float, min: Int = 6) -> Int { Swift.max(min, Int(length * along)) }
    }

    // MARK: Limbs

    /// Capsule from the proximal joint (origin, sphere `r0`) down to the
    /// distal joint at (0, −length, 0) (sphere `r1`). `stations` rows are
    /// `[d, a, b, cz, cx]`: depth below the proximal joint, lateral and
    /// antero-posterior half-widths, posterior and lateral centre offsets.
    static func limb(length L: Float, r0: Float, r1: Float, stations: [[Float]], detail: Detail) -> RiderMesh {
        var rows = stations
        if rows.first?[0] ?? 1 > 0 { rows.insert([0, r0, r0, 0, 0], at: 0) }
        if rows.last?[0] ?? 0 < L { rows.append([L, r1, r1, 0, 0]) }
        let prof = RiderProfile(rows)
        let capTop = Float.pi / 2 * r0, capBottom = Float.pi / 2 * r1
        let total = capTop + L + capBottom
        var mesh = RiderMesh()
        mesh.surface(along: detail.rings(total), around: detail.around,
                     uv: { t, th in SIMD2(th / (2 * .pi), t) }) { t, th in
            let s = t * total
            if s <= capTop {
                let phi = s / r0
                let rad = r0 * sin(phi)
                return SIMD3(rad * cos(th), r0 * cos(phi), rad * sin(th))
            }
            if s >= capTop + L {
                let phi = (s - capTop - L) / r1
                let rad = r1 * cos(phi)
                return SIMD3(rad * cos(th), -L - r1 * sin(phi), rad * sin(th))
            }
            let d = s - capTop
            return SIMD3(prof(d, 3) + prof(d, 0) * cos(th), -d, prof(d, 2) + prof(d, 1) * sin(th))
        }
        return mesh
    }

    static func thigh(_ l: RiderBodyLayout, _ q: Detail) -> RiderMesh {
        limb(length: l.thighLength, r0: l.hipRadius, r1: l.kneeRadius, stations: [
            [0.000, l.hipRadius, l.hipRadius, 0, 0],
            [0.060, 0.083, 0.088, 0.000, 0.000],
            [0.140, 0.076, 0.081, -0.008, 0.000],
            [0.240, 0.068, 0.074, -0.010, -0.002],
            [0.330, 0.060, 0.064, -0.008, -0.004],
            [0.400, 0.056, 0.057, -0.003, -0.002],
        ], detail: q)
    }

    static func shank(_ l: RiderBodyLayout, _ q: Detail) -> RiderMesh {
        limb(length: l.shankLength, r0: l.kneeRadius * 0.985, r1: l.ankleRadius, stations: [
            [0.000, l.kneeRadius * 0.985, l.kneeRadius * 0.985, 0, 0],
            [0.050, 0.051, 0.051, 0.004, 0.000],
            [0.130, 0.058, 0.062, 0.017, -0.004],
            [0.200, 0.052, 0.055, 0.014, -0.003],
            [0.290, 0.040, 0.040, 0.006, 0.000],
            [0.370, 0.032, 0.032, 0.002, 0.000],
        ], detail: q)
    }

    static func upperArm(_ l: RiderBodyLayout, _ q: Detail) -> RiderMesh {
        limb(length: l.upperArmLength, r0: l.shoulderRadius, r1: l.elbowRadius, stations: [
            [0.000, l.shoulderRadius, l.shoulderRadius, 0, 0],
            [0.050, 0.050, 0.048, 0.000, 0.004],
            [0.110, 0.043, 0.044, -0.002, 0.002],
            [0.180, 0.038, 0.042, -0.004, 0.000],
            [0.250, 0.038, 0.040, -0.002, 0.000],
        ], detail: q)
    }

    static func forearm(_ l: RiderBodyLayout, _ q: Detail) -> RiderMesh {
        limb(length: l.forearmLength, r0: l.elbowRadius * 0.985, r1: l.wristRadius, stations: [
            [0.000, l.elbowRadius * 0.985, l.elbowRadius * 0.985, 0, 0],
            [0.045, 0.040, 0.036, 0.000, 0.000],
            [0.100, 0.037, 0.031, 0.000, 0.000],
            [0.170, 0.031, 0.024, 0.000, 0.000],
            [0.225, 0.028, 0.020, 0.000, 0.000],
        ], detail: q)
    }

    static func neck(_ l: RiderBodyLayout, _ q: Detail) -> RiderMesh {
        limb(length: l.neckLength, r0: l.neckBaseRadius, r1: l.neckTopRadius, stations: [
            [0.000, l.neckBaseRadius, l.neckBaseRadius, 0, 0],
            [0.050, 0.055, 0.053, 0.000, 0.000],
        ], detail: q)
    }

    // MARK: Lofts with domed ends

    /// Cross-section of a loft: half-width `a` along the section's x, front
    /// and back half-depths, and the section centre.
    struct Section {
        var a: Float
        var bNeg: Float
        var bPos: Float
        var cx: Float = 0
        var cy: Float = 0
    }

    /// Loft over axial coordinate `w ∈ span`, each section placed in 3D by
    /// `place(w, x, y)`. Both ends close with elliptical domes of the given
    /// lengths, so nothing is left open.
    static func domedLoft(
        _ mesh: inout RiderMesh,
        slot: Int = 0,
        span: ClosedRange<Float>,
        domeStart: Float,
        domeEnd: Float,
        rings: Int,
        around: Int,
        exponent: Float = 2,
        uv: ((Float, Float) -> SIMD2<Float>)? = nil,
        section: (Float) -> Section,
        place: @escaping (Float, Float, Float) -> SIMD3<Float>
    ) {
        let w0 = span.lowerBound, w1 = span.upperBound
        let lStart = domeStart * 1.4, lEnd = domeEnd * 1.4
        let total = lStart + (w1 - w0) + lEnd
        // Texture v is the axial fraction (domes clamp to 0 / 1), so kit
        // details land at fixed heights whatever the tessellation.
        let axial: (Float) -> Float = { t in min(max((t * total - lStart) / (w1 - w0), 0), 1) }
        let texture: (Float, Float) -> SIMD2<Float> = { t, th in
            uv?(axial(t), th) ?? SIMD2(th / (2 * .pi), axial(t))
        }
        mesh.surface(slot: slot, along: rings, around: around, uv: texture) { t, th in
            let s = t * total
            var w: Float, k: Float = 1, sec: Section
            if s < lStart {
                let phi = s / lStart * .pi / 2
                w = w0 - domeStart * cos(phi); k = sin(phi); sec = section(w0)
            } else if s > lStart + (w1 - w0) {
                let phi = (total - s) / lEnd * .pi / 2
                w = w1 + domeEnd * cos(phi); k = sin(phi); sec = section(w1)
            } else {
                w = w0 + (s - lStart); sec = section(w)
            }
            let e = RiderMath.superellipse(th, exponent)
            let bAvg = (sec.bNeg + sec.bPos) / 2, bDiff = (sec.bPos - sec.bNeg) / 2
            let x = sec.cx + k * sec.a * e.x
            let y = sec.cy + k * e.y * (bAvg + bDiff * e.y)
            return place(w, x, y)
        }
    }

    /// Rows `[y, a, bFront, bBack, cz, cx]` → a vertical loft, x lateral, z back.
    static func verticalLoft(_ mesh: inout RiderMesh, rows: [[Float]], domeBottom: Float, domeTop: Float, detail: Detail,
                             uv: ((Float, Float) -> SIMD2<Float>)? = nil) {
        let prof = RiderProfile(rows)
        let y0 = rows.first![0], y1 = rows.last![0]
        let len = (y1 - y0) + 1.4 * (domeBottom + domeTop)
        domedLoft(&mesh, span: y0...y1, domeStart: domeBottom, domeEnd: domeTop,
                  rings: detail.rings(len, min: 10), around: detail.around, uv: uv,
                  section: { y in Section(a: prof(y, 0), bNeg: prof(y, 1), bPos: prof(y, 2), cx: prof(y, 4), cy: prof(y, 3)) },
                  place: { y, x, z in SIMD3(x, y, z) })
    }

    // MARK: Trunk

    static func pelvis(_ q: Detail) -> RiderMesh {
        var m = RiderMesh()
        verticalLoft(&m, rows: [
            [-0.078, 0.082, 0.048, 0.088, 0.034, 0],
            [-0.045, 0.128, 0.074, 0.110, 0.024, 0],
            [-0.005, 0.146, 0.085, 0.122, 0.015, 0],
            [0.045, 0.146, 0.092, 0.112, 0.006, 0],
            [0.100, 0.138, 0.094, 0.096, 0.002, 0],
            [0.150, 0.132, 0.090, 0.086, 0.004, 0],
        ], domeBottom: 0.016, domeTop: 0.03, detail: q)
        return m
    }

    static func torso(_ q: Detail) -> RiderMesh {
        var m = RiderMesh()
        let rows: [[Float]] = [
            [-0.070, 0.166, 0.112, 0.124, 0.000, 0],
            [0.000, 0.153, 0.104, 0.104, 0.000, 0],
            [0.100, 0.152, 0.106, 0.100, 0.000, 0],
            [0.200, 0.160, 0.118, 0.106, 0.000, 0],
            [0.280, 0.166, 0.122, 0.112, 0.000, 0],
            [0.350, 0.168, 0.114, 0.116, 0.006, 0],
            [0.410, 0.156, 0.094, 0.104, 0.012, 0],
            [0.452, 0.112, 0.072, 0.086, 0.018, 0],
            [0.488, 0.066, 0.056, 0.060, 0.022, 0],
        ]
        verticalLoft(&m, rows: rows, domeBottom: 0.008, domeTop: 0.012, detail: q)
        return m
    }

    // MARK: Head, helmet, glasses

    static func head(_ q: Detail) -> RiderMesh {
        var m = RiderMesh()
        verticalLoft(&m, rows: [
            [-0.050, 0.022, 0.016, 0.012, -0.080, 0],
            [-0.035, 0.040, 0.026, 0.030, -0.065, 0],
            [-0.010, 0.056, 0.045, 0.045, -0.045, 0],
            [0.020, 0.066, 0.075, 0.070, -0.025, 0],
            [0.055, 0.074, 0.098, 0.090, -0.020, 0],
            [0.090, 0.078, 0.100, 0.098, -0.018, 0],
            [0.125, 0.074, 0.090, 0.094, -0.015, 0],
            [0.150, 0.060, 0.070, 0.076, -0.012, 0],
        ], domeBottom: 0.012, domeTop: 0.03, detail: q)
        let faceUV = SIMD2<Float>(0.75, 0.3)
        // Nose.
        let nose = RiderPath([SIMD3(0, 0.060, -0.108), SIMD3(0, 0.040, -0.121), SIMD3(0, 0.022, -0.131), SIMD3(0, 0.014, -0.118)])
        m.tube(path: nose, along: 8, around: max(8, q.around / 2), side: SIMD3(1, 0, 0), caps: true,
               uv: { _, _ in faceUV }) { t in
            SIMD2(0.008 + 0.007 * t, 0.006 + 0.004 * sin(t * .pi))
        }
        // Ears.
        for sx: Float in [-1, 1] {
            let c = SIMD3<Float>(sx * 0.073, 0.034, 0.006)
            m.surface(along: 8, around: max(8, q.around / 2), uv: { _, _ in faceUV }) { t, th in
                let phi = t * .pi
                return c + SIMD3(0.009 * cos(phi), 0.029 * sin(phi) * cos(th), 0.017 * sin(phi) * sin(th))
            }
        }
        return m
    }

    /// Polar angle of the helmet rim at azimuth `th` (0 = right, π/2 = back).
    static func helmetRim(_ th: Float) -> Float {
        (95 + 16 * sin(th) - 5 * cos(2 * th)) * .pi / 180
    }

    static let helmetCentre = SIMD3<Float>(0, 0.085, -0.012)
    static let helmetRadii = SIMD3<Float>(0.104, 0.120, 0.137)

    static func helmetPoint(_ phi: Float, _ th: Float, scale: Float = 1) -> SIMD3<Float> {
        let r = helmetRadii * scale
        // Slight aero taper at the back.
        let tail: Float = 1 + 0.06 * max(sin(th), 0) * sin(phi)
        return helmetCentre + SIMD3(r.x * sin(phi) * cos(th), r.y * cos(phi), r.z * tail * sin(phi) * sin(th))
    }

    /// Shell (slot 0) and straps / rim lip (slot 1).
    static func helmet(_ q: Detail) -> RiderMesh {
        var m = RiderMesh(slots: 2)
        let rings = max(10, q.around / 2 + 4)
        m.surface(slot: 0, along: rings, around: q.around * 2, orientation: .away(from: helmetCentre),
                  uv: { t, th in SIMD2(th / (2 * .pi), t) }) { t, th in
            helmetPoint(t * helmetRim(th), th)
        }
        // Rim lip: the shell's thickness, seen from below and at the edges.
        m.surface(slot: 1, along: 2, around: q.around * 2, orientation: .away(from: helmetCentre + SIMD3(0, 0.4, 0))) { t, th in
            let phi = helmetRim(th)
            return simd_mix(helmetPoint(phi, th), helmetPoint(phi - 0.05, th, scale: 0.8), SIMD3(repeating: t))
        }
        // Chin straps: front and rear straps meet below each ear and run to the buckle.
        for sx: Float in [-1, 1] {
            let junction = SIMD3<Float>(sx * 0.062, -0.012, -0.002)
            let paths = [
                RiderPath([SIMD3(sx * 0.082, 0.082, -0.060), SIMD3(sx * 0.074, 0.040, -0.040), junction]),
                RiderPath([SIMD3(sx * 0.080, 0.070, 0.060), SIMD3(sx * 0.074, 0.030, 0.030), junction]),
                RiderPath([junction, SIMD3(sx * 0.050, -0.040, -0.035), SIMD3(sx * 0.018, -0.062, -0.068), SIMD3(0, -0.064, -0.072)]),
            ]
            for p in paths {
                m.tube(slot: 1, path: p, along: 10, around: 6, side: SIMD3(1, 0, 0), exponent: 3) { _ in SIMD2(0.0016, 0.0055) }
            }
        }
        return m
    }

    /// Wraparound sunglasses: lens (slot 0) and frame (slot 1).
    static func glasses(_ q: Detail) -> RiderMesh {
        var m = RiderMesh(slots: 2)
        let axis = SIMD3<Float>(0, 0.060, -0.036)
        let radius: Float = 0.090
        let psiMax: Float = 75 * .pi / 180
        func lensPoint(_ psi: Float, _ y: Float) -> SIMD3<Float> {
            let tilt = (0.06 - y) * 0.15          // pantoscopic tilt
            let r = radius - tilt
            return SIMD3(axis.x + r * sin(psi), y, axis.z - r * cos(psi))
        }
        func bottom(_ psi: Float) -> Float {
            let n = psi / psiMax
            return 0.031 + 0.006 * n * n + 0.024 * exp(-(psi * psi) / (0.22 * 0.22))
        }
        func top(_ psi: Float) -> Float {
            let n = psi / psiMax
            return 0.090 - 0.010 * n * n
        }
        m.surface(slot: 0, along: 8, around: max(16, q.around), theta: -psiMax...psiMax,
                  orientation: .away(from: axis), uv: { t, _ in SIMD2(0.5, 1 - t) }) { t, psi in
            lensPoint(psi, bottom(psi) + (top(psi) - bottom(psi)) * t)
        }
        // Brow bar along the top edge.
        var brow = [SIMD3<Float>]()
        for k in 0...12 {
            let psi = -psiMax + 2 * psiMax * Float(k) / 12
            brow.append(lensPoint(psi, top(psi) + 0.002) + SIMD3(0, 0, 0.001))
        }
        m.tube(slot: 1, path: RiderPath(brow), along: 24, around: 6, side: SIMD3(0, 1, 0), caps: true) { _ in SIMD2(0.004, 0.003) }
        // Temple arms back over the ears.
        for sx: Float in [-1, 1] {
            let start = lensPoint(sx * psiMax, top(psiMax) - 0.004)
            let arm = RiderPath([start, SIMD3(sx * 0.081, 0.075, -0.02), SIMD3(sx * 0.079, 0.062, 0.030)])
            m.tube(slot: 1, path: arm, along: 8, around: 6, side: SIMD3(1, 0, 0), caps: true) { _ in SIMD2(0.0022, 0.004) }
        }
        return m
    }

    // MARK: Shoes

    /// Road shoe in the foot frame (origin at the ankle, −z toward the toes),
    /// with cleat and dial. One texture: u = 0.75 is the sole.
    static func shoe(_ q: Detail) -> RiderMesh {
        var m = RiderMesh()
        let heelZ: Float = 0.072
        let rows: [[Float]] = [   // w from heel, a, ySole, yTop, cx (medial = −x for the right foot)
            [0.000, 0.026, -0.074, -0.022, 0.000],
            [0.020, 0.035, -0.082, -0.006, 0.000],
            [0.050, 0.038, -0.083, -0.004, 0.000],
            [0.085, 0.040, -0.084, -0.012, 0.000],
            [0.135, 0.046, -0.084, -0.024, -0.001],
            [0.185, 0.050, -0.084, -0.034, -0.003],
            [0.230, 0.049, -0.083, -0.041, -0.006],
            [0.265, 0.042, -0.081, -0.042, -0.008],
            [0.290, 0.031, -0.079, -0.047, -0.010],
        ]
        let prof = RiderProfile(rows)
        domedLoft(&m, span: 0...0.29, domeStart: 0.010, domeEnd: 0.016, rings: q.rings(0.33, min: 14),
                  around: q.around, exponent: 2.6,
                  section: { w in
                      let ys = prof(w, 1), yt = prof(w, 2)
                      return Section(a: prof(w, 0), bNeg: (yt - ys) / 2, bPos: (yt - ys) / 2, cx: prof(w, 3), cy: (yt + ys) / 2)
                  },
                  place: { w, x, y in SIMD3(x, y, heelZ - w) })
        let soleUV = SIMD2<Float>(0.75, 0.5)
        // Cleat under the ball of the foot.
        let cleat = RiderPath([SIMD3(0, -0.088, -0.105), SIMD3(0, -0.088, -0.170)])
        m.tube(path: cleat, along: 2, around: 8, side: SIMD3(1, 0, 0), exponent: 3, caps: true, uv: { _, _ in soleUV }) { _ in
            SIMD2(0.026, 0.0045)
        }
        // Ratchet dial on the outside of the instep.
        let dial = RiderPath([SIMD3(0.030, -0.018, -0.070), SIMD3(0.040, -0.012, -0.070)])
        m.tube(path: dial, along: 1, around: 10, side: SIMD3(0, 0, 1), caps: true, uv: { _, _ in soleUV }) { _ in
            SIMD2(0.013, 0.013)
        }
        return m
    }

    // MARK: Hands

    /// A gloved hand wrapped over a brake hood, in bike space. `wrist` is
    /// the wrist joint, `hoodTop` the top of the hood where the palm sits,
    /// `side` +1 right / −1 left.
    static func hand(wrist: SIMD3<Float>, hoodTop: SIMD3<Float>, side sx: Float, wristRadius: Float, _ q: Detail) -> RiderMesh {
        var m = RiderMesh()
        let up = SIMD3<Float>(0, 1, 0), out = SIMD3<Float>(sx, 0, 0)
        /// Offset forward, up and outward (toward this hand's side).
        func off(_ f: Float, _ u: Float, _ o: Float) -> SIMD3<Float> { SIMD3(sx * o, u, -f) }
        // Handshake grip: the knuckle line runs from the pinky (low, outside)
        // to the index (high, inside); the palm sits on the hood's outer top.
        let breadth = normalize(up * 0.80 - out * 0.60)
        let knuckles = hoodTop + off(0.030, 0.006, 0.020)
        let palm = RiderPath([wrist, hoodTop + off(-0.022, 0.020, 0.017), knuckles])
        let around = max(10, q.around / 2)
        m.tube(path: palm, along: 10, around: around, side: breadth, exponent: 2.4, caps: true) { t in
            let w = RiderMath.smoothstep(0, 0.55, t)
            return SIMD2(RiderMath.mix(wristRadius * 1.05, 0.040, w), RiderMath.mix(wristRadius, 0.0145, t))
        }
        m.surface(along: 8, around: around) { t, th in
            let phi = t * .pi, r = wristRadius * 1.05
            let d = SIMD3<Float>(sin(phi) * cos(th), cos(phi), sin(phi) * sin(th))
            return wrist + d * r
        }
        // Fingers curl forward over the hood, then down its outside and under.
        let offsets: [Float] = [0.026, 0.009, -0.008, -0.024]
        let lengths: [Float] = [0.074, 0.082, 0.076, 0.062]
        for (o, l) in zip(offsets, lengths) {
            let k = knuckles + breadth * o
            let p1 = k + off(0.32 * l, -0.10 * l, 0.10 * l)
            let p2 = k + off(0.42 * l, -0.48 * l, 0.06 * l)
            let p3 = k + off(0.30 * l, -0.78 * l, -0.22 * l)
            m.tube(path: RiderPath([k, p1, p2, p3]), along: 10, around: 8, side: out, caps: true) { t in
                let r: Float = 0.0088 - 0.0018 * t
                return SIMD2(r, r * 0.92)
            }
        }
        // Thumb round the inside of the hood.
        let thumb = RiderPath([wrist + off(0.008, -0.008, -0.010), hoodTop + off(0.004, 0.002, -0.022), hoodTop + off(0.034, -0.010, -0.020)])
        m.tube(path: thumb, along: 8, around: 8, side: up, caps: true) { t in
            SIMD2(0.0115 - 0.0025 * t, 0.0105 - 0.002 * t)
        }
        return m
    }
}
