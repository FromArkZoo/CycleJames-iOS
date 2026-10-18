import SceneKit
import UIKit
import MetalKit

/// Materials for the course environment. All physically based; detail comes
/// from baked textures (see `WorldTextures`) and the shader modifiers in
/// `WorldShaders`. Every material is shared by all the geometry that uses
/// it, so each shader is compiled once.
final class WorldMaterials {
    let config: WorldConfig
    let textures: WorldTextures
    let bundle: CourseBundle
    let art: CourseArt

    init(config: WorldConfig, textures: WorldTextures, bundle: CourseBundle, art: CourseArt) {
        self.config = config
        self.textures = textures
        self.bundle = bundle
        self.art = art
    }

    private func pbr(_ color: UIColor, roughness: CGFloat = 0.9, metalness: CGFloat = 0) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = roughness
        m.metalness.contents = metalness
        return m
    }

    private func bind(_ m: SCNMaterial, _ key: String, _ texture: Any?) {
        guard let texture else { return }
        let p = SCNMaterialProperty(contents: texture)
        p.wrapS = .repeat
        p.wrapT = .repeat
        p.mipFilter = .linear
        m.setValue(p, forKey: key)
    }

    private static func scale(_ sx: Float, _ sy: Float) -> SCNMatrix4 {
        SCNMatrix4MakeScale(sx, sy, 1)
    }

    // MARK: Ground

    /// Maps world (x, z) texture coordinates onto the ortho photo.
    private var orthoTransform: SCNMatrix4 {
        guard let o = bundle.course.ortho else { return SCNMatrix4Identity }
        let sx = Float(1 / o.widthM), sy = Float(1 / o.heightM)
        return SCNMatrix4Mult(SCNMatrix4MakeScale(sx, sy, 1),
                              SCNMatrix4MakeTranslation(Float(-o.originEast) * sx, Float(o.originNorth) * sy, 0))
    }

    private func groundMaterial(geometry: String) -> SCNMaterial {
        let m = pbr(UIColor(red: 0.33, green: 0.42, blue: 0.22, alpha: 1), roughness: 0.95)
        m.diffuse.clamped(textures.ortho(bundle: bundle) ?? WorldTextures.solid(UIColor(red: 0.33, green: 0.42, blue: 0.22, alpha: 1)))
        m.diffuse.contentsTransform = orthoTransform
        // Kept at 1 px per metre above the battery tier, like the ortho.
        let splat = textures.metal("\(bundle.id)_splat", srgb: false, cap: textures.limit > 1024 ? 4096 : nil)
            ?? textures.metal(image: WorldTextures.solid(UIColor(red: 1, green: 0, blue: 0, alpha: 1)), srgb: false)
        bind(m, "splatTex", splat)
        bind(m, "detailTex", textures.metal("cj_ground_detail", srgb: false)
             ?? textures.metal(image: WorldTextures.solid(UIColor(white: 0.5, alpha: 0.5)), srgb: false))
        bind(m, "farTex", textures.metal("cj_farfields", srgb: true)
             ?? textures.metal(image: WorldTextures.solid(UIColor(red: 0.36, green: 0.44, blue: 0.25, alpha: 1)), srgb: true))
        m.setValue(NSNumber(value: config.terrainNormalDetail ? 1.0 : 0.0), forKey: "detailNormals")
        m.shaderModifiers = [.geometry: geometry, .surface: WorldShaders.terrainSurface]
        return m
    }

    lazy var terrain: SCNMaterial = groundMaterial(geometry: WorldShaders.terrainGeometry)
    lazy var verge: SCNMaterial = groundMaterial(geometry: WorldShaders.vergeGeometry)
    var farTerrain: SCNMaterial { terrain }

    // MARK: Road

    private func paved(albedo: String, detail: String, tileU: Float, tileV: Float, mud: Double,
                       normal: Double, fallback: UIColor, brightness: CGFloat = 1) -> SCNMaterial {
        let m = pbr(fallback, roughness: 0.7)
        if let img = textures.image(albedo) {
            m.diffuse.tiled(img)
            m.diffuse.contentsTransform = Self.scale(1 / tileU, 1 / tileV)
            m.diffuse.intensity = brightness
            bind(m, "detailTex", textures.metal(detail, srgb: false)
                 ?? textures.metal(image: WorldTextures.solid(UIColor(red: 0.5, green: 0.5, blue: 0.7, alpha: 1)), srgb: false))
            m.setValue(NSNumber(value: mud), forKey: "mudAmount")
            m.setValue(NSNumber(value: normal), forKey: "normalStrength")
            m.shaderModifiers = [.geometry: WorldShaders.pavedGeometry, .surface: WorldShaders.pavedSurface]
        }
        return m
    }

    lazy var cobbles: SCNMaterial = {
        let m = paved(albedo: "cj_cobble_albedo", detail: "cj_cobble_detail", tileU: 1.08, tileV: 1.08, mud: 1,
                      normal: 1, fallback: UIColor(red: 0.33, green: 0.34, blue: 0.35, alpha: 1))
        if m.shaderModifiers != nil {
            m.shaderModifiers?[.surface] = WorldShaders.cobbleSurface
            let t = art.setts.tint
            m.setValue(NSValue(scnVector4: SCNVector4(t.x, t.y, t.z, t.w)), forKey: "stoneTint")
        }
        return m
    }()
    lazy var asphalt: SCNMaterial = paved(albedo: "cj_asphalt_albedo", detail: "cj_asphalt_detail",
                                          tileU: 2, tileV: 2, mud: 0.3, normal: 0.7,
                                          fallback: UIColor(white: 0.30, alpha: 1))
    /// Side-road versions of the paved materials (see `drapedGeometry`).
    lazy var sideAsphalt: SCNMaterial = draped(asphalt)
    lazy var sideCobbles: SCNMaterial = draped(cobbles)

    private func draped(_ base: SCNMaterial) -> SCNMaterial {
        let m = base.copy() as! SCNMaterial
        if m.shaderModifiers != nil { m.shaderModifiers?[.geometry] = WorldShaders.drapedGeometry }
        return m
    }

    lazy var kerb: SCNMaterial = paved(albedo: "cj_asphalt_albedo", detail: "cj_asphalt_detail",
                                       tileU: 0.7, tileV: 1.3, mud: 0.6, normal: 1,
                                       fallback: UIColor(white: 0.55, alpha: 1), brightness: 1.9)

    /// Pale, weathered concrete with dark joints every `slabM` metres along
    /// the road: concrete-plate lanes (the Stooktestraat) and precast
    /// gutters (the Paterberg).
    private func concrete(slabM: Float, tile: Float, mud: Double, brightness: CGFloat = 2.15) -> SCNMaterial {
        let m = paved(albedo: "cj_asphalt_albedo", detail: "cj_asphalt_detail", tileU: tile, tileV: tile, mud: mud,
                      normal: 0.45, fallback: UIColor(white: 0.6, alpha: 1), brightness: brightness)
        if m.shaderModifiers != nil {
            m.shaderModifiers?[.surface] = WorldShaders.concreteSurface
            m.setValue(NSNumber(value: slabM / tile), forKey: "slabV")
            m.setValue(NSNumber(value: 0.012 / tile), forKey: "jointV")
        }
        return m
    }

    /// Road-marking paint, slightly worn grey-white.
    lazy var roadPaint: SCNMaterial = pbr(UIColor(white: 0.78, alpha: 1), roughness: 0.6)
    /// Red cycle-lane surfacing beside the white edge line.
    lazy var cycleLane: SCNMaterial = {
        let m = paved(albedo: "cj_asphalt_albedo", detail: "cj_asphalt_detail", tileU: 2, tileV: 2, mud: 0.2,
                      normal: 0.6, fallback: UIColor(red: 0.55, green: 0.2, blue: 0.16, alpha: 1), brightness: 1.0)
        if m.shaderModifiers != nil {
            m.shaderModifiers?[.surface] = WorldShaders.tintedPavedSurface
            // About (0.3, 0.05, 0.035) linear: Belgian brick-red cycle lanes.
            m.setValue(NSValue(scnVector3: SCNVector3(5.6, 1.0, 0.72)), forKey: "tint3")
        }
        return m
    }()

    lazy var concrete: SCNMaterial = concrete(slabM: 5, tile: 2, mud: 0.25)
    /// Weathered and dirtier than the lanes: in photos the Paterberg's
    /// gutter is about as light as the setts beside it.
    lazy var gutter: SCNMaterial = concrete(slabM: 1, tile: 0.8, mud: 0.5, brightness: 1.5)

    // MARK: Plants

    private func plant(atlas: String, flutter: Double, wind: Double, translucency: Double,
                       alphaCut: Double, fallback: UIColor) -> SCNMaterial {
        let m = pbr(fallback, roughness: 0.75)
        m.isDoubleSided = true
        if let img = textures.image(atlas) {
            m.diffuse.clamped(img)
        }
        m.setValue(NSNumber(value: wind), forKey: "windStrength")
        m.setValue(NSNumber(value: flutter), forKey: "flutter")
        let s = WorldSun.toSun
        m.setValue(NSValue(scnVector3: SCNVector3(s.x, s.y, s.z)), forKey: "toSun")
        m.setValue(NSNumber(value: translucency), forKey: "translucency")
        m.setValue(NSNumber(value: alphaCut), forKey: "alphaCut")
        m.shaderModifiers = [
            .geometry: WorldShaders.windGeometry,
            .surface: WorldShaders.foliageSurface,
            .fragment: WorldShaders.opaqueFragment,
        ]
        return m
    }

    lazy var leaves: SCNMaterial = plant(atlas: "cj_foliage", flutter: 1, wind: 1, translucency: 0.55,
                                         alphaCut: 0.42, fallback: UIColor(red: 0.2, green: 0.32, blue: 0.1, alpha: 1))
    /// Copper-beech hedges: the leaf atlas tinted purple-red.
    lazy var copperLeaves: SCNMaterial = {
        let m = leaves.copy() as! SCNMaterial
        m.multiply.contents = UIColor(red: 0.52, green: 0.25, blue: 0.3, alpha: 1)
        return m
    }()
    lazy var grass: SCNMaterial = {
        let m = plant(atlas: "cj_grass", flutter: 1.6, wind: 1, translucency: 0.35,
                      alphaCut: 0.4, fallback: UIColor(red: 0.25, green: 0.38, blue: 0.12, alpha: 1))
        m.shaderModifiers?[.geometry] = WorldShaders.grassGeometry
        m.setValue(NSNumber(value: config.grassRadius), forKey: "grassFadeEnd")
        return m
    }()
    lazy var impostor: SCNMaterial = {
        let m = plant(atlas: "cj_impostor", flutter: 0, wind: 0.5, translucency: 0.2,
                      alphaCut: 0.5, fallback: UIColor(red: 0.2, green: 0.3, blue: 0.1, alpha: 1))
        m.shaderModifiers?[.geometry] = WorldShaders.impostorGeometry
        return m
    }()

    lazy var bark: SCNMaterial = {
        let m = pbr(UIColor(red: 0.3, green: 0.26, blue: 0.22, alpha: 1), roughness: 0.9)
        if let img = textures.image("cj_bark_albedo") {
            m.diffuse.tiled(img)
            bind(m, "detailTex", textures.metal("cj_bark_detail", srgb: false))
            m.setValue(NSNumber(value: 1.0), forKey: "normalStrength")
            m.setValue(NSNumber(value: 1.0), forKey: "windStrength")
            m.setValue(NSNumber(value: 0.0), forKey: "flutter")
            m.shaderModifiers = [.geometry: WorldShaders.windGeometry, .surface: WorldShaders.barkSurface]
        }
        return m
    }()

    // MARK: Buildings

    lazy var walls: SCNMaterial = {
        let m = pbr(UIColor(white: 0.8, alpha: 1), roughness: 0.85)
        if let img = textures.image("cj_facade") { m.diffuse.clamped(img) }
        return m
    }()

    private func roof(_ name: String, fallback: UIColor) -> SCNMaterial {
        let m = pbr(fallback, roughness: 0.7)
        m.isDoubleSided = true
        if let img = textures.image(name) {
            m.diffuse.tiled(img)
            bind(m, "detailTex", textures.metal(name + "_detail", srgb: false))
            m.setValue(NSNumber(value: 1.0), forKey: "normalStrength")
            m.shaderModifiers = [.surface: WorldShaders.detailSurface]
        }
        return m
    }

    lazy var roofPantile: SCNMaterial = roof("cj_roof_pantile", fallback: UIColor(red: 0.6, green: 0.3, blue: 0.18, alpha: 1))
    lazy var roofSlate: SCNMaterial = roof("cj_roof_slate", fallback: UIColor(white: 0.18, alpha: 1))

    lazy var darkMetal: SCNMaterial = pbr(UIColor(white: 0.05, alpha: 1), roughness: 0.45, metalness: 0.5)
    lazy var lampGlass: SCNMaterial = pbr(UIColor(white: 0.85, alpha: 1), roughness: 0.2)
    lazy var wood: SCNMaterial = {
        let m = pbr(UIColor(red: 0.34, green: 0.27, blue: 0.2, alpha: 1), roughness: 0.9)
        if let img = textures.image("cj_bark_albedo") {
            m.diffuse.tiled(img)
            m.diffuse.contentsTransform = Self.scale(4, 1)
            m.diffuse.intensity = 1.25
        }
        return m
    }()
    lazy var wire: SCNMaterial = pbr(UIColor(white: 0.25, alpha: 1), roughness: 0.5, metalness: 0.8)
    lazy var whitePaint: SCNMaterial = pbr(UIColor(white: 0.86, alpha: 1), roughness: 0.75)
    lazy var poleConcrete: SCNMaterial = pbr(UIColor(red: 0.6, green: 0.6, blue: 0.58, alpha: 1), roughness: 0.92)
    /// Dark-stained or creosoted timber.
    lazy var darkWood: SCNMaterial = {
        let m = wood.copy() as! SCNMaterial
        m.diffuse.intensity = 0.55
        return m
    }()
    lazy var greyMetal: SCNMaterial = pbr(UIColor(white: 0.42, alpha: 1), roughness: 0.5, metalness: 0.6)

    /// In `BuildingBuilder.PropPart` order.
    var props: [SCNMaterial] {
        [darkMetal, lampGlass, wood, wire, whitePaint, poleConcrete, darkWood, greyMetal]
    }

    /// Ponds: still, open water.
    lazy var water: SCNMaterial = {
        let m = pbr(UIColor(red: 0.02, green: 0.035, blue: 0.03, alpha: 1), roughness: 0.06)
        return m
    }()

    /// Ditches and brooks a metre wide, often under the roadside bushes:
    /// dark, rippled water dimmed where it is covered (see `streamSurface`).
    lazy var stream: SCNMaterial = {
        let m = pbr(UIColor(red: 0.03, green: 0.04, blue: 0.03, alpha: 1), roughness: 0.4)
        m.shaderModifiers = [.geometry: WorldShaders.streamGeometry, .surface: WorldShaders.streamSurface,
                             .fragment: WorldShaders.streamFragment]
        return m
    }()
}

extension WorldTextures {
    private static let device = MTLCreateSystemDefaultDevice()

    /// A bundled texture uploaded with a full mip chain, for sampling in
    /// shader modifiers, once per name however many materials use it. Data
    /// textures come from `.rgbz` files (see
    /// scripts/courses/textures/texlib.py), whose channels are used as
    /// stored; colour ones from JPEG / PNG.
    func metal(_ name: String, srgb: Bool, cap: Int? = nil) -> MTLTexture? {
        gpuTexture("\(name)|\(srgb)|\(cap ?? limit)") {
            if let raw = rawTexture(name, cap: cap) { return raw }
            guard let img = image(name) else { return nil }
            return metal(image: img, srgb: srgb)
        }
    }

    private static let queue = device?.makeCommandQueue()

    /// `<name>.rgbz`: u32 width, u32 height (little-endian), then raw
    /// deflate of RGBA8 rows. Larger than the tier's `limit`, the top mip
    /// levels are dropped. Nil (and `uploadFailed` set) when the GPU work
    /// doesn't complete, e.g. because the app went to the background.
    func rawTexture(_ name: String, cap: Int? = nil) -> MTLTexture? {
        let limit = cap ?? self.limit
        guard let device = Self.device, let queue = Self.queue,
              let url = Bundle.main.url(forResource: name, withExtension: "rgbz")
                ?? Bundle.main.url(forResource: name, withExtension: "rgbz", subdirectory: "CourseTextures"),
              let file = try? Data(contentsOf: url), file.count > 8 else { return nil }
        let w = file.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian) }
        let h = file.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian) }
        guard w > 0, h > 0,
              let pixels = try? (file.subdata(in: 8..<file.count) as NSData).decompressed(using: .zlib) as Data,
              pixels.count == w * h * 4 else { return nil }
        // Mip levels to skip so the largest kept one fits the limit.
        var skip = 0
        while max(w >> skip, h >> skip) > limit, max(w >> skip, h >> skip) > 1 { skip += 1 }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: true)
        desc.usage = .shaderRead
        desc.storageMode = .private
        let kept = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: max(w >> skip, 1),
                                                            height: max(h >> skip, 1), mipmapped: true)
        kept.usage = .shaderRead
        kept.storageMode = .private
        guard let full = device.makeTexture(descriptor: desc),
              let tex = skip == 0 ? full : device.makeTexture(descriptor: kept),
              let staging = pixels.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: pixels.count, options: .storageModeShared) }),
              let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: w * 4, sourceBytesPerImage: w * h * 4,
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: full, destinationSlice: 0,
                  destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.generateMipmaps(for: full)
        if skip > 0 {
            blit.copy(from: full, sourceSlice: 0, sourceLevel: skip, to: tex, destinationSlice: 0,
                      destinationLevel: 0, sliceCount: 1, levelCount: tex.mipmapLevelCount)
        }
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        guard cmd.status == .completed else {
            noteUploadFailed()
            return nil
        }
        return tex
    }

    func metal(image: UIImage, srgb: Bool) -> MTLTexture? {
        guard let device = Self.device, let cg = image.cgImage else { return nil }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .generateMipmaps: true,
            .SRGB: srgb,
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
        ]
        do {
            return try loader.newTexture(cgImage: cg, options: options)
        } catch {
            noteUploadFailed()
            return nil
        }
    }
}
