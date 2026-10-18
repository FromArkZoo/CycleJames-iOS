import SceneKit
import simd

/// Growable, flat vertex arrays for building static meshes on a background
/// thread. Hot loops write scalars rather than SIMD values so Debug builds
/// stay usable.
struct MeshBuffer {
    var positions: [Float] = []
    var normals: [Float] = []
    var uvs: [Float] = []
    /// Optional second and third texture channels (`_geometry.texcoords[1]`
    /// and `[2]`), used to carry per-vertex data to the shaders.
    var uv2: [Float] = []
    var uv3: [Float] = []
    /// Optional fourth channel (`texcoords[3]`): billboard corner offsets.
    var uv4: [Float] = []
    /// Optional RGBA per vertex (`_geometry.color`).
    var colors: [Float] = []
    /// One index list per material.
    var parts: [[UInt32]]

    init(parts: Int = 1) {
        self.parts = Array(repeating: [], count: max(parts, 1))
    }

    var vertexCount: Int { positions.count / 3 }
    var triangleCount: Int { parts.reduce(0) { $0 + $1.count / 3 } }
    var isEmpty: Bool { parts.allSatisfy(\.isEmpty) }

    mutating func reserve(vertices: Int, indices: Int, part: Int = 0, uv: Bool = true, color: Bool = false, uv2 channel: Bool = false) {
        positions.reserveCapacity(positions.count + vertices * 3)
        normals.reserveCapacity(normals.count + vertices * 3)
        if uv { uvs.reserveCapacity(uvs.count + vertices * 2) }
        if color { colors.reserveCapacity(colors.count + vertices * 4) }
        if channel { uv2.reserveCapacity(uv2.count + vertices * 2) }
        parts[part].reserveCapacity(parts[part].count + indices)
    }

    @discardableResult
    @inline(__always)
    mutating func vertex(_ x: Float, _ y: Float, _ z: Float,
                         _ nx: Float, _ ny: Float, _ nz: Float,
                         _ u: Float, _ v: Float) -> UInt32 {
        let i = UInt32(positions.count / 3)
        positions.append(x); positions.append(y); positions.append(z)
        normals.append(nx); normals.append(ny); normals.append(nz)
        uvs.append(u); uvs.append(v)
        return i
    }

    @inline(__always)
    mutating func color(_ r: Float, _ g: Float, _ b: Float, _ a: Float) {
        colors.append(r); colors.append(g); colors.append(b); colors.append(a)
    }

    @inline(__always)
    mutating func texcoord2(_ u: Float, _ v: Float) {
        uv2.append(u); uv2.append(v)
    }

    @inline(__always)
    mutating func texcoord3(_ u: Float, _ v: Float) {
        uv3.append(u); uv3.append(v)
    }

    @inline(__always)
    mutating func texcoord4(_ u: Float, _ v: Float) {
        uv4.append(u); uv4.append(v)
    }

    @inline(__always)
    mutating func tri(_ a: UInt32, _ b: UInt32, _ c: UInt32, part: Int = 0) {
        parts[part].append(a); parts[part].append(b); parts[part].append(c)
    }

    /// Two triangles a-b-c, a-c-d (counter-clockwise seen from the front).
    @inline(__always)
    mutating func quad(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32, part: Int = 0) {
        tri(a, b, c, part: part)
        tri(a, c, d, part: part)
    }

    /// Appends `other` scaled by (sx, sy, sz), turned by `yaw` about +y and
    /// moved to (tx, ty, tz). Parts map one to one. Normals use the
    /// inverse-transpose of the scale.
    mutating func append(_ other: MeshBuffer, sx: Float, sy: Float, sz: Float, yaw: Float,
                         tx: Float, ty: Float, tz: Float, partOffset: Int = 0) {
        let base = UInt32(vertexCount)
        let c = cos(yaw), s = sin(yaw)
        let n = other.vertexCount
        positions.reserveCapacity(positions.count + n * 3)
        normals.reserveCapacity(normals.count + n * 3)
        other.positions.withUnsafeBufferPointer { p in
            other.normals.withUnsafeBufferPointer { nm in
                for i in 0..<n {
                    let x = p[3 * i] * sx, y = p[3 * i + 1] * sy, z = p[3 * i + 2] * sz
                    positions.append(x * c + z * s + tx)
                    positions.append(y + ty)
                    positions.append(-x * s + z * c + tz)
                    var nx = nm[3 * i] / sx, ny = nm[3 * i + 1] / sy, nz = nm[3 * i + 2] / sz
                    let l = max(sqrtf(nx * nx + ny * ny + nz * nz), 1e-6)
                    nx /= l; ny /= l; nz /= l
                    normals.append(nx * c + nz * s)
                    normals.append(ny)
                    normals.append(-nx * s + nz * c)
                }
            }
        }
        if !other.uvs.isEmpty { uvs.append(contentsOf: other.uvs) }
        if !other.uv2.isEmpty { uv2.append(contentsOf: other.uv2) }
        if !other.uv3.isEmpty { uv3.append(contentsOf: other.uv3) }
        if !other.uv4.isEmpty { uv4.append(contentsOf: other.uv4) }
        if !other.colors.isEmpty { colors.append(contentsOf: other.colors) }
        for (k, src) in other.parts.enumerated() {
            let dst = k + partOffset
            while parts.count <= dst { parts.append([]) }
            parts[dst].reserveCapacity(parts[dst].count + src.count)
            for idx in src { parts[dst].append(idx + base) }
        }
    }

    /// Centre of the vertex bounding box.
    var boundsCentre: SIMD3<Float> {
        guard vertexCount > 0 else { return .zero }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        positions.withUnsafeBufferPointer { p in
            for i in 0..<vertexCount {
                let v = SIMD3(p[3 * i], p[3 * i + 1], p[3 * i + 2])
                lo = simd_min(lo, v); hi = simd_max(hi, v)
            }
        }
        return (lo + hi) / 2
    }

    /// Moves every vertex by `d`.
    mutating func translate(by d: SIMD3<Float>) {
        let n = vertexCount
        positions.withUnsafeMutableBufferPointer { p in
            for i in 0..<n {
                p[3 * i] += d.x; p[3 * i + 1] += d.y; p[3 * i + 2] += d.z
            }
        }
    }

    /// Area-weighted smooth normals from the triangles (replaces `normals`).
    mutating func computeNormals() {
        let n = vertexCount
        var acc = [Float](repeating: 0, count: n * 3)
        positions.withUnsafeBufferPointer { p in
            acc.withUnsafeMutableBufferPointer { a in
                for part in parts {
                    var t = 0
                    while t + 2 < part.count {
                        let i0 = Int(part[t]), i1 = Int(part[t + 1]), i2 = Int(part[t + 2])
                        let ax = p[3 * i1] - p[3 * i0], ay = p[3 * i1 + 1] - p[3 * i0 + 1], az = p[3 * i1 + 2] - p[3 * i0 + 2]
                        let bx = p[3 * i2] - p[3 * i0], by = p[3 * i2 + 1] - p[3 * i0 + 1], bz = p[3 * i2 + 2] - p[3 * i0 + 2]
                        let cx = ay * bz - az * by, cy = az * bx - ax * bz, cz = ax * by - ay * bx
                        a[3 * i0] += cx; a[3 * i0 + 1] += cy; a[3 * i0 + 2] += cz
                        a[3 * i1] += cx; a[3 * i1 + 1] += cy; a[3 * i1 + 2] += cz
                        a[3 * i2] += cx; a[3 * i2 + 1] += cy; a[3 * i2 + 2] += cz
                        t += 3
                    }
                }
                for i in 0..<n {
                    let x = a[3 * i], y = a[3 * i + 1], z = a[3 * i + 2]
                    let l = sqrtf(x * x + y * y + z * z)
                    if l > 1e-12 { a[3 * i] = x / l; a[3 * i + 1] = y / l; a[3 * i + 2] = z / l } else { a[3 * i + 1] = 1 }
                }
            }
        }
        normals = acc
    }

    /// The SceneKit geometry, one element per non-empty part, each with the
    /// matching material (or the last one if there are fewer materials).
    func geometry(materials: [SCNMaterial]) -> SCNGeometry? {
        let n = vertexCount
        guard n > 0, !isEmpty else { return nil }
        var sources: [SCNGeometrySource] = [Self.source(positions, .vertex, 3)]
        if normals.count == n * 3 { sources.append(Self.source(normals, .normal, 3)) }
        if uvs.count == n * 2 { sources.append(Self.source(uvs, .texcoord, 2)) }
        if uv2.count == n * 2 { sources.append(Self.source(uv2, .texcoord, 2)) }
        if uv2.count == n * 2, uv3.count == n * 2 { sources.append(Self.source(uv3, .texcoord, 2)) }
        if uv2.count == n * 2, uv3.count == n * 2, uv4.count == n * 2 { sources.append(Self.source(uv4, .texcoord, 2)) }
        if colors.count == n * 4 { sources.append(Self.source(colors, .color, 4)) }
        var elements: [SCNGeometryElement] = []
        var mats: [SCNMaterial] = []
        for (k, part) in parts.enumerated() where !part.isEmpty {
            let data: Data
            let bytes: Int
            if n <= 65_535 {
                let small = part.map { UInt16(truncatingIfNeeded: $0) }
                data = small.withUnsafeBufferPointer { Data(buffer: $0) }
                bytes = 2
            } else {
                data = part.withUnsafeBufferPointer { Data(buffer: $0) }
                bytes = 4
            }
            elements.append(SCNGeometryElement(data: data, primitiveType: .triangles,
                                               primitiveCount: part.count / 3, bytesPerIndex: bytes))
            if !materials.isEmpty { mats.append(materials[min(k, materials.count - 1)]) }
        }
        let g = SCNGeometry(sources: sources, elements: elements)
        g.materials = mats
        return g
    }

    private static func source(_ a: [Float], _ semantic: SCNGeometrySource.Semantic, _ comps: Int) -> SCNGeometrySource {
        let data = a.withUnsafeBufferPointer { Data(buffer: $0) }
        return SCNGeometrySource(data: data, semantic: semantic, vectorCount: a.count / comps,
                                 usesFloatComponents: true, componentsPerVector: comps,
                                 bytesPerComponent: 4, dataOffset: 0, dataStride: comps * 4)
    }
}

/// Small deterministic hash-based randomness, so the world looks the same
/// on every ride.
struct WorldRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

    init(_ a: Double, _ b: Double, salt: UInt64 = 0) {
        let ia = UInt64(bitPattern: Int64((a * 100).rounded()))
        let ib = UInt64(bitPattern: Int64((b * 100).rounded()))
        self.init(seed: ia &* 0x1F1F_1F1F &+ ib &* 0x0101_0101_0103 &+ salt &* 0x5851_F42D_4C95_7F2D)
    }

    mutating func next() -> UInt64 {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
    mutating func range(_ lo: Float, _ hi: Float) -> Float { lo + (hi - lo) * unit() }
    /// Roughly normal, mean 0, sd 1.
    mutating func gauss() -> Float { (unit() + unit() + unit() + unit() - 2) * 1.732 }
}

@inline(__always) func smoothstepF(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}
