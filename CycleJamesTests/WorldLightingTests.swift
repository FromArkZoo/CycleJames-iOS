import XCTest
import SceneKit
import Metal
@testable import CycleJames

/// The course's light raster (scripts/courses/textures/bake_light_maps.py,
/// `WorldMaterials+Light`, `WorldShaders+Light`): the bake matches the
/// near terrain grid and the places it should darken, the shaders splice
/// the snippet whole, and every material that splices it has all of its
/// uniforms, copies included, also after a live tier step. SceneKit draws
/// an unset texture as black and an unset float as 0, without a word.
final class WorldLightingTests: XCTestCase {
    private func bundle(_ id: String) throws -> CourseBundle {
        do {
            return try CourseBundle.load(id: id)
        } catch {
            throw XCTSkip("\(id) data not in the test host bundle: \(error)")
        }
    }

    /// `<id>_light.rgbz` decoded: width, height, RGBA8 rows (north first).
    private func raster(_ id: String) throws -> (w: Int, h: Int, px: [UInt8]) {
        guard let url = Bundle.main.url(forResource: "\(id)_light", withExtension: "rgbz")
                ?? Bundle.main.url(forResource: "\(id)_light", withExtension: "rgbz", subdirectory: "CourseTextures"),
              let file = try? Data(contentsOf: url), file.count > 8 else {
            throw XCTSkip("\(id)_light.rgbz not in the test host bundle")
        }
        let w = file.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian) }
        let h = file.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian) }
        let pixels = try (file.subdata(in: 8..<file.count) as NSData).decompressed(using: .zlib) as Data
        XCTAssertEqual(pixels.count, w * h * 4, id)
        return (w, h, [UInt8](pixels))
    }

    private func materials(_ b: CourseBundle, _ q: GraphicsQuality) -> WorldMaterials {
        WorldMaterials(config: .make(q), textures: WorldTextures(limit: WorldConfig.make(q).textureLimit),
                       bundle: b, art: CourseArt.make(bundle: b))
    }

    func test_eachCourseHasARasterOnItsNearGrid() throws {
        for id in CourseCatalog.courseIDs {
            let b = try bundle(id)
            let r = try raster(id)
            let t = b.terrainNear
            XCTAssertEqual(r.w, t.cols, id)
            XCTAssertEqual(r.h, t.rows, id)
            // Along the route: mostly open sky (the Muur least, about 0.58:
            // town streets between three- and four-storey terraces, then the
            // park lane under 10-25 m of canopy), and the ground height code
            // higher at the summit than at the foot.
            let route = b.route
            var sky = 0.0
            for i in route.s.indices {
                let col = min(max(Int(route.east[i] - t.originEast), 0), r.w - 1)
                let row = min(max(Int(t.originNorth - route.north[i]), 0), r.h - 1)
                sky += Double(r.px[(row * r.w + col) * 4]) / 255
            }
            sky /= Double(route.s.count)
            XCTAssertGreaterThan(sky, 0.55, "\(id): mean sky visibility along the route \(sky)")
            XCTAssertLessThan(sky, 0.97, "\(id): nothing on the route is shaded? \(sky)")
            let lo = route.elev.indices.min { route.elev[$0] < route.elev[$1] }!
            let hi = route.elev.indices.max { route.elev[$0] < route.elev[$1] }!
            func height(_ i: Int) -> UInt8 {
                let col = min(max(Int(route.east[i] - t.originEast), 0), r.w - 1)
                let row = min(max(Int(t.originNorth - route.north[i]), 0), r.h - 1)
                return r.px[(row * r.w + col) * 4 + 3]
            }
            XCTAssertGreaterThan(height(hi), height(lo), "\(id): ground height code")
        }
    }

    /// The Koppenberg's holle weg (s 500-650) sees a fraction of the sky the
    /// open fields past s 900 see.
    func test_theKoppenbergLaneIsDeepAndTheFieldsOpen() throws {
        let b = try bundle("koppenberg")
        let r = try raster("koppenberg")
        let t = b.terrainNear, route = b.route
        func meanSky(_ s0: Double, _ s1: Double) -> Double {
            var sum = 0.0, n = 0.0
            for i in route.s.indices where route.s[i] >= s0 && route.s[i] < s1 {
                let col = Int(route.east[i] - t.originEast), row = Int(t.originNorth - route.north[i])
                sum += Double(r.px[(row * r.w + col) * 4]) / 255
                n += 1
            }
            return sum / max(n, 1)
        }
        XCTAssertLessThan(meanSky(500, 650), 0.45)
        XCTAssertGreaterThan(meanSky(900, 1000), 0.9)
    }

    /// World (x, z), z pointing south, onto the raster as the bake lays it.
    func test_uvMapsTheRasterCorners() throws {
        let b = try bundle("oudekwaremont")
        let t = b.terrainNear
        let uv = materials(b, .balanced).lightUV
        func map(_ east: Double, _ north: Double) -> SIMD2<Double> {
            SIMD2(east * Double(uv.x) + Double(uv.z), -north * Double(uv.y) + Double(uv.w))
        }
        let nw = map(t.originEast, t.originNorth)
        let se = map(t.originEast + t.widthM, t.originNorth - t.heightM)
        XCTAssertEqual(nw.x, 0, accuracy: 1e-5)
        XCTAssertEqual(nw.y, 0, accuracy: 1e-5)
        XCTAssertEqual(se.x, 1, accuracy: 1e-5)
        XCTAssertEqual(se.y, 1, accuracy: 1e-5)
    }

    func test_bakedShadeTakesOverAtEachTiersShadowEdge() {
        var floors: [Float] = []
        for q in [GraphicsQuality.high, .balanced, .battery] {
            let config = WorldConfig.make(q)
            let k = WorldMaterials.lightK(config)
            XCTAssertEqual(Double(k.z), config.shadowDistance, accuracy: 1e-3, "\(q)")
            XCTAssertLessThan(k.y, k.z, "\(q)")
            XCTAssertGreaterThan(Double(k.y), config.shadowDistance * 0.8, "\(q)")
            XCTAssertGreaterThan(k.x, 3, "\(q): sun-to-sky ratio")
            floors.append(k.w)
        }
        // Less shadow, less occlusion: lanes stay legible where the tier
        // draws the least shade.
        XCTAssertEqual(floors, [0.55, 0.6, 0.65])
    }

    /// Each surface that applies the light also declares its arguments
    /// (with no comment in the block), fetches once and applies once; the
    /// cycle lane's tint still finds its anchors.
    func test_snippetsAreSplicedWhole() {
        let hosts = ["terrainSurface": WorldShaders.terrainSurface,
                     "pavedSurface": WorldShaders.pavedSurface,
                     "tintedPavedSurface": WorldShaders.tintedPavedSurface,
                     "concreteSurface": WorldShaders.concreteSurface,
                     "settSurface": WorldShaders.settSurface]
        for (name, src) in hosts {
            let args = src.components(separatedBy: "#pragma arguments")[1].components(separatedBy: "#pragma")[0]
            XCTAssertTrue(args.contains(WorldShaders.lightArgs), name)
            XCTAssertFalse(args.contains("//"), "\(name): a comment in the arguments block")
            XCTAssertEqual(src.components(separatedBy: WorldShaders.lightFetch).count, 2, name)
            XCTAssertEqual(src.components(separatedBy: WorldShaders.lightApply).count, 2, name)
            // The fetch comes first, then the apply, then the diffuse.
            let f = src.range(of: WorldShaders.lightFetch)!.lowerBound
            let a = src.range(of: WorldShaders.lightApply)!.lowerBound
            let d = src.range(of: "_surface.diffuse = float4(alb, 1.0);")!.lowerBound
            XCTAssertTrue(f < a && a < d, name)
        }
        XCTAssertTrue(WorldShaders.tintedPavedSurface.contains("float3 tint3;\n#pragma body"))
        XCTAssertTrue(WorldShaders.tintedPavedSurface.contains("alb *= tint3;"))
        // The setts' micro-shadows are gated by the raster's sun visibility.
        XCTAssertTrue(WorldShaders.settSurface.contains("microShadow * lgtQ.g"))
    }

    /// The walls correct the raster between the fetch and the apply. A
    /// chimney stack (`WallKind.stack`, the shader's kind 5) stands above
    /// the roofs, but 2 m out from it is still its house, where the bake
    /// leaves no sun: it takes open, sunlit ground. The ground's sun shade
    /// fades up the wall unless the canopy (B, metres / 40) stands higher.
    func test_wallsCorrectTheRasterBeforeApplyingIt() throws {
        XCTAssertEqual(BuildingBuilder.WallKind.stack.rawValue, 5)
        XCTAssertEqual(BuildingBuilder.wallCode(.stack, tint: 7), 47, "kind = floor(code / 8) in the shader")
        let src = WorldShaders.wallSurface
        let kind = try XCTUnwrap(src.range(of: "float kind = floor(code * 0.125 + 0.01);")).lowerBound
        let f = try XCTUnwrap(src.range(of: WorldShaders.lightFetch))
        let a = try XCTUnwrap(src.range(of: WorldShaders.lightApply)).lowerBound
        XCTAssertTrue(kind < f.lowerBound && f.upperBound < a)
        let between = String(src[f.upperBound..<a])
        XCTAssertTrue(between.contains("if (kind > 4.5 && kind < 5.5) lgtQ = float4(1.0, 1.0, 0.0, 0.0);"), between)
        XCTAssertTrue(between.contains("lgtQ.g = mix(lgtQ.g, 1.0, smoothstep(1.5, 5.0, hG) * smoothstep(0.0, 2.0, hG - lgtQ.b * 40.0));"),
                      between)
        // The stack's open sky is set before the sky's height term reads it.
        let stack = try XCTUnwrap(between.range(of: "if (kind > 4.5")).lowerBound
        let skyUp = try XCTUnwrap(between.range(of: "lgtQ.r = 1.0 - (1.0 - lgtQ.r)")).lowerBound
        XCTAssertTrue(stack < skyUp)
    }

    /// Every material that splices the snippet has the raster and all its
    /// uniforms, copies included, and the live list reaches all of them.
    func test_everyLitMaterialIsBoundAndFollowsTheTier() throws {
        let b = try bundle("koppenberg")
        let m = materials(b, .balanced)
        let lit = m.lit
        for mat in m.warmUp {
            let splices = mat.shaderModifiers?[.surface]?.contains("lightTex") ?? false
            XCTAssertEqual(splices, lit.contains { $0 === mat },
                           "\(mat.shaderModifiers?[.surface]?.prefix(60) ?? "plain"): in `lit` iff it splices the light")
        }
        for mat in lit {
            let label = String(mat.shaderModifiers?[.surface]?.prefix(40) ?? "plain")
            XCTAssertTrue(mat.shaderModifiers?[.surface]?.contains("lightTex") ?? false, label)
            let tex = (mat.value(forKey: "lightTex") as? SCNMaterialProperty)?.contents as? MTLTexture
            XCTAssertNotNil(tex, label)
            XCTAssertEqual(tex?.width, b.terrainNear.cols, label)
            for key in ["lightUV", "lightK", "lightSun"] {
                XCTAssertNotNil(mat.value(forKey: key) as? NSValue, "\(label): \(key)")
            }
            XCTAssertEqual((mat.value(forKey: "lightK") as? NSValue)?.scnVector4Value.w ?? 0, 0.6, accuracy: 1e-6, label)
        }
        m.applyLive(.make(.battery))
        for mat in lit {
            let k = (mat.value(forKey: "lightK") as? NSValue)?.scnVector4Value
            XCTAssertEqual(k?.z ?? 0, 45, accuracy: 1e-4, "after a live step")
            XCTAssertEqual(k?.w ?? 0, 0.65, accuracy: 1e-6, "after a live step")
        }
    }

    /// The world build decodes the raster once (`CourseWorldBuilder`) and
    /// hands it on. The plants' `SkyRaster` samples exactly as one made
    /// channel by channel from the file, as it was when it decoded the file
    /// itself; the lane meter reads the course's route over its near grid;
    /// and the textures upload the pixels handed in, without decoding the
    /// file again, to the GPU texels the file holds.
    func test_oneDecodeFeedsThePlantsTheMeterAndTheGPU() throws {
        let b = try bundle("koppenberg")
        let r = try raster("koppenberg")
        let name = "koppenberg_light"
        let px = try XCTUnwrap(WorldTextures.rawPixels(name))
        XCTAssertEqual(px.width, r.w)
        XCTAssertEqual(px.height, r.h)
        XCTAssertTrue(px.rgba.elementsEqual(r.px))

        let config = WorldConfig.make(.balanced)
        let t = b.terrainNear
        let sky = try XCTUnwrap(SkyRaster(pixels: px, bundle: b, config: config))
        let reference = SkyRaster(sky: stride(from: 0, to: r.px.count, by: 4).map { r.px[$0] },
                                  canopy: stride(from: 2, to: r.px.count, by: 4).map { r.px[$0] },
                                  width: r.w, height: r.h, originEast: t.originEast, originNorth: t.originNorth,
                                  metresPerPixel: t.widthM / Double(r.w), minSky: WorldMaterials.skyFloor(config))
        var shaded = 0, canopy = 0
        for s in stride(from: 0.0, through: b.route.length, by: 5) {
            let pose = b.route.pose(at: s)
            for lateral: Float in [-12, -4, 0, 3, 9] {
                let p = pose.position + pose.right * lateral
                let east = Double(p.x), north = Double(-p.z)
                let v = sky.visibility(east: east, north: north)
                XCTAssertEqual(v, reference.visibility(east: east, north: north), "s \(s), \(lateral) m")
                XCTAssertEqual(sky.hasCanopy(east: east, north: north), reference.hasCanopy(east: east, north: north))
                XCTAssertEqual(sky.plantSky(east: east, north: north, radius: 3),
                               reference.plantSky(east: east, north: north, radius: 3), "s \(s), \(lateral) m")
                if v < 0.8 { shaded += 1 }
                if sky.hasCanopy(east: east, north: north) { canopy += 1 }
            }
        }
        XCTAssertGreaterThan(shaded, 50, "the comparison covers the lane's shade")
        XCTAssertGreaterThan(canopy, 50, "and its canopy")

        XCTAssertEqual(LightProfile.make(bundle: b, pixels: px).sky,
                       LightProfile.make(route: b.route, grid: t, pixels: (r.w, r.h, Data(r.px))).sky)

        #if DEBUG
        let before = WorldTextures.decodes(name)
        #endif
        let textures = WorldTextures(limit: config.textureLimit)
        textures.adopt(px, as: name)
        let m = WorldMaterials(config: config, textures: textures, bundle: b, art: CourseArt.make(bundle: b))
        let tex = try XCTUnwrap(m.lightRaster)
        #if DEBUG
        XCTAssertEqual(WorldTextures.decodes(name), before, "uploaded from the pixels handed in")
        #endif
        XCTAssertEqual(tex.width, r.w)
        XCTAssertEqual(tex.height, r.h)
        // A block of texels about the route's middle, read back.
        let mid = b.route.pose(at: b.route.length / 2).position
        let n = 48
        let x0 = min(max(Int(Double(mid.x) - t.originEast) - n / 2, 0), r.w - n)
        let y0 = min(max(Int(t.originNorth + Double(mid.z)) - n / 2, 0), r.h - n)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let buf = try XCTUnwrap(device.makeBuffer(length: n * n * 4, options: .storageModeShared))
        let cmd = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let blit = try XCTUnwrap(cmd.makeBlitCommandEncoder())
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x0, y: y0, z: 0),
                  sourceSize: MTLSize(width: n, height: n, depth: 1), to: buf, destinationOffset: 0,
                  destinationBytesPerRow: n * 4, destinationBytesPerImage: n * n * 4)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        let got = Array(UnsafeBufferPointer(start: buf.contents().assumingMemoryBound(to: UInt8.self), count: n * n * 4))
        var want: [UInt8] = []
        for y in y0..<(y0 + n) { want += r.px[((y * r.w + x0) * 4)..<((y * r.w + x0 + n) * 4)] }
        XCTAssertEqual(got, want, "texels at (\(x0), \(y0))")
        #if DEBUG
        // Without pixels handed in, the textures decode the file.
        _ = WorldMaterials(config: config, textures: WorldTextures(limit: config.textureLimit), bundle: b,
                           art: CourseArt.make(bundle: b)).lightRaster
        XCTAssertEqual(WorldTextures.decodes(name), before + 1)
        #endif
    }

    /// A course without a raster is open and sunlit: the fallback's alpha
    /// is 1, so it isn't premultiplied to black.
    func test_fallbackIsOpenSunlitGround() throws {
        let b = try bundle("paterberg")
        let none = CourseBundle(id: "nowhere", directory: b.directory, course: b.course, route: b.route,
                                terrainNear: b.terrainNear, terrainFar: nil, scenery: nil)
        let m = WorldMaterials(config: .make(.balanced), textures: WorldTextures(limit: 2048),
                               bundle: none, art: CourseArt.make(bundle: b))
        let tex = try XCTUnwrap(m.lightRaster)
        XCTAssertEqual(tex.width, 1)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let buf = try XCTUnwrap(device.makeBuffer(length: 4, options: .storageModeShared))
        let cmd = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let blit = try XCTUnwrap(cmd.makeBlitCommandEncoder())
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: buf, destinationOffset: 0,
                  destinationBytesPerRow: 4, destinationBytesPerImage: 4)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        let px = Array(UnsafeBufferPointer(start: buf.contents().assumingMemoryBound(to: UInt8.self), count: 4))
        let sky = tex.pixelFormat == .bgra8Unorm ? px[2] : px[0]
        XCTAssertGreaterThan(sky, 250, "sky \(px) \(tex.pixelFormat.rawValue)")
        XCTAssertGreaterThan(px[1], 250, "sun \(px)")
        XCTAssertGreaterThan(px[3], 250, "alpha \(px)")
    }
}
