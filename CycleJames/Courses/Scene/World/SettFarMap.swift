import Foundation
import Metal

/// The setts as the far road sees them: two texel rows per course, one
/// centred on the joint between two courses and one on the course's middle,
/// 256 texels across 5.6 m, for 4096 courses. Each texel holds the
/// stones' colour, premultiplied by their share of the texel and darkened
/// on each sett's rounded shoulders as the shader darkens them, and the
/// joints' share, across the road and between setts. Mip-mapped and
/// sampled anisotropically, it keeps the far road a road of setts: a darker
/// line at every course while a course is still a pixel or two deep, each
/// sett's lighter crown and dark joints across the road, batches of
/// lighter and darker courses, long after the shader has stopped drawing
/// single setts, and clusters of lighter and darker setts (value noise on a
/// lattice that wraps with the map, filtered with it, so it never aliases).
/// Close up, each sett takes its colour from its own texel, so near and far
/// are the same stones.
///
/// Laid out with `WorldShaders.settSurface`'s own hashes and edges, so keep
/// the two in step. Course k of the map is the course whose layout and
/// colour key is k; the shader keys a course's layout (batch length,
/// stagger, sett edges, joints) and colour on its index from the climb's
/// first sett course modulo 4096 (614-676 m of road, longer than the
/// Koppenberg's or the Paterberg's cobbles), and everything else (each
/// sett's crown, dome, tilt, grain, damage, and the course edges) on the
/// index itself, so no stone ever repeats. The map's course edges are those
/// of the first 4096 courses (later ones differ by a few centimetres).
/// Across the road each course repeats every 5.6 m (a whole number of
/// setts), wider than any cobbled carriageway or side road, so the map
/// wraps without a seam; a raised pavement beyond it shows stones its own
/// course has across the road, where it has none.
enum SettFarMap {
    static let width = 256
    /// Courses in the map: the period of the setts' layout and colours.
    static let courses = 4096
    static let rowsPerCourse = 2
    static let rows = courses * rowsPerCourse
    /// Metres across the texture's width, centred on the road's centre
    /// line: the period of each course's setts across the road.
    static let span: Float = 5.6
    /// Courses baked per task.
    private static let chunk = 128
    /// The stones' colours are stored x this (`settSurface` divides).
    static let colourScale: Float = 3.5
    /// Cluster cells: across the span, and courses along.
    private static let clusterCells = 12, clusterCourses = 4

    /// The course (from s = 0) a few metres before the route's first setts:
    /// the carriageway's course 0 of the map.
    static func firstCourse(_ route: CourseRoute, depth: Float) -> Int {
        guard let ci = route.surfaceNames.firstIndex(of: "cobbles"),
              let i = route.surface.firstIndex(of: ci) else { return 0 }
        return max(Int(((route.s[i] - 5) / Double(depth)).rounded(.down)), 0)
    }

    /// RGBA8 rows, row j centred on j / 2 courses from the map's start
    /// (even rows on the joints between courses): rgb = stone colour
    /// (linear) x `colourScale` x the stones' share of the texel, with their
    /// shoulders darkened; a = the joints' share. `seed` is the look's
    /// (`SettLook.seed`).
    static func pixels(style: CourseArt.SettStyle, seed: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * rows * 4)
        out.withUnsafeMutableBufferPointer { fill($0.baseAddress!, style: style, seed: seed) }
        return out
    }

    /// `pixels` written straight into `out` (width x rows x 4 bytes).
    static func fill(_ out: UnsafeMutablePointer<UInt8>, style: CourseArt.SettStyle, seed: Int) {
        let light = courseLightness(seed: seed)
        DispatchQueue.concurrentPerform(iterations: courses / chunk) { i in
            bake(courses: i * chunk..<(i + 1) * chunk, style: style, seed: seed, light: light, into: out)
        }
    }

    /// One edge between two courses, as `settSurface`'s cjsCourseEdge lays
    /// it, in courses from the map's start: `base` + `tilt` u + `wave`
    /// sin(u `freq` + `phase`).
    private struct CourseEdge {
        var base, tilt, wave, freq, phase: Float

        init(_ k: Int, style: CourseArt.SettStyle, fseed: UInt32) {
            let n = SettFarMap.courses
            let key = Float(((k % n) + n) % n)
            let r = SettFarMap.unit(SettFarMap.key(key, 0x2545F491 ^ fseed))
            let d0 = style.layout.x
            base = Float(k) + style.layout.z * (r.x - 0.5)
            tilt = (0.0045 * sin(key * 0.173 + 0.6) + 0.004 * (r.w - 0.5)) / d0
            wave = 0.006 * (r.z - 0.5) / d0
            freq = 1.7 + 4 * r.w
            phase = 6.2832 * r.y
        }

        func at(_ u: Float) -> Float { base + tilt * u + wave * sin(u * freq + phase) }
    }

    /// The rows of courses `range` (and the edges of their neighbours that
    /// reach into them), box-filtered over each texel.
    private static func bake(courses range: Range<Int>, style: CourseArt.SettStyle, seed: Int, light: [Float],
                             into out: UnsafeMutablePointer<UInt8>) {
        let w = width
        let rowLo = range.lowerBound * rowsPerCourse, nRows = range.count * rowsPerCourse
        // r, g, b (shaded stone), stone cover.
        var acc = [Float](repeating: 0, count: nRows * w * 4)
        let fseed = UInt32(seed * 4) &* 0x01000193
        let d0 = style.layout.x, l0 = style.layout.y, sJit = style.layout.w
        let jx = style.joint.x, jy = style.joint.y, jt = style.split.x
        // A side's joint half width, drawn from r as the shader draws it.
        func jw(_ r: Float) -> Float { jx + (jy - jx) * r * r + jt * (r * r) * (r * r) }
        // The shoulder's mean radius (settSurface: R = 0.012 + 0.6 shape.w r).
        let rim = 0.012 + 0.3 * style.shape.w
        let rimS = rim / d0
        let pB = style.stoneB.w, pC = style.stoneC.w, spread = style.stoneA.w
        let fams = [style.stoneA, style.stoneB, style.stoneC]
        let dx = span / Float(w), half = span / 2
        var rowShade = [Float](repeating: 0, count: 4), rowCover = rowShade
        acc.withUnsafeMutableBufferPointer { a in
            for c in (range.lowerBound - 1)...range.upperBound {
                let lay = ((c % courses) + courses) % courses
                let hk = key(Float(lay), 0x68E31DA4 ^ fseed)
                let rk = unit(hk)
                // A whole number of setts across the span.
                let nk = max((span / (l0 * (0.88 + 0.24 * rk.x))).rounded(), 1)
                let lk = span / nk, n = Int(nk)
                let ok = rk.y * lk
                let below = CourseEdge(c, style: style, fseed: fseed)
                let above = CourseEdge(c + 1, style: style, fseed: fseed)
                let tint = light[lay]
                // One period of setts, from the one over the left edge.
                let mLo = Int(((-half - ok) / lk).rounded(.down))
                var eL = settEdge(mLo, n: n, hk: hk, lk: lk, ok: ok, jitter: sJit)
                for m in mLo..<(mLo + n) {
                    let eR = settEdge(m + 1, n: n, hk: hk, lk: lk, ok: ok, jitter: sJit)
                    defer { eL = eR }
                    // This sett's colour (h1: family, lightness, hue) and
                    // joints (h2: left, right, below, above), as the shader
                    // hashes them.
                    let mm = ((m % n) + n) % n
                    let h1 = hash(hk ^ (UInt32(mm) &* 0x165667B1) ^ 0x9E3779B9)
                    let r1 = unit(h1), r3 = unit(lcg(h1))
                    let su0 = eL + jw(r3.x)
                    let su1 = eR - jw(r3.y)
                    guard su1 > su0 else { continue }
                    let uc = 0.5 * (eL + eR)
                    let ss0 = below.at(uc) + jw(r3.z) / d0
                    let ss1 = above.at(uc) - jw(r3.w) / d0
                    guard ss1 > ss0 else { continue }
                    let fam = r1.x < pC ? fams[2] : (r1.x < pC + pB ? fams[1] : fams[0])
                    let clu = cluster(uc, Float(lay) + 0.5, fseed: fseed)
                    let k = (1 + spread * (2 * r1.y - 1)) * tint * (1 + 0.28 * (clu - 0.5))
                    let hue = 0.03 * (2 * r1.z - 1)
                    let cr = fam.x * k * (1 + hue), cg = fam.y * k, cb = fam.z * k * (1 - hue)
                    // Rows it covers (row j spans j / 2 -+ 1 / 4 courses).
                    let j0 = max(Int((2 * (ss0 + 0.25)).rounded(.down)), rowLo)
                    let j1 = min(Int((2 * (ss1 + 0.25)).rounded(.down)), rowLo + nRows - 1)
                    guard j0 <= j1 else { continue }
                    // Columns, wrapping across the span's edges.
                    let x0 = Int(((su0 + half) / dx).rounded(.down))
                    let x1 = Int(((su1 + half) / dx).rounded(.down))
                    guard x1 - x0 < w, j1 - j0 < 4 else { continue }
                    // Shaded and plain shares of each row's height.
                    for j in j0...j1 {
                        let t0 = max(ss0, Float(j) * 0.5 - 0.25), t1 = min(ss1, Float(j) * 0.5 + 0.25)
                        rowShade[j - j0] = t1 > t0 ? shaded(t0, t1, ss0, ss1, rimS) * 2 : 0
                        rowCover[j - j0] = max(t1 - t0, 0) * 2
                    }
                    for x in x0...x1 {
                        let ux = Float(x) * dx - half
                        let u0 = max(su0, ux), u1 = min(su1, ux + dx)
                        guard u1 > u0 else { continue }
                        let f = shaded(u0, u1, su0, su1, rim) / dx
                        let cv = (u1 - u0) / dx
                        let xw = ((x % w) + w) % w
                        for j in j0...j1 {
                            let fs = f * rowShade[j - j0]
                            let o = ((j - rowLo) * w + xw) * 4
                            a[o] += cr * fs
                            a[o + 1] += cg * fs
                            a[o + 2] += cb * fs
                            a[o + 3] += cv * rowCover[j - j0]
                        }
                    }
                }
            }
        }
        for j in 0..<nRows {
            for x in 0..<w {
                let i = (j * w + x) * 4
                let o = ((rowLo + j) * w + x) * 4
                out[o] = byte(acc[i] * colourScale)
                out[o + 1] = byte(acc[i + 1] * colourScale)
                out[o + 2] = byte(acc[i + 2] * colourScale)
                out[o + 3] = byte(1 - acc[i + 3])
            }
        }
    }

    /// Sett edge `m` of a course of `n` setts across the span, along its
    /// middle line (settSurface's cjsSettEdge at d = 0).
    private static func settEdge(_ m: Int, n: Int, hk: UInt32, lk: Float, ok: Float, jitter: Float) -> Float {
        let e = unit(hash(hk ^ (UInt32(((m % n) + n) % n) &* 0x27D4EB2F)))
        return ok + Float(m) * lk + lk * jitter * (e.x - 0.5)
    }

    /// Clusters of lighter and darker setts: value noise (0..1) at lateral
    /// `u` and `t` courses into the map, on a lattice of `clusterCells`
    /// across the span by `clusterCourses` courses, wrapping with the map.
    private static func cluster(_ u: Float, _ t: Float, fseed: UInt32) -> Float {
        let nu = clusterCells, nt = courses / clusterCourses
        let gu = (u / span + 0.5) * Float(nu), gt = t / Float(clusterCourses)
        let iu = Int(gu.rounded(.down)), it = Int(gt.rounded(.down))
        var fu = gu - Float(iu), ft = gt - Float(it)
        fu = fu * fu * (3 - 2 * fu)
        ft = ft * ft * (3 - 2 * ft)
        func v(_ a: Int, _ b: Int) -> Float {
            let x = UInt32(((a % nu) + nu) % nu) &* 0x8DA6B343, y = UInt32(((b % nt) + nt) % nt) &* 0xD8163841
            return Float(hash(x ^ y ^ 0x3C6EF372 ^ fseed) >> 8) / 16_777_216
        }
        let a = v(iu, it) + (v(iu + 1, it) - v(iu, it)) * fu
        let b = v(iu, it + 1) + (v(iu + 1, it + 1) - v(iu, it + 1)) * fu
        return a + (b - a) * ft
    }

    /// The integral over [x0, x1] of a sett's shading across [a, b]: 0.82
    /// on its edge rising to 1 over its shoulder of radius `r` (the shader's
    /// 0.82 + 0.18 (1 - (1 - e)^2)).
    private static func shaded(_ x0: Float, _ x1: Float, _ a: Float, _ b: Float, _ r: Float) -> Float {
        // The primitive of the shading from an edge, d in from it.
        func prim(_ d: Float) -> Float {
            let p = d < r ? d * d / r - d * d * d / (3 * r * r) : d - r / 3
            return 0.82 * d + 0.18 * p
        }
        let mid = 0.5 * (a + b)
        var s: Float = 0
        if x0 < mid { s += prim(min(x1, mid) - a) - prim(x0 - a) }
        if x1 > mid { s += prim(b - max(x0, mid)) - prim(b - x1) }
        return s
    }

    /// Each course's lightness (1 = mean): course to course a little, in
    /// runs of 3 to 40 courses from one batch a little more, and the odd
    /// worn or relaid row.
    static func courseLightness(seed: Int) -> [Float] {
        var g = SplitMix(state: 0x5EED_5E77 &+ UInt64(seed) &* 0x9E37_79B9_7F4A_7C15)
        var lum = [Float](repeating: 0, count: courses)
        var i = 0
        while i < courses {
            let run = 3 + Int(g.unit() * 38)
            let shift = 0.10 * (g.unit() - 0.5)
            for k in i..<min(i + run, courses) { lum[k] = shift }
            i += run
        }
        for k in 0..<courses {
            lum[k] += 0.14 * (g.unit() - 0.5)
            if g.unit() < 0.04 { lum[k] += g.unit() < 0.5 ? -0.09 : 0.09 }
        }
        // Neighbours in a batch correlate a little (the ring wraps).
        return (0..<courses).map { k in
            let v = 0.15 * lum[(k + courses - 1) % courses] + 0.7 * lum[k] + 0.15 * lum[(k + 1) % courses]
            return 1 + 0.9 * v
        }
    }

    // The shader's hashes (settSurface's #pragma declaration), bit for bit.
    @inline(__always) static func hash(_ v: UInt32) -> UInt32 {
        var x = v
        x ^= x >> 16
        x &*= 0x7feb352d
        x ^= x >> 15
        x &*= 0x846ca68b
        x ^= x >> 16
        return x
    }

    @inline(__always) static func unit(_ h: UInt32) -> SIMD4<Float> {
        SIMD4(Float(h & 0xff), Float((h >> 8) & 0xff), Float((h >> 16) & 0xff), Float(h >> 24)) * (1 / 255.0)
    }

    @inline(__always) static func key(_ a: Float, _ salt: UInt32) -> UInt32 {
        hash(UInt32(bitPattern: Int32(a)) &* 0x9E3779B1 &+ salt)
    }

    @inline(__always) static func lcg(_ h: UInt32) -> UInt32 {
        var x = h &* 747796405 &+ 2891336453
        x ^= x >> 13
        return x
    }

    private static func byte(_ v: Float) -> UInt8 {
        UInt8(max(0, min(255, (v * 255).rounded())))
    }

    private struct SplitMix {
        var state: UInt64
        mutating func unit() -> Float {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Float((z ^ (z >> 31)) >> 40) / Float(1 << 24)
        }
    }
}

extension WorldTextures {
    /// `SettFarMap` for a look, made and uploaded with a full mip chain once
    /// per world (8 MB, 10.7 MB with its mips). Nil (and `uploadFailed`
    /// set) when the GPU work doesn't complete.
    func settFarMap(_ style: CourseArt.SettStyle, seed: Int) -> MTLTexture? {
        gpuTexture("settFar|\(seed)") {
            let w = SettFarMap.width, h = SettFarMap.rows
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
                  let staging = device.makeBuffer(length: w * h * 4, options: .storageModeShared) else { return nil }
            SettFarMap.fill(staging.contents().assumingMemoryBound(to: UInt8.self), style: style, seed: seed)
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: true)
            desc.usage = .shaderRead
            desc.storageMode = .private
            guard let tex = device.makeTexture(descriptor: desc),
                  let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else { return nil }
            blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: w * 4, sourceBytesPerImage: w * h * 4,
                      sourceSize: MTLSize(width: w, height: h, depth: 1), to: tex, destinationSlice: 0,
                      destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            guard cmd.status == .completed else {
                noteUploadFailed()
                return nil
            }
            return tex
        }
    }
}
