import XCTest
import UIKit
import simd
import SceneKit
import Metal
@testable import CycleJames

/// The procedural trees (`TreeArchetype`) and the plant meshes the
/// vegetation builder merges them into. SceneKit draws a plant's leaves with
/// the plain diffuse, silently, when its mesh lacks a texture channel the
/// shader reads, so every mesh must carry channels 1-3 for every vertex.
final class TreeArchetypeTests: XCTestCase {
    private let all = TreeArchetype.makeAll()

    private func assertChannels(_ m: MeshBuffer, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let n = m.vertexCount
        XCTAssertGreaterThan(n, 0, "\(what) is empty", file: file, line: line)
        XCTAssertEqual(m.normals.count, n * 3, "\(what) normals", file: file, line: line)
        XCTAssertEqual(m.uvs.count, n * 2, "\(what) uv", file: file, line: line)
        XCTAssertEqual(m.uv2.count, n * 2, "\(what) uv2 (sway, phase)", file: file, line: line)
        XCTAssertEqual(m.uv3.count, n * 2, "\(what) uv3 (shade, colour)", file: file, line: line)
        XCTAssertEqual(m.uv4.count, n * 2, "\(what) uv4 (billboard corner)", file: file, line: line)
        for part in m.parts { XCTAssertTrue(part.allSatisfy { Int($0) < n }, "\(what) index out of range", file: file, line: line) }
        XCTAssertTrue(m.positions.allSatisfy(\.isFinite), "\(what) has a non-finite position", file: file, line: line)
    }

    func test_everyArchetypeEmitsConsistentChannels() {
        XCTAssertEqual(all.count, TreeArchetype.Form.allCases.reduce(0) { $0 + $1.variants * 2 })
        for a in all {
            assertChannels(a.full, "\(a.form) full")
            assertChannels(a.light, "\(a.form) light")
            XCTAssertFalse(a.full.parts[1].isEmpty, "\(a.form) has no leaves")
            XCTAssertFalse(a.light.parts[1].isEmpty, "\(a.form) light has no leaves")
        }
    }

    func test_archetypesAreDeterministicPerSeed() {
        for f in TreeArchetype.Form.allCases {
            for lane in [false, true] {
                let a = TreeArchetype.make(f, variant: 1, towardsLane: lane)
                let b = TreeArchetype.make(f, variant: 1, towardsLane: lane)
                XCTAssertEqual(a.full.positions, b.full.positions, "\(f)")
                XCTAssertEqual(a.full.uv3, b.full.uv3, "\(f)")
                XCTAssertEqual(a.light.positions, b.light.positions, "\(f)")
            }
            let c = TreeArchetype.make(f, variant: 0), d = TreeArchetype.make(f, variant: 1)
            XCTAssertNotEqual(c.full.positions, d.full.positions, "\(f): variants should differ")
        }
    }

    /// Leaf cards' centres (billboards keep every corner at the centre).
    private func cardCentres(_ m: MeshBuffer) -> [SIMD3<Float>] {
        Set(m.parts[1]).map { i in SIMD3(m.positions[3 * Int(i)], m.positions[3 * Int(i) + 1], m.positions[3 * Int(i) + 2]) }
    }

    /// The Kwaremont poplar was bare sticks rising past its leaves: every
    /// limb, branch and whip must end among leaf cards.
    func test_noBareLimbTips() {
        for a in all where a.form != .conifer {
            XCTAssertFalse(a.limbTips.isEmpty, "\(a.form) records no limb tips")
            let cards = cardCentres(a.full)
            for tip in a.limbTips {
                let near = cards.map { simd_distance($0, tip) }.min() ?? .infinity
                if a.lobes.isEmpty {
                    XCTAssertLessThan(near, 0.9, "\(a.form) branch tip \(tip) sticks out of the leaves")
                } else {
                    // Lobed crowns end each limb 0.35 r from its lobe's
                    // centre, inside the shell of cards.
                    XCTAssertTrue(a.lobes.contains { simd_distance($0.c, tip) <= 0.5 * $0.r }, "\(a.form) limb tip \(tip) outside its lobe")
                    XCTAssertLessThan(near, a.lobes.map(\.r).max() ?? 1, "\(a.form) limb tip \(tip) far from any leaves")
                }
            }
        }
    }

    /// A Lombardy poplar is a dense column: no band over 1.2 m high without
    /// a leaf card, from the lowest leaves to near the top.
    func test_lombardyColumnHasNoGaps() {
        for a in all where a.form == .lombardy {
            let ys = cardCentres(a.full).map(\.y).sorted()
            let inColumn = ys.filter { $0 >= a.crownBase && $0 <= 0.9 * a.refHeight }
            XCTAssertGreaterThan(inColumn.count, 150)
            let gap = zip(inColumn, inColumn.dropFirst()).map { $1 - $0 }.max() ?? 0
            XCTAssertLessThan(gap, 1.2)
            XCTAssertLessThan(ys.first ?? 99, a.crownBase + 1.2, "leaves should start near the crown base")
        }
    }

    /// A lane-side crown grows towards +x (it is turned to face the road
    /// when placed).
    func test_laneSideCrownGrowsTowardsTheLane() {
        for f in TreeArchetype.Form.allCases where f.spec != nil {
            let plain = TreeArchetype.make(f, variant: 0), lane = TreeArchetype.make(f, variant: 0, towardsLane: true)
            let meanX = { (a: TreeArchetype) -> Float in
                let c = self.cardCentres(a.full)
                return c.reduce(0) { $0 + $1.x } / Float(max(c.count, 1))
            }
            XCTAssertGreaterThan(meanX(lane), meanX(plain) + 0.1 * plain.refRadius, "\(f)")
        }
    }

    /// Mean leaf shading (texture channel 2's x) of a mesh's leaf vertices.
    private func meanLeafShade(_ m: MeshBuffer) -> Float {
        let v = Set(m.parts[1]).map { m.uv3[2 * Int($0)] }
        return v.reduce(0, +) / Float(max(v.count, 1))
    }

    /// The light version is shaded like the full one, so a crown doesn't
    /// darken (or brighten) as it crosses `treeDetailCameraDistance`, and the
    /// middle distance's woods are no darker than the near trees.
    func test_lightVersionShadesLikeTheFullOne() {
        for f in TreeArchetype.Form.allCases {
            let arch = all.filter { $0.form == f }
            let full = arch.map { meanLeafShade($0.full) }.reduce(0, +) / Float(arch.count)
            let light = arch.map { meanLeafShade($0.light) }.reduce(0, +) / Float(arch.count)
            XCTAssertEqual(light, full, accuracy: 0.1, "\(f): light \(light), full \(full)")
        }
    }

    /// A lane-side crown reaches out over the lane from about where the
    /// leaves begin (its cards hang a little below the crown base, as the
    /// plain crown's do): none hangs down to the rider.
    func test_laneSideCrownKeepsItsLeavesUp() {
        for a in all where a.form.spec != nil {
            let low = a.lowestLeaf(laneSide: true, sy: 1, cardScale: 1)
            XCTAssertGreaterThan(low, a.crownBase - 0.05 * a.refHeight,
                                 "\(a.form): lane-side leaves down to \(low) m, crown base \(a.crownBase) m")
        }
    }

    /// Leaf cards' extent across the view (billboard corners at their
    /// centre plus their offset) in a band of heights.
    private func width(_ m: MeshBuffer, from y0: Float, to y1: Float) -> Float {
        var lo = Float.infinity, hi = -Float.infinity
        for i in Set(m.parts[1]).map(Int.init) {
            let y = m.positions[3 * i + 1] + m.uv4[2 * i + 1]
            guard y >= y0, y < y1 else { continue }
            let x = m.positions[3 * i] + m.uv4[2 * i]
            lo = min(lo, x); hi = max(hi, x)
        }
        return hi - lo
    }

    /// The Lombardy's light version keeps the column's width and taper, so
    /// it doesn't slim to a rod at the switch.
    func test_lombardyLightVersionKeepsTheColumnsWidth() {
        for a in all where a.form == .lombardy {
            for y in stride(from: Float(2), to: 18, by: 4) {
                let full = width(a.full, from: y, to: y + 4), light = width(a.light, from: y, to: y + 4)
                XCTAssertGreaterThan(light, 0.85 * full, "y \(y)-\(y + 4): light \(light) m, full \(full) m")
            }
        }
    }

    /// Hulls stay inside their card, anticlockwise and convex, so the card's
    /// triangle fan covers it once.
    func test_hullsAreConvexInsideTheirCard() {
        for hull in [TreeArchetype.broadHull, TreeArchetype.poplarHull, TreeArchetype.ivyHull] {
            for (k, p) in hull.enumerated() {
                XCTAssertTrue(abs(p.x) <= 1 && abs(p.y) <= 1, "\(p) outside the card")
                let a = hull[(k + 1) % hull.count] - p, b = hull[(k + 2) % hull.count] - hull[(k + 1) % hull.count]
                XCTAssertGreaterThan(a.x * b.y - a.y * b.x, 0, "hull turns clockwise at \(k + 1)")
            }
        }
    }

    /// An atlas's alpha (cj_foliage.png unless named), rows top first, or a
    /// skip when the atlas isn't in the test host bundle.
    private func foliageAlpha(_ name: String = "cj_foliage") throws -> (alpha: [UInt8], width: Int, height: Int) {
        guard let cg = WorldTextures(limit: 4096).image(name)?.cgImage else {
            throw XCTSkip("\(name).png not in the test host bundle")
        }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = px.withUnsafeMutableBytes { buf -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        XCTAssertTrue(drawn)
        return (stride(from: 3, to: px.count, by: 4).map { px[$0] }, w, h)
    }

    /// Each hull (fitted by scripts/courses/textures/fit_hulls.py) holds
    /// every texel of its quadrant with alpha over 0.3 in the bundled atlas,
    /// so no trimmed card clips a leaf; and each hedge-core texel sits in a
    /// 7 x 7 patch of opaque leaf, so a hedge's core is never cut.
    func test_hullsEncloseTheirLeaves() throws {
        let (alpha, w, h) = try foliageAlpha()
        let quads = [("broad", TreeArchetype.broadUV), ("poplar", TreeArchetype.poplarUV), ("ivy", TreeArchetype.ivyUV)]
        for (name, uv) in quads {
            let hull = try XCTUnwrap(TreeArchetype.hull(for: uv), name)
            var leaves = 0, outside = 0
            for y in 0..<h {
                let v = (Float(y) + 0.5) / Float(h)
                guard v >= uv.y, v <= uv.w else { continue }
                for x in 0..<w where alpha[y * w + x] > 76 {
                    let u = (Float(x) + 0.5) / Float(w)
                    guard u >= uv.x, u <= uv.z else { continue }
                    // Card units, as `TreeArchetype.card` maps them.
                    let p = SIMD2((u - uv.x) / (uv.z - uv.x) * 2 - 1, (uv.w - v) / (uv.w - uv.y) * 2 - 1)
                    leaves += 1
                    let inside = hull.indices.allSatisfy { k in
                        let a = hull[k], b = hull[(k + 1) % hull.count]
                        return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) >= -1e-5
                    }
                    if !inside { outside += 1 }
                }
            }
            XCTAssertGreaterThan(leaves, w * h / 40, "\(name): too few leaves, wrong quadrant?")
            XCTAssertEqual(outside, 0, "\(name): \(outside) of \(leaves) leaf texels outside the hull; run fit_hulls.py")
            let core = TreeArchetype.core(for: uv)
            XCTAssertTrue((uv.x...uv.z).contains(core.x) && (uv.y...uv.w).contains(core.y), "\(name) core outside its quadrant")
            let cx = Int(core.x * Float(w)), cy = Int(core.y * Float(h))
            for dy in -3...3 {
                for dx in -3...3 {
                    XCTAssertGreaterThanOrEqual(alpha[(cy + dy) * w + cx + dx], 253, "\(name) core texel not in opaque leaf")
                }
            }
        }
    }

    /// A straight hedge along +x, its road face at z = 0 facing -z, cut as
    /// `VegetationBuilder.hedgeSection` cuts one, `length` long.
    private func straightHedge(length: Float, height: Float) -> [VegetationBuilder.HedgeSection] {
        let pts: [SIMD2<Float>] = [SIMD2(0, -0.12), SIMD2(0.05, height - 0.06), SIMD2(0.11, height),
                                   SIMD2(0.79, height), SIMD2(0.85, height - 0.06), SIMD2(0.9, -0.12)]
        let sideN = (0..<5).map { j in
            simd_normalize(SIMD3<Float>(0, pts[j + 1].x - pts[j].x, pts[j].y - pts[j + 1].y))
        }
        let normals = (0..<6).map { j in simd_normalize(sideN[max(j - 1, 0)] + sideN[min(j, 4)]) }
        return stride(from: Float(0), through: length, by: 0.6).map { x in
            VegetationBuilder.HedgeSection(ring: pts.map { SIMD3(x, $0.y, $0.x) }, normals: normals,
                                           along: SIMD3(1, 0, 0), foot: -0.12, top: height, sky: 0.8)
        }
    }

    /// A clipped hedge is a closed core, every edge shared by two of its
    /// triangles but along the buried foot, clad in cards that keep close
    /// to it: none stands more than 15 cm over the top or 25 cm off a face
    /// or past an end. And it stays cheap.
    func test_hedgeIsAClosedWallWithCardsOnIt() {
        for kind in [CourseArt.HedgeKind.green, .copperBeech, .laurel, .ivy] {
            let look = VegetationBuilder.hedgeLook(kind)
            let length: Float = 24, height: Float = 2.6
            var m = MeshBuffer(parts: 2)
            var rnd = WorldRandom(seed: 5)
            VegetationBuilder.hedgeStretch(straightHedge(length: length, height: height), look: look, rnd: &rnd, into: &m)
            assertChannels(m, "\(kind) hedge")
            XCTAssertTrue(m.parts[0].isEmpty, "hedges have no bark")
            let core = TreeArchetype.core(for: look.uv)
            func isCore(_ i: Int) -> Bool { m.uvs[2 * i] == core.x && m.uvs[2 * i + 1] == core.y }
            func key(_ i: Int) -> SIMD3<Int> {
                SIMD3(Int((m.positions[3 * i] * 1e4).rounded()), Int((m.positions[3 * i + 1] * 1e4).rounded()),
                      Int((m.positions[3 * i + 2] * 1e4).rounded()))
            }
            var edges: [[SIMD3<Int>]: Int] = [:]
            var coreTris = 0
            let tris = m.parts[1]
            for t in stride(from: 0, to: tris.count, by: 3) {
                let v = (0..<3).map { Int(tris[t + $0]) }
                guard v.allSatisfy(isCore) else {
                    XCTAssertFalse(v.contains(where: isCore), "a triangle mixes core and card")
                    continue
                }
                coreTris += 1
                for e in 0..<3 {
                    let a = key(v[e]), b = key(v[(e + 1) % 3])
                    let lo = a.x != b.x ? (a.x < b.x ? a : b) : a.y != b.y ? (a.y < b.y ? a : b) : (a.z < b.z ? a : b)
                    edges[[lo, lo == a ? b : a], default: 0] += 1
                }
            }
            XCTAssertGreaterThan(coreTris, 0)
            let foot = Int((Float(-0.12) * 1e4).rounded())
            XCTAssertTrue(edges.allSatisfy { $0.value == 2 || ($0.value == 1 && $0.key.allSatisfy { $0.y == foot }) },
                          "\(kind): the core is open")
            for i in 0..<m.vertexCount where !isCore(i) {
                let p = SIMD3(m.positions[3 * i], m.positions[3 * i + 1], m.positions[3 * i + 2])
                XCTAssertLessThan(p.y, height + 0.15, "\(kind): a card stands over the top at \(p)")
                XCTAssertTrue((-0.25...1.15).contains(p.z), "\(kind): a card stands off a face at \(p)")
                XCTAssertTrue((-0.25...(length + 0.25)).contains(p.x), "\(kind): a card sticks out past an end at \(p)")
            }
            // About three times the cards-only hedge's 46 a metre (its ends
            // about 170 each).
            XCTAssertLessThan(Float(m.triangleCount) / length, 155, "\(kind): \(m.triangleCount) triangles")
            XCTAssertTrue(m.uv3.enumerated().allSatisfy { $0.offset % 2 == 1 || (0...1).contains($0.element) }, "ao out of 0...1")
        }
    }

    /// Sky shading: the plant's foot takes the sky there, its top the full
    /// sky, rising in between.
    func test_skyShadeOpensTowardsThePlantsTop() {
        var m = MeshBuffer(parts: 1)
        for y: Float in [0, 3, 6, 9, 12] {
            m.vertex(0, 10 + y, 0, 0, 1, 0, 0, 0)
            m.texcoord2(0, 0)
            m.texcoord3(0.8, 0)
            m.texcoord4(0, 0)
        }
        VegetationBuilder.skyShade(&m, from: 0, sky: 0.6, baseY: 10, height: 12)
        let shade = (0..<m.vertexCount).map { m.uv3[2 * $0] }
        XCTAssertEqual(shade[0], 0.8 * 0.6, accuracy: 1e-5)
        XCTAssertEqual(shade[4], 0.8, accuracy: 1e-5)
        XCTAssertTrue(zip(shade[0..<4], shade[1..<5]).allSatisfy { $0 < $1 }, "\(shade)")
    }

    /// The CPU sky raster reads as the ground shader does: filtered at
    /// texel centres, row 0 north, floored, open sky off the raster.
    func test_skyRasterReadsLikeTheGroundShader() {
        // 100 x 100 px of 1 m, north-west corner at (1000, 2000); one dark
        // texel at column 50, row 20, the rest half sky.
        var px = [UInt8](repeating: 128, count: 100 * 100)
        px[20 * 100 + 50] = 0
        let sky = SkyRaster(sky: px, width: 100, height: 100, originEast: 1000, originNorth: 2000, metresPerPixel: 1, minSky: 0.3)
        XCTAssertEqual(sky.visibility(east: 1030.5, north: 1940.5), 128.0 / 255, accuracy: 1e-4)
        XCTAssertEqual(sky.visibility(east: 1050.5, north: 1979.5), 0.3, accuracy: 1e-4, "floored at minSky")
        XCTAssertEqual(sky.visibility(east: 1051.0, north: 1979.5), 0.3, accuracy: 1e-4, "half way to a half-sky texel, floored")
        XCTAssertEqual(sky.visibility(east: 1051.5, north: 1979.5), 128.0 / 255, accuracy: 1e-4)
        XCTAssertEqual(sky.visibility(east: 900, north: 1950), 1, "off the raster")
        XCTAssertGreaterThan(sky.visibility(east: 1000.5, north: 1950), 0.9, "fades to open sky at its edge")
    }

    /// A plant's sky leaves out its own crown, which the raster counts
    /// over its foot: a tree in a field keeps the field's sky, one in a
    /// lane or a wood the shade all round it, one at a wood's edge its open
    /// side; with no canopy at the foot, the foot's sky.
    func test_plantSkyLeavesOutItsOwnCrown() {
        let n = 100
        func raster(_ f: (Int, Int) -> (sky: UInt8, canopy: UInt8)) -> SkyRaster {
            var sky = [UInt8](repeating: 0, count: n * n), canopy = sky
            for y in 0..<n {
                for x in 0..<n {
                    (sky[y * n + x], canopy[y * n + x]) = f(x, y)
                }
            }
            return SkyRaster(sky: sky, canopy: canopy, width: n, height: n, originEast: 0, originNorth: Double(n),
                             metresPerPixel: 1, minSky: 0.2)
        }
        // A crown of 4 m radius, centred on the texel at (50, 50), over a
        // field of sky 0.95.
        let crown = { (x: Int, y: Int) in hypot(Double(x - 50), Double(y - 50)) <= 4 }
        let field = raster { x, y in crown(x, y) ? (77, 64) : (242, 0) }
        let foot = (east: 50.5, north: 49.5)
        XCTAssertEqual(field.visibility(east: foot.east, north: foot.north), 77.0 / 255, accuracy: 1e-4)
        XCTAssertTrue(field.hasCanopy(east: foot.east, north: foot.north))
        XCTAssertGreaterThan(field.plantSky(east: foot.east, north: foot.north, radius: 4), 0.9, "a field tree keeps its light")
        XCTAssertEqual(field.plantSky(east: foot.east, north: foot.north, radius: 0), 77.0 / 255, accuracy: 1e-4,
                       "radius 0 is the foot")
        XCTAssertGreaterThan(field.plantSky(east: 20.5, north: 79.5, radius: 4), 0.94, "in the open, the foot")
        // The same crown in a wood (sky 0.35 under canopy all round).
        let wood = raster { x, y in crown(x, y) ? (77, 64) : (89, 64) }
        XCTAssertLessThan(wood.plantSky(east: foot.east, north: foot.north, radius: 4), 0.36, "a wood stays shaded")
        // At a wood's edge (east of x = 52 open).
        let edge = raster { x, y in crown(x, y) ? (77, 64) : x >= 52 ? (242, 0) : (89, 64) }
        XCTAssertGreaterThan(edge.plantSky(east: foot.east, north: foot.north, radius: 4), 0.9, "its open side counts")
        // No canopy channel: the foot.
        var bare = [UInt8](repeating: 242, count: n * n)
        for y in 0..<n { for x in 0..<n where crown(x, y) { bare[y * n + x] = 77 } }
        let noCanopy = SkyRaster(sky: bare, width: n, height: n, originEast: 0, originNorth: Double(n), metresPerPixel: 1,
                                 minSky: 0.2)
        XCTAssertEqual(noCanopy.plantSky(east: foot.east, north: foot.north, radius: 4), 77.0 / 255, accuracy: 1e-4)
    }

    /// An impostor's shading, linear up its quad, gives the crown (from
    /// 35 % of the height up) the same mean as `skyShade`'s on the full and
    /// light versions, so a tree doesn't step in brightness at the switch.
    func test_impostorOpensLikeTheCrown() {
        for sky: Float in [0.6, 0.8, 1] {
            var m = MeshBuffer(parts: 2)
            VegetationBuilder.impostor(&m, cell: 0, width: 6, height: 12, x: 0, y: 0, z: 0, yaw: 0, phase: 0, tint: 0, sky: sky)
            let bottom = m.uv3[0] / 0.92, top = m.uv3[2 * 2] / 0.92
            XCTAssertEqual(bottom, sky, accuracy: 1e-5)
            var lin: Float = 0, quad: Float = 0
            let steps = 200
            for i in 0..<steps {
                let t = 0.35 + 0.65 * (Float(i) + 0.5) / Float(steps)
                lin += bottom + (top - bottom) * t
                quad += sky + (1 - sky) * t * t
            }
            XCTAssertEqual(lin / Float(steps), quad / Float(steps), accuracy: 0.005, "sky \(sky)")
        }
    }

    func test_packedColourDecodesAsTheShaderDoes() {
        for c in [SIMD3<Float>(1, 1, 1), SIMD3(0.84, 0.88, 0.74), SIMD3(1.95, 0.27, 1.95), SIMD3(3, 0, 0.5)] {
            let packed = TreeArchetype.packColour(c)
            XCTAssertGreaterThanOrEqual(packed, 65536, "must read as packed, not as legacy yellowing")
            let u = UInt32(packed)
            let back = SIMD3(Float((u >> 16) & 255), Float((u >> 8) & 255), Float(u & 255)) / 128
            let want = simd_clamp(c, SIMD3(repeating: 1.0 / 128), SIMD3(repeating: 255.0 / 128))
            XCTAssertLessThan(simd_reduce_max(simd_abs(back - want)), 0.5 / 128 + 1e-6, "\(c)")
            XCTAssertEqual(Float(Int(packed)), packed, "packed colour must be an exact integer")
        }
    }

    /// Trimmed cards: a hexagon of four triangles, its texture coordinates
    /// inside the card's cell, mirrored or not.
    func test_trimmedCardStaysInItsCell() {
        for mirror in [false, true] {
            var m = MeshBuffer(parts: 2)
            let uv = TreeArchetype.broadUV
            TreeArchetype.card(&m, centre: .zero, size: 2, normal: SIMD3(0, 0, 1), roll: 0.4, uv: uv, crownCentre: SIMD3(0, 0, -1),
                               crownRadii: SIMD3(1, 1, 1), height: 10, ao: 1, mirror: mirror, hull: TreeArchetype.broadHull)
            assertChannels(m, "hexagon card")
            XCTAssertEqual(m.parts[1].count, 12)
            for i in 0..<m.vertexCount {
                XCTAssertTrue((uv.x...uv.z).contains(m.uvs[2 * i]) && (uv.y...uv.w).contains(m.uvs[2 * i + 1]))
                // Offsets match the hull point (mirrored in x on the card).
                let k = mirror ? m.vertexCount - 1 - i : i
                let h = TreeArchetype.broadHull[k]
                let ox = (mirror ? -h.x : h.x), oy = h.y
                let want = SIMD2(ox * cos(0.4) - oy * sin(0.4), ox * sin(0.4) + oy * cos(0.4))
                XCTAssertLessThan(simd_distance(SIMD2(m.uv4[2 * i], m.uv4[2 * i + 1]), want), 1e-4)
            }
        }
    }

    /// A streamed verge-grass cell mixes tufts of every kind, edge tufts with
    /// soil-coloured roots and bank ferns; all of them carry colour as well.
    func test_grassCellMeshKeepsEveryChannel() {
        var m = MeshBuffer(parts: 1)
        var rnd = WorldRandom(seed: 9)
        let cells: [VegetationBuilder.GrassCell] = [.green, .seeded, .dry, .nettle, .carrot, .knapweed, .tansy, .fern]
        for c in cells {
            VegetationBuilder.grassTuft(&m, x: 1, y: 0, z: 2, rnd: &rnd, tall: true, cell: c)
        }
        VegetationBuilder.grassTuft(&m, x: 0, y: 0, z: 0, rnd: &rnd, tall: false, tint: SIMD3(1.1, 1, 0.9), cell: .green,
                                    height: 0.1...0.22, width: 0.2...0.35, lean: SIMD2(0.06, 0), soilRoots: true)
        VegetationBuilder.fern(&m, base: .zero, normal: SIMD3(0.8, 0.6, 0), along: SIMD3(0, 0, 1), size: 0.7, rnd: &rnd)
        assertChannels(m, "grass cell")
        XCTAssertEqual(m.colors.count, m.vertexCount * 4)
        XCTAssertTrue(m.uvs.allSatisfy { (0...1).contains($0) }, "tuft cells stay inside the atlas")
    }

    /// What the builder makes of them: a cluster mixing trees, shrubs and
    /// bank plants, and the hedges, keeps every channel.
    func test_placedPlantsKeepConsistentChannels() {
        var cluster = MeshBuffer(parts: 2)
        let lib = TreeLibrary()
        var rnd = WorldRandom(seed: 3)
        for f in TreeArchetype.Form.allCases {
            let a = lib.pick(f, &rnd, towardsLane: f == .oak)
            VegetationBuilder.appendPlant(&cluster, a.full, sx: 0.8, sy: 0.9, yaw: 1, x: 5, y: 2, z: -3, phase: 1,
                                          tint: TreeArchetype.packColour(f.leafColour), lean: SIMD2(0.5, 0), height: 12)
        }
        TreeArchetype.card(&cluster, centre: SIMD3(0, 1, 0), size: 1, normal: SIMD3(0, 1, 0), roll: 0, uv: TreeArchetype.ivyUV,
                           crownCentre: .zero, crownRadii: SIMD3(1, 1, 1), height: 3, ao: 0.9, billboard: false)
        assertChannels(cluster, "cluster")
        let packed = cluster.uv3.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        XCTAssertTrue(packed.contains { $0 >= 65536 }, "trees carry a packed colour")
    }

    // MARK: - The Riviera

    private let riviera = TreeArchetype.Form.allCases.filter(\.isRiviera)

    /// The Riviera's hulls (fitted by `fit_hulls.py --med`) hold their
    /// cells' leaves in cj_foliage_med.png (a texel or so of the fan's
    /// tip may stand out), stay convex inside their card, and the hedge
    /// cores sit in opaque leaf.
    func test_medHullsEncloseTheirLeaves() throws {
        let (alpha, w, h) = try foliageAlpha("cj_foliage_med")
        let cells: [(String, SIMD4<Float>)] = [
            ("aleppo", TreeArchetype.medAleppoUV), ("pinea", TreeArchetype.medPineaUV), ("olive", TreeArchetype.medOliveUV),
            ("evergreen", TreeArchetype.medEvergreenUV), ("cypress", TreeArchetype.medCypressUV),
            ("bougainvillea", TreeArchetype.medBougainvilleaUV), ("fan", TreeArchetype.medFanUV), ("deadFan", TreeArchetype.medDeadFanUV),
        ]
        for (name, uv) in cells {
            let hull = try XCTUnwrap(TreeArchetype.hull(for: uv), name)
            for (k, p) in hull.enumerated() {
                XCTAssertTrue(abs(p.x) <= 1 && abs(p.y) <= 1, "\(name): \(p) outside the card")
                let a = hull[(k + 1) % hull.count] - p, b = hull[(k + 2) % hull.count] - hull[(k + 1) % hull.count]
                XCTAssertGreaterThan(a.x * b.y - a.y * b.x, 0, "\(name): hull turns clockwise at \(k + 1)")
            }
            var leaves = 0, outside = 0
            for y in 0..<h {
                let v = (Float(y) + 0.5) / Float(h)
                guard v >= uv.y, v <= uv.w else { continue }
                for x in 0..<w where alpha[y * w + x] > 76 {
                    let u = (Float(x) + 0.5) / Float(w)
                    guard u >= uv.x, u <= uv.z else { continue }
                    let p = SIMD2((u - uv.x) / (uv.z - uv.x) * 2 - 1, (uv.w - v) / (uv.w - uv.y) * 2 - 1)
                    leaves += 1
                    let inside = hull.indices.allSatisfy { k in
                        let a = hull[k], b = hull[(k + 1) % hull.count]
                        return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) >= -1e-5
                    }
                    if !inside { outside += 1 }
                }
            }
            XCTAssertGreaterThan(leaves, w * h / 400, "\(name): too few leaves, wrong cell?")
            XCTAssertLessThanOrEqual(outside, leaves / 10_000, "\(name): \(outside) of \(leaves) leaf texels outside; run fit_hulls.py --med")
        }
        for uv in [TreeArchetype.medEvergreenUV, TreeArchetype.medBougainvilleaUV, TreeArchetype.medCypressUV] {
            let core = TreeArchetype.core(for: uv)
            XCTAssertTrue((uv.x...uv.z).contains(core.x) && (uv.y...uv.w).contains(core.y), "core outside its cell")
            let cx = Int(core.x * Float(w)), cy = Int(core.y * Float(h))
            for dy in -3...3 {
                for dx in -3...3 { XCTAssertGreaterThanOrEqual(alpha[(cy + dy) * w + cx + dx], 253, "core texel not in opaque leaf") }
            }
        }
    }

    /// Every Riviera tree's bark sits on its own tile of the bark atlas
    /// (`TreeArchetype.setBark`), and its leaves inside cj_foliage_med's
    /// cells (none in the Flemish atlas's quadrants' places by mistake).
    func test_rivieraBarkAndLeavesUseTheirAtlases() {
        for a in all where a.form.isRiviera {
            let tile = Float(a.form.medBark.tile.rawValue) * TreeArchetype.barkTileStride
            for m in [a.full, a.light] {
                for i in Set(m.parts[0]).map(Int.init) {
                    XCTAssertTrue((tile..<(tile + TreeArchetype.barkTileStride)).contains(m.uvs[2 * i]), "\(a.form) bark u \(m.uvs[2 * i])")
                }
                for i in Set(m.parts[1]).map(Int.init) {
                    XCTAssertTrue((0...1).contains(m.uvs[2 * i]) && (0...1).contains(m.uvs[2 * i + 1]), "\(a.form) leaf uv")
                }
            }
        }
    }

    /// A cypress is a dense column like the Lombardy's: no band over 1 m
    /// without leaves from its foot to near its top, and slender.
    func test_cypressColumnHasNoGaps() {
        for a in all where a.form == .cypress {
            let ys = cardCentres(a.full).map(\.y).sorted()
            let inColumn = ys.filter { $0 >= a.crownBase && $0 <= 0.9 * a.refHeight }
            XCTAssertGreaterThan(inColumn.count, 120)
            XCTAssertLessThan(zip(inColumn, inColumn.dropFirst()).map { $1 - $0 }.max() ?? 0, 1.0)
            XCTAssertLessThan(width(a.full, from: 0, to: a.refHeight), 3.2, "a cypress is narrow")
        }
    }

    /// A Canary palm's crown: dozens of fronds as ribbons in the frond
    /// strip, reaching out about their length, the old ones drooping below
    /// the crown, none down to the ground.
    func test_phoenixCrownSpreadsAndDroops() {
        for a in all where a.form == .phoenixPalm {
            let leaves = Set(a.full.parts[1]).map(Int.init)
            let uv = TreeArchetype.medFrondUV
            XCTAssertTrue(leaves.allSatisfy { (uv.x...uv.z).contains(a.full.uvs[2 * $0]) && (uv.y...uv.w).contains(a.full.uvs[2 * $0 + 1]) })
            XCTAssertGreaterThan(a.full.parts[1].count / 3, 900, "a dense crown")
            let reach = leaves.map { simd_length(SIMD2(a.full.positions[3 * $0], a.full.positions[3 * $0 + 2])) }.max() ?? 0
            XCTAssertGreaterThan(reach, 3.5)
            let low = leaves.map { a.full.positions[3 * $0 + 1] }.min() ?? 0
            XCTAssertGreaterThan(low, 0.8, "fronds down to the ground")
            XCTAssertLessThan(low, a.crownBase + 1.5, "the old fronds should droop below the crown")
        }
    }

    /// The species the data give are the trees drawn; without one, the mix
    /// is the Riviera's alone.
    func test_rivieraPickHonoursSpeciesAndStaysRiviera() {
        var rnd = WorldRandom(seed: 4)
        let named: [(String, TreeArchetype.Form)] = [("pine", .aleppoPine), ("umbrellaPine", .stonePine), ("cypress", .cypress),
                                                     ("palm", .phoenixPalm), ("olive", .olive), ("araucaria", .araucaria)]
        for (kind, form) in named {
            XCTAssertEqual(VegetationBuilder.pickRivieraForm(kind: kind, h: 10, r: 3, landuse: nil, crowded: false, zone: nil, y: 50,
                                                             rnd: &rnd), form, kind)
        }
        let zones: [RivieraPlants.Mix?] = [nil, .seaFront, .villaGardens, .sanctuaryPark, .greenhouseBelt, .terraces, .summit]
        for zone in zones {
            for lu in [nil, "residential", "forest", "orchard", "farmland"] {
                for _ in 0..<40 {
                    let h = rnd.range(3, 22), r = rnd.range(0.6, 7)
                    let f = VegetationBuilder.pickRivieraForm(kind: rnd.unit() < 0.3 ? "conifer" : nil, h: h, r: r, landuse: lu,
                                                              crowded: false, zone: zone, y: 40, rnd: &rnd)
                    XCTAssertTrue(f.isRiviera, "\(f) for \(String(describing: lu)) in \(String(describing: zone))")
                }
            }
        }
    }

    /// Prickly pear and agave are solid (bark atlas, part 0), on their own
    /// tiles, with every channel.
    func test_succulentsAreSolidOnTheirTiles() {
        var rnd = WorldRandom(seed: 6)
        for (name, tile) in [("opuntia", TreeArchetype.MedBark.opuntia), ("agave", .agave)] {
            var m = MeshBuffer(parts: 2)
            if name == "opuntia" {
                VegetationBuilder.opuntia(&m, base: SIMD3(0, 10, 0), height: 2, rnd: &rnd)
            } else {
                VegetationBuilder.agave(&m, base: SIMD3(0, 10, 0), size: 1.4, spike: false, rnd: &rnd)
            }
            assertChannels(m, name)
            XCTAssertTrue(m.parts[1].isEmpty, "\(name) has no leaf cards")
            let t0 = Float(tile.rawValue) * TreeArchetype.barkTileStride
            XCTAssertTrue(Set(m.parts[0]).allSatisfy { (t0..<(t0 + TreeArchetype.barkTileStride)).contains(m.uvs[2 * Int($0)]) }, name)
            XCTAssertLessThan(m.triangleCount, 1600, "\(name): \(m.triangleCount) triangles")
            let top = (0..<m.vertexCount).map { m.positions[3 * $0 + 1] }.max() ?? 0
            XCTAssertGreaterThan(top, 10.8, "\(name) too low")
        }
    }

    /// The Riviera's hedges are closed walls clad in its own leaves, like
    /// the Flemish ones.
    func test_rivieraHedgesUseTheirAtlas() {
        for kind in [CourseArt.HedgeKind.green, .copperBeech, .laurel, .ivy] {
            let look = VegetationBuilder.hedgeLook(kind, riviera: true)
            XCTAssertNotNil(TreeArchetype.medCore(for: look.uv), "\(kind): no core leaf in cj_foliage_med")
            var m = MeshBuffer(parts: 2)
            var rnd = WorldRandom(seed: 5)
            // (As long as the Flemish test's, so the ends weigh the same.)
            VegetationBuilder.hedgeStretch(straightHedge(length: 24, height: 2.4), look: look, rnd: &rnd, into: &m)
            assertChannels(m, "\(kind) Riviera hedge")
            XCTAssertLessThan(Float(m.triangleCount) / 24, 155, "\(kind): \(m.triangleCount) triangles")
        }
    }

    /// The Riviera's trees keep to the world's budget (the research notes
    /// on the Poggio: a palm's full version about 1.5 k triangles, its
    /// light one about 200), the others to what a Flemish beech costs.
    func test_rivieraArchetypesKeepToTheTriangleBudget() {
        let palms: Set<TreeArchetype.Form> = [.phoenixPalm, .washingtonia, .fanPalm]
        for a in all where a.form.isRiviera {
            let palm = palms.contains(a.form)
            XCTAssertLessThanOrEqual(a.full.triangleCount, palm ? 1500 : 2000, "\(a.form) full: \(a.full.triangleCount)")
            XCTAssertLessThanOrEqual(a.light.triangleCount, palm ? 220 : 450, "\(a.form) light: \(a.light.triangleCount)")
        }
    }

    /// The Poggio's hand-placed plants are moved from the look bible's s
    /// onto the route through its landmarks: at the fork and hairpin 2 as
    /// course.json has them, steadily, and the climb's start still counts.
    func test_poggioPlantsFollowTheRoutesDrift() {
        let c = RivieraPlants.poggio
        XCTAssertEqual(c.routeS(0, start: 300), 300, accuracy: 1e-9)
        XCTAssertEqual(c.routeS(1383, start: 300), 1677, accuracy: 1e-9, "hairpin 2")
        XCTAssertEqual(c.routeS(3731, start: 299.99), 4016.29, accuracy: 0.01, "the summit")
        XCTAssertEqual(c.routeS(500, start: 310) - c.routeS(500, start: 300), 10, accuracy: 1e-9)
        var last = -Double.infinity
        for s in stride(from: -300.0, through: 4200, by: 5) {
            let r = c.routeS(s, start: 300)
            XCTAssertGreaterThan(r, last, "s \(s)")
            last = r
        }
    }

    /// A crown taller than the terraces' olives is never drawn as one, and
    /// a very tall one (over 19 m) is a stone pine, a eucalypt, a pine, a
    /// cypress or a Washingtonia, never a palm or an oak stretched to it.
    func test_rivieraTallCrownsKeepPlausibleSpecies() {
        var rnd = WorldRandom(seed: 9)
        let zones: [RivieraPlants.Mix?] = [nil, .seaFront, .villaGardens, .sanctuaryPark, .greenhouseBelt, .terraces, .summit]
        let tall: Set<TreeArchetype.Form> = [.stonePine, .eucalyptus, .aleppoPine, .cypress, .washingtonia]
        for zone in zones {
            for lu in [nil, "residential", "forest", "orchard", "olive", "terraces", "greenhouse", "farmland"] {
                for _ in 0..<40 {
                    let h = rnd.range(10, 30), r = rnd.range(0.6, 8)
                    let f = VegetationBuilder.pickRivieraForm(kind: rnd.unit() < 0.3 ? "conifer" : "deciduous", h: h, r: r,
                                                              landuse: lu, crowded: false, zone: zone, y: 40, rnd: &rnd)
                    XCTAssertNotEqual(f, .olive, "a \(h) m olive")
                    if h > 19 { XCTAssertTrue(tall.contains(f), "\(f) at \(h) m") }
                    // (A guessed fan palm over 16 m stood alone as a chimney
                    // at hairpin 1; the summit's are its own planting.)
                    if f == .washingtonia, zone != .summit { XCTAssertLessThanOrEqual(h, 16, "a \(h) m Washingtonia") }
                }
            }
        }
    }

    /// The linear colour a shader reads, averaged over a texture level's
    /// region (fractions of its size), read back from the GPU; nil for a
    /// format this doesn't decode.
    private func meanLinear(_ tex: MTLTexture, level: Int, x0: Double, y0: Double, x1: Double, y1: Double) -> SIMD3<Double>? {
        let w = max(tex.width >> level, 1), h = max(tex.height >> level, 1)
        let bpp: Int
        switch tex.pixelFormat {
        case .rgba8Unorm, .rgba8Unorm_srgb, .bgra8Unorm, .bgra8Unorm_srgb: bpp = 4
        case .rgba16Float: bpp = 8
        default: return nil
        }
        guard let queue = tex.device.makeCommandQueue(),
              let buf = tex.device.makeBuffer(length: w * h * bpp, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
                  destinationBytesPerRow: w * bpp, destinationBytesPerImage: w * h * bpp)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        let srgb = [.rgba8Unorm_srgb, .bgra8Unorm_srgb].contains(tex.pixelFormat)
        let bgr = [.bgra8Unorm, .bgra8Unorm_srgb].contains(tex.pixelFormat)
        func lin(_ c: Double) -> Double { srgb ? (c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)) : c }
        var sum = SIMD3<Double>(0, 0, 0), n = 0.0
        for y in Int(y0 * Double(h))..<Int(y1 * Double(h)) {
            for x in Int(x0 * Double(w))..<Int(x1 * Double(w)) {
                let o = (y * w + x) * bpp
                var c: SIMD3<Double>
                if bpp == 8 {
                    let p = buf.contents().advanced(by: o).assumingMemoryBound(to: Float16.self)
                    c = SIMD3(Double(p[0]), Double(p[1]), Double(p[2]))
                } else {
                    let p = buf.contents().advanced(by: o).assumingMemoryBound(to: UInt8.self)
                    c = SIMD3(lin(Double(p[0]) / 255), lin(Double(p[1]) / 255), lin(Double(p[2]) / 255))
                    if bgr { c = SIMD3(c.z, c.y, c.x) }
                }
                sum += c
                n += 1
            }
        }
        return sum / max(n, 1)
    }

    /// The bark atlas a trunk's shader samples (`barkAtlasSurface`) reads
    /// the same colours on every tier: on battery (texture limit 1024) every
    /// Riviera trunk drew pale pinkish white while balanced was right.
    /// Compared at the same size (the 4096 / 2048 tiers' level 1 against
    /// battery's level 0), tile by tile.
    func test_rivieraBarkAtlasKeepsItsColourOnEveryTier() throws {
        var means: [Int: [SIMD3<Double>]] = [:]
        let b = try CourseBundle.load(id: "poggio")
        for limit in [4096, 2048, 1024] {
            let mats = WorldMaterials(config: .make(limit == 1024 ? .battery : limit == 2048 ? .balanced : .high),
                                      textures: WorldTextures(limit: limit), bundle: b, art: CourseArt.make(bundle: b))
            let m = mats.makeBarkAtlas()
            let albedo = try XCTUnwrap((m.value(forKey: "albedoTex") as? SCNMaterialProperty)?.contents as? MTLTexture, "\(limit)")
            let detail = try XCTUnwrap((m.value(forKey: "detailTex") as? SCNMaterialProperty)?.contents as? MTLTexture, "\(limit)")
            XCTAssertLessThanOrEqual(max(albedo.width, albedo.height), limit)
            let level = albedo.width > 1024 ? 1 : 0
            for tile in 0..<8 {
                let x = Double(tile % 4) * 0.25, y = Double(tile / 4) * 0.5
                let c = try XCTUnwrap(meanLinear(albedo, level: level, x0: x + 0.02, y0: y + 0.04, x1: x + 0.23, y1: y + 0.46),
                                      "albedo format \(albedo.pixelFormat.rawValue)")
                let d = try XCTUnwrap(meanLinear(detail, level: detail.width > 1024 ? 1 : 0, x0: x + 0.02, y0: y + 0.04, x1: x + 0.23, y1: y + 0.46),
                                      "detail format \(detail.pixelFormat.rawValue)")
                means[tile, default: []].append(c)
                XCTAssertGreaterThan(d.z, 0.3, "tile \(tile) roughness at \(limit)")
            }
        }
        for (tile, cs) in means {
            for c in cs.dropFirst() {
                XCTAssertEqual(c.x, cs[0].x, accuracy: 0.02, "tile \(tile) (the battery tier last)")
                XCTAssertEqual(c.y, cs[0].y, accuracy: 0.02, "tile \(tile)")
                XCTAssertEqual(c.z, cs[0].z, accuracy: 0.02, "tile \(tile)")
            }
        }
    }

    /// On the Riviera a cluster drawn in full keeps the light versions of
    /// its plants that have no full one (`Cluster.lightOnly`), and a cluster
    /// with no full level is left as it is.
    func test_rivieraFullClusterKeepsItsLightOnlyPlants() {
        var card = MeshBuffer(parts: 2)
        TreeArchetype.card(&card, centre: SIMD3(0, 1, 0), size: 1, normal: SIMD3(0, 0, 1), roll: 0, uv: TreeArchetype.medEvergreenUV,
                           crownCentre: .zero, crownRadii: SIMD3(1, 1, 1), height: 3, ao: 0.9)
        var near = VegetationBuilder.Cluster()
        near.full.appendExactly(card)
        near.full.appendExactly(card)
        near.light.appendExactly(card)
        near.light.appendExactly(card)
        near.lightOnly.appendExactly(card)
        let folded = VegetationBuilder.foldLightOnly(near)
        XCTAssertEqual(folded.full.triangleCount, 3 * card.triangleCount)
        XCTAssertTrue(folded.lightOnly.isEmpty)
        assertChannels(folded.full, "folded full")
        var far = VegetationBuilder.Cluster()
        far.light.appendExactly(card)
        far.lightOnly.appendExactly(card)
        let kept = VegetationBuilder.foldLightOnly(far)
        XCTAssertTrue(kept.full.isEmpty)
        XCTAssertEqual(kept.light.triangleCount, card.triangleCount)
    }

    /// The Poggio's plants as built: both hand-placed Norfolk Island pines
    /// (the second stood in a villa and was dropped), the prickly-pear
    /// thicket at hairpin 2, and the maquis on the banks (`buildRivieraScrub`)
    /// within reason; every cluster's channels whole.
    func test_poggioVegetationKeepsItsSignaturePlants() throws {
        let b = try CourseBundle.load(id: "poggio")
        let corridor = RoadCorridor(bundle: b, vergeWidth: 13)
        let out = VegetationBuilder.build(corridor: corridor, scenery: b.scenery, config: WorldConfig.make(.high).riviera(),
                                          courseID: "poggio")
        XCTAssertEqual(out.counts["trees: araucaria"], 2)
        XCTAssertGreaterThanOrEqual(out.counts["riviera succulents"] ?? 0, 9)
        let scrub = out.counts["riviera scrub"] ?? 0
        XCTAssertGreaterThan(scrub, 12_000)
        XCTAssertLessThan(scrub, 60_000)
        for c in out.clusters {
            XCTAssertTrue(c.lightOnly.isEmpty, "light-only plants folded or let go of")
            if !c.full.isEmpty { assertChannels(c.full, "full") }
            if !c.light.isEmpty { assertChannels(c.light, "light") }
        }
        // The light level of every cluster (the trees' and shrubs' light
        // versions and the scrub, 2-6 triangles a clump): 0.44 M with the
        // scrub of 30 October, before it thinned with distance.
        let light = out.clusters.reduce(0) { $0 + $1.light.triangleCount }
        XCTAssertLessThan(light, 520_000)
        // Every clump's leaves stay behind the edge walls' footprints and
        // off the carriageway (reviews2: cards through the render wall at
        // route 2100), and the cameras know the scrub.
        let field = try XCTUnwrap(VegetationBuilder.ScrubField.current(courseID: "poggio"))
        XCTAssertEqual(field.discs.filter { !$0.shrub }.count, scrub)
        let edge = VegetationBuilder.RivieraEdge(corridor: corridor, scenery: b.scenery)
        var through = 0, onRoad = 0
        for d in field.discs where !d.shrub {
            let q = corridor.coarse.query(east: d.e, north: d.n)
            let st = corridor.station(at: q.s)
            let side: Double = (d.e - st.east) * st.rightE + (d.n - st.north) * st.rightN >= 0 ? 1 : -1
            let beyond = q.dist - st.reach(side)
            let wall = edge.back(q.s, side: side)
            if wall > 0, beyond > wall - 0.5, beyond - Double(d.radius) < wall + 0.1 { through += 1 }
            if beyond - Double(d.radius) < 0.2 { onRoad += 1 }
        }
        // (A few hundredths of a metre either way where the nearest station
        // of a clump and of its lattice point differ round a bend.)
        XCTAssertLessThan(through, scrub / 500, "clumps reaching through an edge wall's face")
        XCTAssertLessThan(onRoad, scrub / 500, "clumps reaching over the carriageway")
        let clearance = CameraClearance(bundle: b)
        let near = try XCTUnwrap(field.discs.first { !$0.shrub && corridor.coarse.query(east: $0.e, north: $0.n).dist < 10 })
        let s = corridor.coarse.query(east: near.e, north: near.n).s
        XCTAssertGreaterThanOrEqual(clearance.groundTop(east: near.e, north: near.n, near: s), near.top - 0.01,
                                    "the ride's clearance has the scrub")
    }
}
