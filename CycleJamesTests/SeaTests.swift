import XCTest
import simd
import Metal
@testable import CycleJames

/// The sea's mesh (`SeaBuilder`): it covers the sea cells and a little of
/// the shore, faces up, and knows how far each vertex is from land.
final class SeaTests: XCTestCase {
    /// A 40 x 120 raster of 10 m cells: land (20 m) in the north, the sea
    /// (written a metre under its level, as the pipeline does) from row 60
    /// south.
    private func coast(level: Float = 0) -> HeightRaster {
        let cols = 40, rows = 120
        var v = [Float](repeating: 20, count: cols * rows)
        for j in 60..<rows { for i in 0..<cols { v[j * cols + i] = level - 1 } }
        return HeightRaster(cols: cols, rows: rows, cellM: 10, originEast: 0, originNorth: 1200, values: v)
    }

    func test_shoreDistanceIsZeroOnTheCoastAndGrowsOffshore() {
        let r = coast()
        let sea = r.values.map { SeaBuilder.isSea($0, level: 0) }
        let d = SeaBuilder.shoreDistance(sea: sea, cols: r.cols, rows: r.rows, cellM: 10)
        let w = r.cols + 1
        // Row 60 of corners is the coastline; row 70 is 100 m out.
        XCTAssertEqual(d[60 * w + 20], 0)
        XCTAssertEqual(d[59 * w + 20], 0)
        XCTAssertEqual(d[70 * w + 20], 100, accuracy: 8)
        XCTAssertEqual(d[78 * w + 20], 180, accuracy: 15)
    }

    func test_seaCoversTheSeaAndTwoCellsOfShoreFacingUp() {
        let r = coast()
        var mesh = MeshBuffer()
        SeaBuilder.addRaster(r, level: 0, skipInside: nil, finer: nil, into: &mesh)
        XCTAssertFalse(mesh.isEmpty)
        var minZ = Float.greatestFiniteMagnitude, maxZ = -minZ
        for k in 0..<mesh.vertexCount {
            XCTAssertEqual(mesh.positions[3 * k + 1], 0)
            XCTAssertEqual(mesh.normals[3 * k + 1], 1)
            minZ = min(minZ, mesh.positions[3 * k + 2]); maxZ = max(maxZ, mesh.positions[3 * k + 2])
        }
        // Scene z = -north: the coast (north 600) is at z -600, two cells
        // of shore take it to -620; the south edge (north 0) is at z 0.
        XCTAssertEqual(minZ, -620, accuracy: 1.01)
        XCTAssertEqual(maxZ, 0, accuracy: 1.01)
        // Every triangle faces up (counter-clockwise seen from above).
        let idx = mesh.parts[0]
        for t in stride(from: 0, to: idx.count, by: 3) {
            func p(_ i: UInt32) -> SIMD3<Float> {
                SIMD3(mesh.positions[3 * Int(i)], mesh.positions[3 * Int(i) + 1], mesh.positions[3 * Int(i) + 2])
            }
            let n = simd_cross(p(idx[t + 1]) - p(idx[t]), p(idx[t + 2]) - p(idx[t]))
            XCTAssertGreaterThan(n.y, 0)
        }
    }

    func test_inlandHasNoSea() {
        var mesh = MeshBuffer()
        let land = HeightRaster(cols: 8, rows: 8, cellM: 10, originEast: 0, originNorth: 80,
                                values: [Float](repeating: 30, count: 64))
        SeaBuilder.addRaster(land, level: 0, skipInside: nil, finer: nil, into: &mesh)
        XCTAssertTrue(mesh.isEmpty)
    }

    /// The horizon raster's sea: cells at the level itself count as sea
    /// when they join the open sea, and a large body of "sea" cut off from
    /// it (a gap in the survey, coded as sea, among mountains) is land.
    func test_coarseSeaMaskTakesTheOpenSeaAndLeavesInlandGaps() {
        let cols = 40, rows = 40
        var v = [Float](repeating: 300, count: cols * rows)
        // Open sea in the south: a metre under the level, then the level.
        for j in 25..<rows { for i in 0..<cols { v[j * cols + i] = j < 32 ? -1 : 0 } }
        // A 10 x 10 gap in the north-west, written as sea.
        for j in 0..<10 { for i in 0..<10 { v[j * cols + i] = -1 } }
        // A 3 x 3 harbour basin behind a mole.
        for j in 20..<23 { for i in 20..<23 { v[j * cols + i] = -1 } }
        let r = HeightRaster(cols: cols, rows: rows, cellM: 50, originEast: 0, originNorth: 2000, values: v)
        let m = SeaBuilder.seaMask(r, level: 0, coarse: true)
        XCTAssertTrue(m[26 * cols + 5])
        XCTAssertTrue(m[38 * cols + 5], "cells at the level, joined to the open sea")
        XCTAssertFalse(m[5 * cols + 5], "a large gap apart from the sea is land")
        XCTAssertTrue(m[21 * cols + 21], "a small basin is sea")
        XCTAssertFalse(m[15 * cols + 15])
        // The near and far grids keep the plain test: the level is land.
        XCTAssertFalse(SeaBuilder.seaMask(r, level: 0, coarse: false)[38 * cols + 5])
    }

    /// The mean linear colour of a GPU texture's level over a part of it
    /// (fractions of its width and height), read back from the GPU.
    private func meanLinear(_ tex: MTLTexture, level: Int, x0: Double, y0: Double, x1: Double, y1: Double) -> SIMD3<Double>? {
        let w = max(tex.width >> level, 1), h = max(tex.height >> level, 1)
        let half = tex.pixelFormat == .rgba16Float
        guard half || [.rgba8Unorm, .rgba8Unorm_srgb, .bgra8Unorm, .bgra8Unorm_srgb].contains(tex.pixelFormat) else { return nil }
        let bpp = half ? 8 : 4
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
                var c: SIMD3<Double>
                if half {
                    let p = buf.contents().advanced(by: (y * w + x) * 8).assumingMemoryBound(to: Float16.self)
                    c = SIMD3(Double(p[0]), Double(p[1]), Double(p[2]))
                } else {
                    let p = buf.contents().advanced(by: (y * w + x) * 4).assumingMemoryBound(to: UInt8.self)
                    c = SIMD3(lin(Double(p[0]) / 255), lin(Double(p[1]) / 255), lin(Double(p[2]) / 255))
                    if bgr { c = SIMD3(c.z, c.y, c.x) }
                }
                sum += c
                n += 1
            }
        }
        return sum / max(n, 1)
    }

    /// The Riviera's colour maps that shaders sample themselves read the
    /// same linear colours on every tier. On battery (texture limit 1024)
    /// the 2000 px far photo went through `WorldTextures.downscaled` and
    /// came back from the GPU holding its sRGB-encoded values as linear
    /// ones, so the inland hills drew pale pinkish grey (reviews2). Compared
    /// at about the same size (the high and balanced uploads' level 1
    /// against battery's level 0), over quarters of the map.
    func test_rivieraColourMapsKeepTheirColourOnEveryTier() throws {
        let b = try CourseBundle.load(id: "poggio")
        var means: [String: [SIMD3<Double>]] = [:]
        for limit in [4096, 2048, 1024] {
            let q: GraphicsQuality = limit == 1024 ? .battery : limit == 2048 ? .balanced : .high
            let textures = WorldTextures(limit: limit)
            let mats = WorldMaterials(config: .make(q), textures: textures, bundle: b, art: CourseArt.make(bundle: b))
            // The Flemish facade atlas (`WorldTextures.wideColourDownscales`)
            // still reads 0.61 for 0.41 on battery: left for the user to decide.
            let maps: [(String, MTLTexture?)] = [("poggio_ortho_far", mats.farPhoto),
                                                 ("cj_facade_lig", textures.metal("cj_facade_lig", srgb: true))]
            for (name, tex) in maps {
                let t = try XCTUnwrap(tex, "\(name) at \(limit)")
                XCTAssertLessThanOrEqual(max(t.width, t.height), limit, name)
                let level = max(t.width, t.height) > 1100 ? 1 : 0
                for k in 0..<4 {
                    let x = Double(k % 2) * 0.5, y = Double(k / 2) * 0.5
                    let c = try XCTUnwrap(meanLinear(t, level: level, x0: x + 0.05, y0: y + 0.05, x1: x + 0.45, y1: y + 0.45),
                                          "\(name) format \(t.pixelFormat.rawValue)")
                    means["\(name) \(k)", default: []].append(c)
                }
            }
        }
        // Battery's map is scaled down on the CPU, averaging sRGB-encoded
        // values: a little darker in linear light than the GPU's mip.
        for (key, cs) in means.sorted(by: { $0.key < $1.key }) {
            for c in cs.dropFirst() {
                XCTAssertEqual(c.x, cs[0].x, accuracy: 0.02, "\(key): \(cs) (high, balanced, battery)")
                XCTAssertEqual(c.y, cs[0].y, accuracy: 0.02, "\(key)")
                XCTAssertEqual(c.z, cs[0].z, accuracy: 0.02, "\(key)")
            }
        }
    }

    func test_beyondTheRasterTheSeaRunsOnWhereItsEdgeIsSea() {
        let r = coast()
        let cx = 200.0, cn = 600.0
        XCTAssertTrue(SeaBuilder.edgeIsSea(r, level: 0, east: 200, north: -5000, cx: cx, cn: cn))
        XCTAssertFalse(SeaBuilder.edgeIsSea(r, level: 0, east: 200, north: 5000, cx: cx, cn: cn))
    }
}
