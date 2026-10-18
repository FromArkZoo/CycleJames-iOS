import SceneKit
import simd

/// Procedural mesh accumulator for the rider and bike: shared vertices plus
/// one triangle list per material slot, turned into a single `SCNGeometry`
/// (one draw call per non-empty slot). Everything is built once at init.
struct RiderMesh {
    private(set) var positions: [SIMD3<Float>] = []
    private(set) var normals: [SIMD3<Float>] = []
    private(set) var uvs: [SIMD2<Float>] = []
    private(set) var triangles: [[UInt32]]

    enum Orientation {
        /// Outward is decided from the middle ring's centroid (closed surfaces).
        case auto
        /// Front face along ∂S/∂θ × ∂S/∂t.
        case natural
        case flipped
        /// Front faces point away from a reference point (open surfaces).
        case away(from: SIMD3<Float>)
    }

    init(slots: Int = 1) {
        triangles = Array(repeating: [], count: max(slots, 1))
    }

    var isEmpty: Bool { positions.isEmpty }

    // MARK: - Low level

    @discardableResult
    mutating func vertex(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ uv: SIMD2<Float> = .zero) -> UInt32 {
        positions.append(p)
        normals.append(n)
        uvs.append(uv)
        return UInt32(positions.count - 1)
    }

    /// Adds a triangle wound so its front face points along `facing`.
    mutating func triangle(_ slot: Int, _ a: UInt32, _ b: UInt32, _ c: UInt32, facing: SIMD3<Float>) {
        let pa = positions[Int(a)], pb = positions[Int(b)], pc = positions[Int(c)]
        if dot(cross(pb - pa, pc - pa), facing) >= 0 {
            triangles[slot] += [a, b, c]
        } else {
            triangles[slot] += [a, c, b]
        }
    }

    // MARK: - Parametric surfaces

    /// A grid over the parametric surface `s(t, θ)`, `t ∈ [0, 1]` along it and
    /// `θ` around it. Normals come from central differences of `s` itself, so
    /// shading is smooth whatever the tessellation; poles are handled by
    /// sampling the derivative just inside the parameter range.
    mutating func surface(
        slot: Int = 0,
        along: Int,
        around: Int,
        theta: ClosedRange<Float> = 0...(2 * .pi),
        orientation: Orientation = .auto,
        uv: ((Float, Float) -> SIMD2<Float>)? = nil,
        _ s: (Float, Float) -> SIMD3<Float>
    ) {
        let along = max(along, 1), around = max(around, 2)
        let rows = along + 1, cols = around + 1
        let th0 = theta.lowerBound, th1 = theta.upperBound
        let et: Float = 4e-4, eth: Float = 1e-3
        var pts = [SIMD3<Float>](), nrm = [SIMD3<Float>](), tex = [SIMD2<Float>]()
        pts.reserveCapacity(rows * cols); nrm.reserveCapacity(rows * cols); tex.reserveCapacity(rows * cols)

        for i in 0..<rows {
            let t = Float(i) / Float(along)
            let tc = min(max(t, 2e-3), 1 - 2e-3)
            for j in 0..<cols {
                let th = th0 + (th1 - th0) * Float(j) / Float(around)
                let p = s(t, th)
                let dt = s(min(tc + et, 1), th) - s(max(tc - et, 0), th)
                let dth = s(tc, th + eth) - s(tc, th - eth)
                let n = cross(dth, dt)
                let len = length(n)
                pts.append(p)
                nrm.append(len > 1e-14 ? n / len : SIMD3(0, 1, 0))
                tex.append(uv?(t, th) ?? SIMD2(Float(j) / Float(around), t))
            }
        }

        var flip = false
        switch orientation {
        case .natural: flip = false
        case .flipped: flip = true
        case .away(let ref):
            var score: Float = 0
            for k in 0..<pts.count { score += dot(nrm[k], pts[k] - ref) }
            flip = score < 0
        case .auto:
            var score: Float = 0
            for i in [rows / 2, rows / 3, (2 * rows) / 3] {
                var c = SIMD3<Float>.zero
                for j in 0..<around { c += pts[i * cols + j] }
                c /= Float(around)
                for j in 0..<around { score += dot(nrm[i * cols + j], pts[i * cols + j] - c) }
            }
            flip = score < 0
        }

        let base = UInt32(positions.count)
        for k in 0..<pts.count {
            positions.append(pts[k])
            normals.append(flip ? -nrm[k] : nrm[k])
            uvs.append(tex[k])
        }
        var idx = [UInt32]()
        idx.reserveCapacity(along * around * 6)
        for i in 0..<along {
            for j in 0..<around {
                let a = base + UInt32(i * cols + j)
                let b = a + 1
                let c = a + UInt32(cols)
                let d = c + 1
                if flip {
                    idx += [a, c, b, b, c, d]
                } else {
                    idx += [a, b, c, b, d, c]
                }
            }
        }
        triangles[slot] += idx
    }

    /// A tube swept along `path`. `section(t)` gives the half-widths along the
    /// side axis (`x`, from `side`) and the in-plane axis (`y`). `exponent`
    /// above 2 squares the section off (superellipse).
    mutating func tube(
        slot: Int = 0,
        path: RiderPath,
        along: Int,
        around: Int,
        side: SIMD3<Float> = SIMD3(1, 0, 0),
        exponent: Float = 2,
        caps: Bool = false,
        uv: ((Float, Float) -> SIMD2<Float>)? = nil,
        section: (Float) -> SIMD2<Float>
    ) {
        func point(_ t: Float, _ th: Float) -> SIMD3<Float> {
            let f = path.frame(t, side: side)
            let e = RiderMath.superellipse(th, exponent)
            let ab = section(t)
            return f.origin + f.x * (ab.x * e.x) + f.y * (ab.y * e.y)
        }
        surface(slot: slot, along: along, around: around, orientation: .natural, uv: uv, point)
        if caps {
            for t: Float in [0, 1] {
                let f = path.frame(t, side: side)
                let n = t == 0 ? -f.t : f.t
                let c = vertex(f.origin, n, uv?(t, 0) ?? SIMD2(0.5, t))
                var ring = [UInt32]()
                for j in 0..<around {
                    let th = 2 * Float.pi * Float(j) / Float(around)
                    ring.append(vertex(point(t, th), n, uv?(t, th) ?? SIMD2(0.5, t)))
                }
                for j in 0..<around {
                    triangle(slot, c, ring[j], ring[(j + 1) % around], facing: n)
                }
            }
        }
    }

    /// Solid of revolution about the x axis. `profile(t)` returns (x, radius).
    mutating func latheX(
        slot: Int = 0,
        along: Int,
        around: Int,
        orientation: Orientation = .auto,
        uv: ((Float, Float) -> SIMD2<Float>)? = nil,
        _ profile: (Float) -> SIMD2<Float>
    ) {
        surface(slot: slot, along: along, around: around, orientation: orientation, uv: uv) { t, th in
            let p = profile(t)
            return SIMD3(p.x, p.y * cos(th), p.y * sin(th))
        }
    }

    /// Flat annulus in the plane `x = x`, front face toward `facing` (±1).
    mutating func annulusX(slot: Int = 0, x: Float, inner: Float, outer: Float, around: Int, facing: Float, uv: SIMD2<Float> = SIMD2(0.5, 0.5)) {
        let n = SIMD3<Float>(facing, 0, 0)
        var ring = [(UInt32, UInt32)]()
        for j in 0...around {
            let th = 2 * Float.pi * Float(j) / Float(around)
            let d = SIMD3<Float>(0, cos(th), sin(th))
            let a = vertex(SIMD3(x, 0, 0) + d * inner, n, uv)
            let b = vertex(SIMD3(x, 0, 0) + d * outer, n, uv)
            ring.append((a, b))
        }
        for j in 0..<around {
            let (a, b) = ring[j], (c, d) = ring[j + 1]
            triangle(slot, a, b, d, facing: n)
            triangle(slot, a, d, c, facing: n)
        }
    }

    /// A convex outline in the (y, z) plane extruded from `x0` to `x1`, with
    /// smooth side walls. `shear` adds x proportional to y (crank Q-offset).
    mutating func extrudeX(slot: Int = 0, outline: [SIMD2<Float>], x0: Float, x1: Float, shear: Float = 0, uv: SIMD2<Float> = SIMD2(0.5, 0.5)) {
        let m = outline.count
        guard m >= 3 else { return }
        var centre = SIMD2<Float>.zero
        for p in outline { centre += p }
        centre /= Float(m)
        func p3(_ p: SIMD2<Float>, _ x: Float) -> SIMD3<Float> { SIMD3(x + shear * p.x, p.x, p.y) }
        // Faces.
        for (x, nx) in [(x0, Float(-1)), (x1, Float(1))] {
            let n = SIMD3<Float>(nx, 0, 0)
            let c = vertex(p3(centre, x), n, uv)
            let ring = outline.map { vertex(p3($0, x), n, uv) }
            for j in 0..<m { triangle(slot, c, ring[j], ring[(j + 1) % m], facing: n) }
        }
        // Walls, normals averaged across corners.
        var wallN = [SIMD3<Float>]()
        for j in 0..<m {
            let prev = outline[(j + m - 1) % m], cur = outline[j], next = outline[(j + 1) % m]
            var d = normalize(cur - centre)
            let e = next - prev
            let perp = SIMD2<Float>(e.y, -e.x)
            if length(perp) > 1e-6 { d = normalize(dot(perp, cur - centre) >= 0 ? perp : -perp) }
            wallN.append(SIMD3(0, d.x, d.y))
        }
        for j in 0..<m {
            let k = (j + 1) % m
            let a = vertex(p3(outline[j], x0), wallN[j], uv)
            let b = vertex(p3(outline[k], x0), wallN[k], uv)
            let c = vertex(p3(outline[k], x1), wallN[k], uv)
            let d = vertex(p3(outline[j], x1), wallN[j], uv)
            let facing = wallN[j] + wallN[k]
            triangle(slot, a, b, c, facing: facing)
            triangle(slot, a, c, d, facing: facing)
        }
    }

    /// A flat ring between `inner` and an outer radius that may vary with
    /// angle (chainring teeth), extruded from `x0` to `x1`. Walls are flat
    /// shaded so the teeth read crisply.
    mutating func ringX(slot: Int = 0, inner: Float, outer: (Float) -> Float, samples: Int, x0: Float, x1: Float, uv: SIMD2<Float> = SIMD2(0.5, 0.5)) {
        func dir(_ j: Int) -> SIMD2<Float> {
            let th = 2 * Float.pi * Float(j) / Float(samples)
            return SIMD2(cos(th), sin(th))
        }
        func p(_ r: Float, _ j: Int, _ x: Float) -> SIMD3<Float> {
            let d = dir(j) * r
            return SIMD3(x, d.x, d.y)
        }
        for (x, nx) in [(x0, Float(-1)), (x1, Float(1))] {
            let n = SIMD3<Float>(nx, 0, 0)
            for j in 0..<samples {
                let th0 = 2 * Float.pi * Float(j) / Float(samples)
                let th1 = 2 * Float.pi * Float(j + 1) / Float(samples)
                let a = vertex(p(inner, j, x), n, uv)
                let b = vertex(p(outer(th0), j, x), n, uv)
                let c = vertex(p(outer(th1), j + 1, x), n, uv)
                let d = vertex(p(inner, j + 1, x), n, uv)
                triangle(slot, a, b, c, facing: n)
                triangle(slot, a, c, d, facing: n)
            }
        }
        for j in 0..<samples {
            let th0 = 2 * Float.pi * Float(j) / Float(samples)
            let th1 = 2 * Float.pi * Float(j + 1) / Float(samples)
            // Outer wall.
            let o0 = p(outer(th0), j, 0), o1 = p(outer(th1), j + 1, 0)
            var n = SIMD3<Float>(0, (o0.y + o1.y) / 2, (o0.z + o1.z) / 2)
            let e = o1 - o0
            let perp = SIMD3<Float>(0, e.z, -e.y)
            if length(perp) > 1e-7 { n = dot(perp, n) >= 0 ? normalize(perp) : -normalize(perp) } else { n = normalize(n) }
            quadX(slot, p(outer(th0), j, x0), p(outer(th1), j + 1, x0), x0: x0, x1: x1, normal: n, uv: uv)
            // Inner wall.
            let i0 = p(inner, j, 0), i1 = p(inner, j + 1, 0)
            let ni = -normalize(SIMD3<Float>(0, (i0.y + i1.y) / 2, (i0.z + i1.z) / 2))
            quadX(slot, p(inner, j, x0), p(inner, j + 1, x0), x0: x0, x1: x1, normal: ni, uv: uv)
        }
    }

    private mutating func quadX(_ slot: Int, _ a: SIMD3<Float>, _ b: SIMD3<Float>, x0: Float, x1: Float, normal: SIMD3<Float>, uv: SIMD2<Float>) {
        let va = vertex(a, normal, uv)
        let vb = vertex(b, normal, uv)
        let vc = vertex(SIMD3(x1, b.y, b.z), normal, uv)
        let vd = vertex(SIMD3(x1, a.y, a.z), normal, uv)
        triangle(slot, va, vb, vc, facing: normal)
        triangle(slot, va, vc, vd, facing: normal)
    }

    // MARK: - Whole-mesh operations

    /// Appends `other` transformed by `m` (normals by its inverse transpose;
    /// winding flips when `m` mirrors).
    mutating func append(_ other: RiderMesh, transform m: simd_float4x4 = matrix_identity_float4x4, slotMap: [Int]? = nil) {
        let base = UInt32(positions.count)
        let m3 = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                               SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                               SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        let nm = m3.inverse.transpose
        let mirrored = m3.determinant < 0
        for k in 0..<other.positions.count {
            let p = m * SIMD4(other.positions[k], 1)
            positions.append(SIMD3(p.x, p.y, p.z))
            normals.append(normalize(nm * other.normals[k]))
            uvs.append(other.uvs[k])
        }
        for (s, tris) in other.triangles.enumerated() {
            let slot = slotMap?[s] ?? s
            while triangles.count <= slot { triangles.append([]) }
            var k = 0
            while k + 2 < tris.count {
                if mirrored {
                    triangles[slot] += [base + tris[k], base + tris[k + 2], base + tris[k + 1]]
                } else {
                    triangles[slot] += [base + tris[k], base + tris[k + 1], base + tris[k + 2]]
                }
                k += 3
            }
        }
    }

    /// Mirror image across the x = 0 plane (left limbs from right ones).
    func mirroredX() -> RiderMesh {
        var out = RiderMesh(slots: triangles.count)
        out.append(self, transform: simd_float4x4(diagonal: SIMD4(-1, 1, 1, 1)))
        return out
    }

    /// One geometry element per non-empty slot, paired with `materials`.
    func geometry(_ materials: [SCNMaterial], name: String? = nil) -> SCNGeometry {
        let n = positions.count
        let vData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let nData = normals.withUnsafeBufferPointer { Data(buffer: $0) }
        let tData = uvs.withUnsafeBufferPointer { Data(buffer: $0) }
        let stride3 = MemoryLayout<SIMD3<Float>>.stride
        let stride2 = MemoryLayout<SIMD2<Float>>.stride
        let sources = [
            SCNGeometrySource(data: vData, semantic: .vertex, vectorCount: n, usesFloatComponents: true,
                              componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride3),
            SCNGeometrySource(data: nData, semantic: .normal, vectorCount: n, usesFloatComponents: true,
                              componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride3),
            SCNGeometrySource(data: tData, semantic: .texcoord, vectorCount: n, usesFloatComponents: true,
                              componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 0, dataStride: stride2),
        ]
        var elements = [SCNGeometryElement]()
        var mats = [SCNMaterial]()
        for (slot, tris) in triangles.enumerated() where !tris.isEmpty {
            if n < 65_535 {
                elements.append(SCNGeometryElement(indices: tris.map { UInt16($0) }, primitiveType: .triangles))
            } else {
                elements.append(SCNGeometryElement(indices: tris, primitiveType: .triangles))
            }
            mats.append(slot < materials.count ? materials[slot] : materials.last ?? SCNMaterial())
        }
        let g = SCNGeometry(sources: sources, elements: elements)
        g.materials = mats
        g.name = name
        return g
    }
}

// MARK: - Curves and profiles

/// Smooth curve through control points (centripetal Catmull–Rom), with
/// `t ∈ [0, 1]` spread over the chord length.
struct RiderPath {
    let points: [SIMD3<Float>]
    private let knots: [Float]
    let closed: Bool

    struct Frame {
        var origin: SIMD3<Float>
        var t: SIMD3<Float>
        var x: SIMD3<Float>
        var y: SIMD3<Float>
    }

    init(_ points: [SIMD3<Float>], closed: Bool = false) {
        precondition(points.count >= 2)
        self.points = points
        self.closed = closed
        let segs = closed ? points.count : points.count - 1
        var k: [Float] = [0]
        for i in 0..<segs {
            k.append(k[i] + max(distance(points[i], points[(i + 1) % points.count]), 1e-6))
        }
        let total = k.last!
        knots = k.map { $0 / total }
    }

    var length: Float {
        var l: Float = 0
        let segs = closed ? points.count : points.count - 1
        for i in 0..<segs { l += distance(points[i], points[(i + 1) % points.count]) }
        return l
    }

    private func control(_ i: Int) -> SIMD3<Float> {
        let n = points.count
        if closed { return points[((i % n) + n) % n] }
        if i < 0 { return points[0] * 2 - points[1] }
        if i >= n { return points[n - 1] * 2 - points[n - 2] }
        return points[i]
    }

    func point(_ t: Float) -> SIMD3<Float> {
        let tt = closed ? t - floor(t) : min(max(t, 0), 1)
        var lo = 0, hi = knots.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if knots[mid] <= tt { lo = mid } else { hi = mid }
        }
        let u = (tt - knots[lo]) / max(knots[hi] - knots[lo], 1e-9)
        return Self.catmullRom(control(lo - 1), control(lo), control(lo + 1), control(lo + 2), u)
    }

    func tangent(_ t: Float) -> SIMD3<Float> {
        let e: Float = 1e-3
        let a = closed ? point(t - e) : point(max(t - e, 0))
        let b = closed ? point(t + e) : point(min(t + e, 1))
        let d = b - a
        let l = simd_length(d)
        return l > 1e-9 ? d / l : SIMD3(0, 1, 0)
    }

    /// Frame whose `x` is `side` made perpendicular to the tangent.
    func frame(_ t: Float, side: SIMD3<Float>) -> Frame {
        let tan = tangent(t)
        var x = side - dot(side, tan) * tan
        if simd_length(x) < 1e-5 {
            let alt: SIMD3<Float> = abs(tan.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1)
            x = alt - dot(alt, tan) * tan
        }
        x = normalize(x)
        return Frame(origin: point(t), t: tan, x: x, y: cross(tan, x))
    }

    static func catmullRom(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>, _ u: Float) -> SIMD3<Float> {
        let t0: Float = 0
        let t1 = t0 + max(sqrt(distance(p0, p1)), 1e-4)
        let t2 = t1 + max(sqrt(distance(p1, p2)), 1e-4)
        let t3 = t2 + max(sqrt(distance(p2, p3)), 1e-4)
        let t = t1 + (t2 - t1) * u
        let a1 = p0 * ((t1 - t) / (t1 - t0)) + p1 * ((t - t0) / (t1 - t0))
        let a2 = p1 * ((t2 - t) / (t2 - t1)) + p2 * ((t - t1) / (t2 - t1))
        let a3 = p2 * ((t3 - t) / (t3 - t2)) + p3 * ((t - t2) / (t3 - t2))
        let b1 = a1 * ((t2 - t) / (t2 - t0)) + a2 * ((t - t0) / (t2 - t0))
        let b2 = a2 * ((t3 - t) / (t3 - t1)) + a3 * ((t - t1) / (t3 - t1))
        return b1 * ((t2 - t) / (t2 - t1)) + b2 * ((t - t1) / (t2 - t1))
    }
}

/// Piecewise-cubic interpolation of several channels over increasing keys.
/// Each row is `[x, channel0, channel1, …]`. End slopes are zero so shapes
/// meet joint spheres tangentially.
struct RiderProfile {
    private let xs: [Float]
    private let ys: [[Float]]

    init(_ rows: [[Float]]) {
        xs = rows.map { $0[0] }
        ys = rows.map { Array($0.dropFirst()) }
    }

    func callAsFunction(_ x: Float, _ ch: Int) -> Float {
        let n = xs.count
        if x <= xs[0] { return ys[0][ch] }
        if x >= xs[n - 1] { return ys[n - 1][ch] }
        var i = 0
        while i < n - 2 && xs[i + 1] < x { i += 1 }
        let x0 = xs[i], x1 = xs[i + 1], h = x1 - x0
        let u = (x - x0) / h
        let y0 = ys[i][ch], y1 = ys[i + 1][ch]
        func slope(_ k: Int) -> Float {
            if k == 0 || k == n - 1 { return 0 }
            return (ys[k + 1][ch] - ys[k - 1][ch]) / (xs[k + 1] - xs[k - 1])
        }
        let m0 = slope(i) * h, m1 = slope(i + 1) * h
        let u2 = u * u, u3 = u2 * u
        return (2 * u3 - 3 * u2 + 1) * y0 + (u3 - 2 * u2 + u) * m0 + (-2 * u3 + 3 * u2) * y1 + (u3 - u2) * m1
    }
}

enum RiderMath {
    /// Unit superellipse point; `n == 2` is a circle, larger is squarer.
    @inline(__always)
    static func superellipse(_ th: Float, _ n: Float) -> SIMD2<Float> {
        let c = cos(th), s = sin(th)
        if n == 2 { return SIMD2(c, s) }
        let e = 2 / n
        return SIMD2(copysign(pow(abs(c), e), c), copysign(pow(abs(s), e), s))
    }

    @inline(__always)
    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    @inline(__always)
    static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

    @inline(__always)
    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    /// Rotations about the rig axes (right-handed, radians).
    @inline(__always)
    static func rotX(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1)))
    }

    @inline(__always)
    static func rotY(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1)))
    }

    @inline(__always)
    static func rotZ(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (SIMD4(c, s, 0, 0), SIMD4(-s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
    }
}
