import Foundation
import simd

/// Parked cars and vans on the Riviera's roadside: the Poggio's summit car
/// parks (the 2023 summit ride video, the 2020s summit photo: Pandas,
/// Puntos, Golfs, a white Duster, estates, in white, silver, grey, black,
/// dark blue and the odd red) and the growers' vans on the ridge. A shaped
/// body (bonnet, glasshouse, boot or hatch) on four tyred wheels standing
/// on the ground, dark glazing that takes the sky's reflection (the props'
/// dark metal), the paint in the sign atlas's cells or, for silver, the
/// galvanised steel's metal, simple lamps and plates. About 300 triangles
/// a car, built straight into the props (no instancing: 20-40 of them).
extension BuildingBuilder {
    /// The body shapes, with their makers' dimensions.
    enum CarShape: CaseIterable {
        /// A city car, 3.65 x 1.64 x 1.55 m (Fiat Panda, the commonest car
        /// in the summit photos).
        case city
        /// A hatchback, 4.1 x 1.76 x 1.47 m (Fiat Punto, VW Golf, Clio).
        case hatch
        /// An estate, 4.65 x 1.8 x 1.48 m.
        case estate
        /// A compact SUV, 4.34 x 1.8 x 1.68 m (the white Dacia Duster of the
        /// summit photo).
        case suv
        /// A panel van, 5.0 x 2.05 x 2.3 m (a Fiat Ducato: the growers').
        case van
    }

    enum CarPaint: CaseIterable { case white, silver, grey, black, blue, red }

    /// Profile of a shape, metres: z forward from the middle, y up from the
    /// ground.
    struct CarDims {
        var length: Float, width: Float, height: Float
        /// Underside of the body between the wheels.
        var sill: Float
        /// Top of the nose (the bonnet's front edge) and of the tail.
        var noseY: Float, tailY: Float
        /// The glass's foot.
        var belt: Float
        /// Nose to the windscreen's foot; the windscreen's and the rear
        /// window's runs; the boot deck behind the rear window.
        var bonnet: Float, screenRun: Float, rearRun: Float, deck: Float
        var wheelR: Float, wheelbase: Float, frontOverhang: Float
    }

    static func carDims(_ shape: CarShape) -> CarDims {
        switch shape {
        case .city:
            return CarDims(length: 3.65, width: 1.64, height: 1.55, sill: 0.24, noseY: 0.74, tailY: 0.94, belt: 0.98,
                           bonnet: 0.72, screenRun: 0.55, rearRun: 0.1, deck: 0.04, wheelR: 0.29, wheelbase: 2.3,
                           frontOverhang: 0.63)
        case .hatch:
            return CarDims(length: 4.1, width: 1.76, height: 1.47, sill: 0.22, noseY: 0.7, tailY: 0.9, belt: 0.93,
                           bonnet: 0.95, screenRun: 0.75, rearRun: 0.32, deck: 0.06, wheelR: 0.31, wheelbase: 2.6,
                           frontOverhang: 0.85)
        case .estate:
            return CarDims(length: 4.65, width: 1.8, height: 1.48, sill: 0.22, noseY: 0.7, tailY: 0.9, belt: 0.94,
                           bonnet: 1.0, screenRun: 0.78, rearRun: 0.16, deck: 0.06, wheelR: 0.32, wheelbase: 2.75,
                           frontOverhang: 0.9)
        case .suv:
            return CarDims(length: 4.34, width: 1.8, height: 1.68, sill: 0.34, noseY: 0.92, tailY: 1.06, belt: 1.1,
                           bonnet: 1.0, screenRun: 0.62, rearRun: 0.24, deck: 0.06, wheelR: 0.35, wheelbase: 2.67,
                           frontOverhang: 0.85)
        case .van:
            return CarDims(length: 5.0, width: 2.05, height: 2.3, sill: 0.36, noseY: 0.98, tailY: 2.25, belt: 1.25,
                           bonnet: 0.7, screenRun: 0.5, rearRun: 0.0, deck: 0.0, wheelR: 0.36, wheelbase: 3.0,
                           frontOverhang: 0.95)
        }
    }

    /// A shape and a paint as they come in an Italian car park: mostly
    /// city cars and hatchbacks, about a third white, then silver, grey and
    /// black, a few dark blue, the odd red.
    static func randomCar(_ rnd: inout WorldRandom) -> (CarShape, CarPaint) {
        let shape = pickWeighted([(4, CarShape.city), (4, .hatch), (1.5, .estate), (1.2, .suv)], &rnd)
        let paint = pickWeighted([(3.2, CarPaint.white), (2.4, .silver), (2, .grey), (1.6, .black), (0.9, .blue),
                                  (0.5, .red)], &rnd)
        return (shape, paint)
    }

    /// A parked car or van standing on the ground: `centre` (course frame,
    /// metres east and north) under the middle of its body, its nose along
    /// `facing`; `ground` gives the height it stands on there. It sits on
    /// the plane through its four wheels' contacts, so they touch the
    /// ground on a slope.
    static func parkedCar(_ shape: CarShape, paint: CarPaint, centre c2: SIMD2<Double>, facing f2: SIMD2<Double>,
                          ground: (SIMD2<Double>) -> Double, kit: inout RoadsideKit) {
        let d = carDims(shape)
        let f = simd_normalize(f2)
        let r2 = SIMD2(f.y, -f.x)
        let zF = d.length / 2 - d.frontOverhang, zR = zF - d.wheelbase
        let tx = d.width / 2 - 0.12
        func contact(_ x: Float, _ z: Float) -> Double { ground(c2 + r2 * Double(x) + f * Double(z)) }
        let fl = contact(-tx, zF), fr = contact(tx, zF), rl = contact(-tx, zR), rr = contact(tx, zR)
        let mean = Float((fl + fr + rl + rr) / 4)
        let pitch = Float((fl + fr - rl - rr) / 2) / d.wheelbase
        let roll = Float((fr + rr - fl - rl) / 2) / (2 * tx)
        let flatF = SIMD3<Float>(Float(f.x), 0, Float(-f.y)), flatR = SIMD3<Float>(Float(r2.x), 0, Float(-r2.y))
        let fwd = simd_normalize(flatF + SIMD3(0, pitch, 0))
        let up = simd_normalize(simd_cross(simd_normalize(flatR + SIMD3(0, roll, 0)), fwd))
        let right = simd_normalize(simd_cross(fwd, up))
        let base = SIMD3<Float>(Float(c2.x), mean, Float(-c2.y))
        // Local (x right, y up, z forward) to world.
        func W(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { base + right * x + up * y + fwd * z }
        func N(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { simd_normalize(right * x + up * y + fwd * z) }

        var body = MeshBuffer(parts: 1), glass = MeshBuffer(parts: 1), trim = MeshBuffer(parts: 1)
        var tyre = MeshBuffer(parts: 1), rims = MeshBuffer(parts: 1), red = MeshBuffer(parts: 1)
        var lamps = MeshBuffer(parts: 1), plates = MeshBuffer(parts: 1)
        let hw = d.width / 2
        let nose = d.length / 2, tail = -d.length / 2
        let wsFoot = nose - d.bonnet, wsTop = wsFoot - d.screenRun
        let rBase = tail + d.deck, rTop = rBase + d.rearRun
        let roofY = d.height - 0.05
        let van = shape == .van
        // The lower body: the side profile (z, y), convex, extruded across.
        let low = d.sill + 0.12
        var profile: [SIMD2<Float>] = [
            SIMD2(tail + 0.04, low), SIMD2(nose - 0.04, low), SIMD2(nose, low + 0.1), SIMD2(nose, d.noseY - 0.06),
            SIMD2(nose - 0.12, d.noseY), SIMD2(wsFoot, d.belt),
        ]
        if van {
            profile += [SIMD2(tail, d.belt), SIMD2(tail, low + 0.1)]
        } else {
            profile += [SIMD2(rBase, d.belt), SIMD2(tail, d.tailY), SIMD2(tail, low + 0.1)]
        }
        carPrism(&body, profile, halfWidth: hw, W: W, N: N)
        if van {
            // The load box behind the cab, to the roof.
            let cabBack = wsTop - 0.75
            carBox(&body, W(0, (d.belt + d.height) / 2, (cabBack + tail) / 2), right, up, fwd,
                SIMD3(hw, (d.height - d.belt) / 2, (cabBack - tail) / 2))
        }
        // Bumpers and sills in black plastic, the body's lowest band.
        carBox(&trim, W(0, d.sill + 0.07, 0), right, up, fwd, SIMD3(hw - 0.03, 0.07, nose - 0.06))
        carBox(&trim, W(0, low + 0.04, nose - 0.04), right, up, fwd, SIMD3(hw - 0.02, 0.07, 0.06))
        carBox(&trim, W(0, low + 0.04, tail + 0.04), right, up, fwd, SIMD3(hw - 0.02, 0.07, 0.06))
        // The glasshouse: tumblehome sides, the windscreen and the rear
        // window raked; the roof over it in the body's paint, the pillars.
        let hb = hw - 0.05, ht = van ? hw - 0.06 : hw - 0.2
        let gBack = van ? wsTop - 0.75 : rTop
        let gFoot = van ? wsTop - 0.75 : rBase
        let side: [SIMD3<Float>] = [W(hb, d.belt, wsFoot), W(hb, d.belt, gFoot), W(ht, roofY, gBack), W(ht, roofY, wsTop)]
        carQuad(&glass, side, hint: N(1, 0.2, 0))
        carQuad(&glass, [W(-hb, d.belt, wsFoot), W(-hb, d.belt, gFoot), W(-ht, roofY, gBack), W(-ht, roofY, wsTop)],
             hint: N(-1, 0.2, 0))
        carQuad(&glass, [W(-hb, d.belt, wsFoot), W(hb, d.belt, wsFoot), W(ht, roofY, wsTop), W(-ht, roofY, wsTop)],
             hint: N(0, d.screenRun, d.height - d.belt))
        if !van {
            carQuad(&glass, [W(-hb, d.belt, rBase), W(hb, d.belt, rBase), W(ht, roofY, rTop), W(-ht, roofY, rTop)],
                 hint: N(0, d.rearRun + 0.05, -(d.height - d.belt)))
        }
        carBox(&body, W(0, roofY + 0.025, (wsTop + gBack) / 2), right, up, fwd, SIMD3(ht + 0.02, 0.03, (wsTop - gBack) / 2 + 0.03))
        for sx in [-1, 1] as [Float] {
            // A-pillars along the windscreen's sides, the B-pillar, and a
            // hatchback's broad C-pillar.
            TreeArchetype.tube(&body, W(sx * (hb + 0.005), d.belt, wsFoot - 0.03), W(sx * (ht + 0.005), roofY, wsTop - 0.03),
                               0.045, 0.04, sides: 4, height: 100)
            if !van {
                let bz = (wsFoot + gFoot) / 2 - 0.05
                TreeArchetype.tube(&trim, W(sx * (hb + 0.008), d.belt, bz), W(sx * (ht + 0.008), roofY, bz + 0.06),
                                   0.04, 0.035, sides: 4, height: 100)
                let cw: Float = shape == .estate ? 0.06 : 0.14
                carQuad(&body, [W(sx * (hb + 0.006), d.belt, gFoot), W(sx * (hb + 0.006), d.belt, gFoot + cw + 0.18),
                             W(sx * (ht + 0.006), roofY, gBack + cw), W(sx * (ht + 0.006), roofY, gBack)],
                     hint: N(sx, 0.2, 0))
            }
            // Mirrors.
            carBox(&body, W(sx * (hw + 0.07), d.belt + 0.08, wsFoot - 0.12), right, up, fwd, SIMD3(0.07, 0.055, 0.035))
            // Lamps: headlamps, the tail lamps, plates.
            carBox(&lamps, W(sx * (hw - 0.2), d.noseY - 0.1, nose - 0.005), right, up, fwd, SIMD3(0.14, 0.05, 0.02))
            let tailLamp = van ? low + 0.55 : d.tailY - 0.13
            carBox(&red, W(sx * (hw - 0.14), tailLamp, tail + 0.005), right, up, fwd, SIMD3(0.11, van ? 0.16 : 0.06, 0.02))
        }
        carBox(&plates, W(0, d.sill + 0.24, nose + 0.005), right, up, fwd, SIMD3(0.26, 0.06, 0.01))
        carBox(&plates, W(0, van ? low + 0.5 : d.tailY - 0.34, tail - 0.005), right, up, fwd, SIMD3(0.26, 0.06, 0.01))
        // Wheels: the tread, the outer sidewall, a light alloy or steel
        // disc, flat on the ground (a face, not an edge, at the bottom), the
        // dark wheel arch over each.
        let n = 10
        let rc = d.wheelR * cos(.pi / Float(n)) - 0.01
        for (sx, z) in [(-1, zF), (1, zF), (-1, zR), (1, zR)] as [(Float, Float)] {
            let xo = sx * (hw + 0.02), xi = sx * (hw - 0.2)
            var ring: [(Float, Float)] = []
            for k in 0...n {
                let a = (Float(k) + 0.5) * 2 * .pi / Float(n)
                ring.append((sin(a), -cos(a)))
            }
            for k in 0..<n {
                let (s0, c0) = ring[k], (s1, c1) = ring[k + 1]
                let r = d.wheelR
                carQuad(&tyre, [W(xi, rc + c0 * r, z + s0 * r), W(xo, rc + c0 * r, z + s0 * r),
                             W(xo, rc + c1 * r, z + s1 * r), W(xi, rc + c1 * r, z + s1 * r)],
                     hint: N(0, (c0 + c1) / 2, (s0 + s1) / 2))
                let rr = r * 0.62
                carQuad(&tyre, [W(xo, rc + c0 * rr, z + s0 * rr), W(xo, rc + c0 * r, z + s0 * r),
                             W(xo, rc + c1 * r, z + s1 * r), W(xo, rc + c1 * rr, z + s1 * rr)], hint: N(sx, 0, 0))
                let xr = xo - sx * 0.025
                carTri(&rims, [W(xr, rc, z), W(xr, rc + c0 * rr, z + s0 * rr), W(xr, rc + c1 * rr, z + s1 * rr)], hint: N(sx, 0, 0))
                // The arch: a band round the top half, on the body's side.
                if c0 > -0.05 || c1 > -0.05 {
                    let a0 = r + 0.03, a1 = r + 0.09, xa = sx * (hw + 0.004)
                    carQuad(&trim, [W(xa, rc + c0 * a0, z + s0 * a0), W(xa, rc + c0 * a1, z + s0 * a1),
                                 W(xa, rc + c1 * a1, z + s1 * a1), W(xa, rc + c1 * a0, z + s1 * a0)], hint: N(sx, 0, 0))
                }
            }
        }
        // A dark underside between the wheels: shade there in any light.
        carQuad(&trim, [W(-hw + 0.05, 0.03, tail + 0.3), W(hw - 0.05, 0.03, tail + 0.3), W(hw - 0.05, 0.03, nose - 0.3),
                     W(-hw + 0.05, 0.03, nose - 0.3)], hint: N(0, 1, 0))
        switch paint {
        case .white: kit.paint(body, "paint.white")
        case .silver: kit.galvanised.append(body, sx: 1, sy: 1, sz: 1, yaw: 0, tx: 0, ty: 0, tz: 0)
        case .grey: kit.paint(body, "paint.darkgrey")
        case .black: kit.dark.append(body, sx: 1, sy: 1, sz: 1, yaw: 0, tx: 0, ty: 0, tz: 0)
        case .blue: kit.paint(body, "paint.blue")
        case .red: kit.paint(body, "paint.red")
        }
        kit.dark.append(glass, sx: 1, sy: 1, sz: 1, yaw: 0, tx: 0, ty: 0, tz: 0)
        kit.paint(trim, "paint.tyre")
        kit.paint(tyre, "paint.tyre")
        kit.galvanised.append(rims, sx: 1, sy: 1, sz: 1, yaw: 0, tx: 0, ty: 0, tz: 0)
        kit.paint(red, "paint.red")
        kit.glass.append(lamps, sx: 1, sy: 1, sz: 1, yaw: 0, tx: 0, ty: 0, tz: 0)
        kit.paint(plates, "paint.white")
    }

    // MARK: - Car geometry

    /// A convex profile (z, y) extruded from -`halfWidth` to +`halfWidth`
    /// across: its two sides and the faces round it, flat-shaded.
    private static func carPrism(_ m: inout MeshBuffer, _ profile: [SIMD2<Float>], halfWidth hw: Float,
                              W: (Float, Float, Float) -> SIMD3<Float>, N: (Float, Float, Float) -> SIMD3<Float>) {
        let c = profile.reduce(SIMD2<Float>.zero, +) / Float(profile.count)
        for sx in [-1, 1] as [Float] {
            for k in 1..<(profile.count - 1) {
                carTri(&m, [W(sx * hw, profile[0].y, profile[0].x), W(sx * hw, profile[k].y, profile[k].x),
                         W(sx * hw, profile[k + 1].y, profile[k + 1].x)], hint: N(sx, 0, 0))
            }
        }
        for k in profile.indices {
            let a = profile[k], b = profile[(k + 1) % profile.count]
            let mid = (a + b) / 2 - c
            carQuad(&m, [W(-hw, a.y, a.x), W(hw, a.y, a.x), W(hw, b.y, b.x), W(-hw, b.y, b.x)], hint: N(0, mid.y, mid.x))
        }
    }

    /// A box on the car's own axes.
    private static func carBox(_ m: inout MeshBuffer, _ c: SIMD3<Float>, _ x: SIMD3<Float>, _ y: SIMD3<Float>,
                            _ z: SIMD3<Float>, _ h: SIMD3<Float>) {
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (x, y, z, SIMD3(h.x, h.y, h.z)), (-x, y, z, SIMD3(h.x, h.y, h.z)), (y, x, z, SIMD3(h.y, h.x, h.z)),
            (-y, x, z, SIMD3(h.y, h.x, h.z)), (z, x, y, SIMD3(h.z, h.x, h.y)), (-z, x, y, SIMD3(h.z, h.x, h.y)),
        ]
        for (n, u, v, e) in faces {
            let f = c + n * e.x
            let du = u * e.y, dv = v * e.z
            let q: [SIMD3<Float>] = [f - du - dv, f + du - dv, f + du + dv, f - du + dv]
            carQuad(&m, q, hint: n)
        }
    }

    /// A flat quad (or triangle) wound to face `hint`'s side.
    private static func carQuad(_ m: inout MeshBuffer, _ p: [SIMD3<Float>], hint: SIMD3<Float>) {
        guard p.count == 4 else { return }
        var nrm = simd_cross(p[1] - p[0], p[2] - p[0]) + simd_cross(p[2] - p[0], p[3] - p[0])
        let flip = simd_dot(nrm, hint) < 0
        if flip { nrm = -nrm }
        let len = simd_length(nrm)
        guard len > 1e-9 else { return }
        nrm /= len
        let first = UInt32(m.vertexCount)
        for q in p { m.vertex(q.x, q.y, q.z, nrm.x, nrm.y, nrm.z, 0, 0) }
        if flip { m.quad(first, first + 3, first + 2, first + 1) } else { m.quad(first, first + 1, first + 2, first + 3) }
    }

    private static func carTri(_ m: inout MeshBuffer, _ p: [SIMD3<Float>], hint: SIMD3<Float>) {
        var nrm = simd_cross(p[1] - p[0], p[2] - p[0])
        let flip = simd_dot(nrm, hint) < 0
        if flip { nrm = -nrm }
        let len = simd_length(nrm)
        guard len > 1e-9 else { return }
        nrm /= len
        let first = UInt32(m.vertexCount)
        for q in p { m.vertex(q.x, q.y, q.z, nrm.x, nrm.y, nrm.z, 0, 0) }
        if flip { m.tri(first, first + 2, first + 1) } else { m.tri(first, first + 1, first + 2) }
    }
}
