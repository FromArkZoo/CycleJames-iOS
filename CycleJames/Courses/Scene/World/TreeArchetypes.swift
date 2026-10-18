import Foundation
import simd

/// Procedural tree models at a reference size, scaled per tree when placed.
/// Each has a full version (trunk, branches, clumped leaf cards), a light
/// version for the middle distance and an impostor cell in cj_impostor.png.
///
/// Mesh parts: 0 = bark, 1 = leaves. Texture channel 1 carries the wind
/// sway weight (x; y is the per-tree phase, filled in at placement) and
/// channel 2 the leaf shading (x = ambient occlusion, y = tint, also per
/// tree).
struct TreeArchetype {
    enum Kind: Int { case broadleaf, poplar, conifer, orchard }

    let kind: Kind
    let refHeight: Float
    let refRadius: Float
    var full: MeshBuffer
    var light: MeshBuffer
    /// Cell in the impostor atlas (0 broadleaf, 1 poplar, 2 conifer, 3 orchard).
    var impostorCell: Int { [0, 1, 2, 3][kind.rawValue] }

    /// Leaf-card atlas quadrants (u0, v0, u1, v1) in cj_foliage.png.
    static let broadUV: SIMD4<Float> = SIMD4(0.005, 0.005, 0.495, 0.495)
    static let poplarUV: SIMD4<Float> = SIMD4(0.505, 0.005, 0.995, 0.495)
    static let ivyUV: SIMD4<Float> = SIMD4(0.005, 0.505, 0.495, 0.995)
    static let needleUV: SIMD4<Float> = SIMD4(0.505, 0.505, 0.995, 0.995)

    static func makeAll() -> [TreeArchetype] {
        [
            broadleaf(seed: 1), broadleaf(seed: 2), broadleaf(seed: 3),
            poplar(seed: 4), poplar(seed: 5),
            conifer(seed: 6),
            orchard(seed: 7), orchard(seed: 8),
        ]
    }

    // MARK: - Geometry helpers

    /// Tapered tube from `a` to `b` (bark, part 0).
    static func tube(_ m: inout MeshBuffer, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ r0: Float, _ r1: Float,
                     sides: Int, height: Float, vStart: Float = 0, baseY: Float = 0) {
        let axis = b - a
        let len = simd_length(axis)
        guard len > 1e-4 else { return }
        let dir = axis / len
        let ref: SIMD3<Float> = abs(dir.y) < 0.95 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let u = simd_normalize(simd_cross(ref, dir))
        let w = simd_cross(dir, u)
        let first = UInt32(m.vertexCount)
        for ring in 0...1 {
            let p = ring == 0 ? a : b
            let r = ring == 0 ? r0 : r1
            for k in 0...sides {
                let ang = Float(k) / Float(sides) * 2 * .pi
                let n = u * cos(ang) + w * sin(ang)
                let q = p + n * r
                m.vertex(q.x, q.y, q.z, n.x, n.y, n.z, Float(k) / Float(sides), vStart + Float(ring) * len * 0.5)
                let sway = swayWeight(y: q.y - baseY, height: height)
                m.texcoord2(sway, 0)
                m.texcoord3(1, 0)
                m.texcoord4(0, 0)
            }
        }
        for k in 0..<sides {
            let a0 = first + UInt32(k), a1 = a0 + 1
            let b0 = first + UInt32(sides + 1 + k), b1 = b0 + 1
            m.tri(a0, a1, b0, part: 0)
            m.tri(a1, b1, b0, part: 0)
        }
    }

    /// Sway grows with height above the ground; roughly 1 at the top of a
    /// 14 m tree.
    @inline(__always)
    static func swayWeight(y: Float, height: Float) -> Float {
        let t = max(y, 0) / max(height, 1)
        return t * t * (height / 14)
    }

    /// One leaf card (part 1). `normal` faces outward; normals are bent away
    /// from the crown centre so a crown shades like a volume. Billboard
    /// cards keep all four corners at the centre and carry their (rolled)
    /// corner offsets in texture channel 3; the wind shader turns them to
    /// face the viewer, so a crown never shows a card edge-on.
    static func card(_ m: inout MeshBuffer, centre c: SIMD3<Float>, size: Float, normal: SIMD3<Float>,
                     roll: Float, uv: SIMD4<Float>, crownCentre: SIMD3<Float>, crownRadii: SIMD3<Float>,
                     height: Float, ao: Float, bend: Float = 0.75, aspect: Float = 1, baseY: Float = 0,
                     billboard: Bool = true) {
        let n = simd_normalize(normal)
        let ref: SIMD3<Float> = abs(n.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        var right = simd_normalize(simd_cross(ref, n))
        var up = simd_cross(n, right)
        let cr = cos(roll), sr = sin(roll)
        let r2 = right * cr + up * sr
        up = -right * sr + up * cr
        right = r2
        let hx = size / 2 * aspect, hy = size / 2
        let corners: [(Float, Float, Float, Float)] = [(-1, -1, uv.x, uv.w), (1, -1, uv.z, uv.w), (1, 1, uv.z, uv.y), (-1, 1, uv.x, uv.y)]
        let first = UInt32(m.vertexCount)
        for (sx, sy, u, v) in corners {
            let corner = c + right * (sx * hx) + up * (sy * hy)
            let p = billboard ? c : corner
            var out = (corner - crownCentre) / crownRadii
            if simd_length(out) < 1e-3 { out = n }
            let bn = simd_normalize(n * (1 - bend) + simd_normalize(out) * bend)
            m.vertex(p.x, p.y, p.z, bn.x, bn.y, bn.z, u, v)
            m.texcoord2(swayWeight(y: corner.y - baseY, height: height), 0)
            let depth = simd_length((corner - crownCentre) / crownRadii)
            let shade = ao * (0.55 + 0.45 * min(depth, 1)) * (0.8 + 0.2 * min(max((corner.y - crownCentre.y) / crownRadii.y * 0.5 + 0.5, 0), 1))
            m.texcoord3(shade, 0)
            if billboard {
                // Screen-space offset: x right, y up, rolled.
                let ox = sx * hx, oy = sy * hy
                m.texcoord4(ox * cr - oy * sr, ox * sr + oy * cr)
            } else {
                m.texcoord4(0, 0)
            }
        }
        m.tri(first, first + 1, first + 2, part: 1)
        m.tri(first, first + 2, first + 3, part: 1)
    }

    static func randomDir(_ r: inout WorldRandom, minY: Float = -1) -> SIMD3<Float> {
        while true {
            let v = SIMD3(r.range(-1, 1), r.range(-1, 1), r.range(-1, 1))
            let l = simd_length(v)
            if l > 0.05, l <= 1, v.y / l >= minY { return v / l }
        }
    }

    // MARK: - Archetypes

    static func broadleaf(seed: UInt64) -> TreeArchetype {
        var r = WorldRandom(seed: seed * 7919)
        let H: Float = 14, R: Float = 4.5
        let cc = SIMD3<Float>(0, 0.6 * H, 0)
        let radii = SIMD3<Float>(R, 0.38 * H, R)
        var full = MeshBuffer(parts: 2)
        var light = MeshBuffer(parts: 2)
        let lean = SIMD3<Float>(r.range(-0.4, 0.4), 0, r.range(-0.4, 0.4))
        let trunkTop = SIMD3<Float>(0, 0.44 * H, 0) + lean
        tube(&full, SIMD3(0, -0.4, 0), SIMD3(0, 0.2 * H, 0) + lean * 0.4, 0.34, 0.27, sides: 8, height: H)
        tube(&full, SIMD3(0, 0.2 * H, 0) + lean * 0.4, trunkTop, 0.27, 0.19, sides: 8, height: H, vStart: 1.4)
        tube(&light, SIMD3(0, -0.4, 0), trunkTop, 0.34, 0.2, sides: 5, height: H)
        let nMain = 5
        var tips: [SIMD3<Float>] = []
        for k in 0..<nMain {
            let az = Float(k) / Float(nMain) * 2 * .pi + r.range(-0.4, 0.4)
            let el = r.range(0.35, 1.0)
            let d = SIMD3(cos(az) * cos(el), sin(el), sin(az) * cos(el))
            let start = SIMD3<Float>(0, r.range(0.36, 0.46) * H, 0) + lean * 0.8
            let tip = cc + d * radii * r.range(0.65, 0.82)
            let mid = (start + tip) * 0.5 + SIMD3(0, r.range(0.2, 0.8), 0)
            tube(&full, start, mid, 0.14, 0.09, sides: 5, height: H)
            tube(&full, mid, tip, 0.09, 0.035, sides: 4, height: H)
            if k < 3 { tube(&light, start, tip, 0.13, 0.05, sides: 4, height: H) }
            for _ in 0..<2 {
                let sub = mid + (tip - mid) * r.range(0.1, 0.6)
                let sd = simd_normalize(d + randomDir(&r) * 0.8)
                tube(&full, sub, cc + sd * radii * r.range(0.75, 0.95), 0.05, 0.015, sides: 4, height: H)
            }
            tips.append(tip)
        }
        // Clumps on the crown shell, a few around each branch tip.
        for k in 0..<54 {
            let d: SIMD3<Float>
            if k < tips.count * 3 {
                d = simd_normalize((tips[k % tips.count] - cc) / radii + randomDir(&r) * 0.45)
            } else {
                d = randomDir(&r, minY: -0.7)
            }
            let frac = k % 4 == 3 ? r.range(0.3, 0.6) : r.range(0.6, 1.0)
            let centre = cc + d * radii * frac
            for _ in 0..<3 {
                let n = simd_normalize(d + randomDir(&r) * 0.8)
                card(&full, centre: centre + randomDir(&r) * 0.3, size: r.range(1.25, 1.95), normal: n,
                     roll: r.range(0, 6.28), uv: broadUV, crownCentre: cc, crownRadii: radii, height: H, ao: 1)
            }
        }
        for _ in 0..<30 {
            let d = randomDir(&r, minY: -0.6)
            let centre = cc + d * radii * r.range(0.5, 0.9)
            card(&light, centre: centre, size: r.range(2.1, 2.8), normal: simd_normalize(d + randomDir(&r) * 0.4),
                 roll: r.range(0, 6.28), uv: broadUV, crownCentre: cc, crownRadii: radii, height: H, ao: 1)
        }
        return TreeArchetype(kind: .broadleaf, refHeight: H, refRadius: R, full: full, light: light)
    }

    static func poplar(seed: UInt64) -> TreeArchetype {
        var r = WorldRandom(seed: seed * 104_729)
        let H: Float = 22, R: Float = 2.8
        var full = MeshBuffer(parts: 2)
        var light = MeshBuffer(parts: 2)
        tube(&full, SIMD3(0, -0.4, 0), SIMD3(0, 0.5 * H, 0), 0.36, 0.2, sides: 8, height: H)
        tube(&full, SIMD3(0, 0.5 * H, 0), SIMD3(0, 0.93 * H, 0), 0.2, 0.05, sides: 6, height: H, vStart: 5)
        tube(&light, SIMD3(0, -0.4, 0), SIMD3(0, 0.85 * H, 0), 0.36, 0.08, sides: 5, height: H)
        for _ in 0..<12 {
            let y = r.range(0.2, 0.85) * H
            let az = r.range(0, 6.28)
            let reach = R * sin(.pi * min(max((y / H - 0.16) / 0.84, 0), 1)) * r.range(0.6, 0.9)
            let start = SIMD3<Float>(0, y, 0)
            let tip = start + SIMD3(cos(az) * reach, r.range(1.5, 3.5), sin(az) * reach)
            tube(&full, start, tip, 0.07, 0.02, sides: 4, height: H)
        }
        for _ in 0..<72 {
            let t = r.range(0.04, 0.98)
            let y = (0.16 + 0.84 * t) * H
            let profile = sin(.pi * min(max(t * 1.05, 0), 1))
            let az = r.range(0, 6.28)
            let rad = R * profile * r.range(0.55, 1.0)
            let centre = SIMD3<Float>(cos(az) * rad, y, sin(az) * rad)
            let out = simd_normalize(SIMD3(cos(az), r.range(-0.2, 0.5), sin(az)))
            for _ in 0..<2 {
                card(&full, centre: centre, size: r.range(1.0, 1.5), normal: simd_normalize(out + randomDir(&r) * 0.7),
                     roll: r.range(0, 6.28), uv: poplarUV, crownCentre: SIMD3(0, y, 0), crownRadii: SIMD3(R, R * 1.5, R),
                     height: H, ao: 1, aspect: 0.8)
            }
        }
        for k in 0..<12 {
            let t = (Float(k) + 0.5) / 12
            let y = (0.18 + 0.8 * t) * H
            let az = Float(k) * 2.4
            let rad = R * sin(.pi * t) * 0.55
            let out = SIMD3<Float>(cos(az), 0.1, sin(az))
            card(&light, centre: SIMD3(cos(az) * rad, y, sin(az) * rad), size: 3.4, normal: out, roll: r.range(-0.3, 0.3),
                 uv: poplarUV, crownCentre: SIMD3(0, y, 0), crownRadii: SIMD3(R, R, R), height: H, ao: 1, aspect: 0.75)
        }
        return TreeArchetype(kind: .poplar, refHeight: H, refRadius: R, full: full, light: light)
    }

    static func conifer(seed: UInt64) -> TreeArchetype {
        var r = WorldRandom(seed: seed * 1_299_709)
        let H: Float = 16, R: Float = 3.2
        var full = MeshBuffer(parts: 2)
        var light = MeshBuffer(parts: 2)
        tube(&full, SIMD3(0, -0.4, 0), SIMD3(0, H, 0), 0.3, 0.04, sides: 7, height: H)
        tube(&light, SIMD3(0, -0.4, 0), SIMD3(0, H, 0), 0.3, 0.04, sides: 4, height: H)
        let levels = 9
        for l in 0..<levels {
            let t = (Float(l) + 0.5) / Float(levels)
            let y = (0.14 + 0.84 * t) * H
            let rad = R * (1 - t) * 1.05 + 0.3
            let nb = 6
            for k in 0..<nb {
                let az = Float(k) / Float(nb) * 2 * .pi + Float(l) * 0.7 + r.range(-0.2, 0.2)
                let dir = SIMD3<Float>(cos(az), -0.25, sin(az))
                let start = SIMD3<Float>(0, y, 0)
                let tip = start + dir * rad
                if l % 2 == 0 { tube(&full, start, tip, 0.05, 0.015, sides: 3, height: H) }
                let mid = start + dir * rad * 0.6
                let n = simd_normalize(SIMD3(cos(az) * 0.3, 1, sin(az) * 0.3))
                card(&full, centre: mid, size: rad * 1.25 + 0.4, normal: n, roll: az, uv: needleUV,
                     crownCentre: SIMD3(0, y, 0), crownRadii: SIMD3(R, R, R), height: H, ao: 0.6 + 0.4 * t, bend: 0.5,
                     billboard: false)
                if l % 3 == 1 && k % 2 == 0 {
                    card(&light, centre: start + dir * rad * 0.45, size: rad * 1.6 + 0.6, normal: n, roll: az, uv: needleUV,
                         crownCentre: SIMD3(0, y, 0), crownRadii: SIMD3(R, R, R), height: H, ao: 0.6 + 0.4 * t, bend: 0.5,
                         billboard: false)
                }
            }
        }
        return TreeArchetype(kind: .conifer, refHeight: H, refRadius: R, full: full, light: light)
    }

    static func orchard(seed: UInt64) -> TreeArchetype {
        var r = WorldRandom(seed: seed * 15_485_863)
        let H: Float = 6, R: Float = 3.2
        let cc = SIMD3<Float>(0, 0.64 * H, 0)
        let radii = SIMD3<Float>(R, 0.33 * H, R)
        var full = MeshBuffer(parts: 2)
        var light = MeshBuffer(parts: 2)
        let top = SIMD3<Float>(r.range(-0.2, 0.2), 0.34 * H, r.range(-0.2, 0.2))
        tube(&full, SIMD3(0, -0.3, 0), top, 0.17, 0.13, sides: 7, height: H)
        tube(&light, SIMD3(0, -0.3, 0), top, 0.17, 0.12, sides: 4, height: H)
        for k in 0..<4 {
            let az = Float(k) * 1.57 + r.range(-0.4, 0.4)
            let el = r.range(0.25, 0.6)
            let d = SIMD3(cos(az) * cos(el), sin(el), sin(az) * cos(el))
            let elbow = top + d * 1.2 + SIMD3(0, r.range(-0.2, 0.3), 0)
            let tip = cc + simd_normalize(d + SIMD3(0, 0.3, 0)) * radii * 0.8
            tube(&full, top, elbow, 0.1, 0.07, sides: 5, height: H)
            tube(&full, elbow, tip, 0.07, 0.025, sides: 4, height: H)
            if k % 2 == 0 { tube(&light, top, tip, 0.09, 0.03, sides: 4, height: H) }
        }
        for _ in 0..<32 {
            let d = randomDir(&r, minY: -0.6)
            let centre = cc + d * radii * r.range(0.5, 0.98)
            for _ in 0..<3 {
                card(&full, centre: centre + randomDir(&r) * 0.25, size: r.range(1.05, 1.55),
                     normal: simd_normalize(d + randomDir(&r) * 0.8), roll: r.range(0, 6.28), uv: broadUV,
                     crownCentre: cc, crownRadii: radii, height: H, ao: 1)
            }
        }
        for _ in 0..<9 {
            let d = randomDir(&r, minY: -0.4)
            card(&light, centre: cc + d * radii * 0.6, size: 3.0, normal: d, roll: r.range(0, 6.28), uv: broadUV,
                 crownCentre: cc, crownRadii: radii, height: H, ao: 1)
        }
        return TreeArchetype(kind: .orchard, refHeight: H, refRadius: R, full: full, light: light)
    }
}
