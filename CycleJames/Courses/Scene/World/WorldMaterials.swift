import SceneKit
import UIKit
import MetalKit

/// Materials for the course environment. All physically based; detail comes
/// from baked textures (see `WorldTextures`) and the shader modifiers in
/// `WorldShaders`. Every material is shared by all the geometry that uses
/// it, so each shader is compiled once.
///
/// Each material is made on first use by its `makeX()`, in the extension
/// for its part of the world (`WorldMaterials+Ground`, `+Road`, `+Plants`
/// and `+Buildings`); `WorldMaterials+Light` binds the course's light
/// raster; `WorldMaterials+Live` lists them for the warm-up and applies
/// live tier steps.
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

    func pbr(_ color: UIColor, roughness: CGFloat = 0.9, metalness: CGFloat = 0) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = roughness
        m.metalness.contents = metalness
        return m
    }

    func bind(_ m: SCNMaterial, _ key: String, _ texture: Any?) {
        guard let texture else { return }
        let p = SCNMaterialProperty(contents: texture)
        p.wrapS = .repeat
        p.wrapT = .repeat
        p.mipFilter = .linear
        m.setValue(p, forKey: key)
    }

    static func scale(_ sx: Float, _ sy: Float) -> SCNMatrix4 {
        SCNMatrix4MakeScale(sx, sy, 1)
    }

    // MARK: Light

    /// The course's baked light raster (`WorldMaterials+Light`).
    lazy var lightRaster: MTLTexture? = makeLightRaster()

    // MARK: Ground

    lazy var terrain: SCNMaterial = makeTerrain()
    lazy var verge: SCNMaterial = makeVerge()
    var farTerrain: SCNMaterial { terrain }

    // MARK: Road

    lazy var cobbles: SCNMaterial = makeCobbles()
    lazy var asphalt: SCNMaterial = makeAsphalt()
    /// Side-road versions of the paved materials (see `drapedGeometry`).
    lazy var sideAsphalt: SCNMaterial = makeSideAsphalt()
    lazy var sideCobbles: SCNMaterial = makeSideCobbles()
    /// Raised sett pavements beside the road.
    lazy var pavementSetts: SCNMaterial = makePavementSetts()
    lazy var kerb: SCNMaterial = makeKerb()
    /// Road-marking paint, slightly worn grey-white.
    lazy var roadPaint: SCNMaterial = makeRoadPaint()
    /// Red cycle-lane surfacing beside the white edge line.
    lazy var cycleLane: SCNMaterial = makeCycleLane()
    lazy var concrete: SCNMaterial = makeConcrete()
    /// Weathered and dirtier than the lanes: in photos the Paterberg's
    /// gutter is about as light as the setts beside it.
    lazy var gutter: SCNMaterial = makeGutter()

    // MARK: Plants

    lazy var leaves: SCNMaterial = makeLeaves()
    lazy var grass: SCNMaterial = makeGrass()
    lazy var impostor: SCNMaterial = makeImpostor()
    lazy var bark: SCNMaterial = makeBark()

    // MARK: Buildings

    lazy var walls: SCNMaterial = makeWalls()
    lazy var roofPantile: SCNMaterial = makeRoofPantile()
    lazy var roofSlate: SCNMaterial = makeRoofSlate()

    lazy var darkMetal: SCNMaterial = makeDarkMetal()
    lazy var lampGlass: SCNMaterial = makeLampGlass()
    lazy var wood: SCNMaterial = makeWood()
    lazy var wire: SCNMaterial = makeWire()
    lazy var whitePaint: SCNMaterial = makeWhitePaint()
    lazy var poleConcrete: SCNMaterial = makePoleConcrete()
    /// Dark-stained or creosoted timber.
    lazy var darkWood: SCNMaterial = makeDarkWood()
    lazy var greyMetal: SCNMaterial = makeGreyMetal()
    lazy var signFace: SCNMaterial = makeSignFace()
    /// The Riviera's roadside: masonry, galvanised steel, chain-link, shade
    /// net (`WorldMaterials+Roadside`).
    lazy var roadsideProps: [SCNMaterial] = makeRoadsideProps()

    /// Ponds: still, open water.
    lazy var water: SCNMaterial = makeWater()
    /// Ditches and brooks a metre wide, often under the roadside bushes:
    /// dark, rippled water dimmed where it is covered (see `streamSurface`).
    lazy var stream: SCNMaterial = makeStream()
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
    /// deflate of RGBA8 rows (decoded by `rawPixels`, or handed in already
    /// decoded: `takePixels`). Larger than the tier's `limit`, the top mip
    /// levels are dropped. Nil (and `uploadFailed` set) when the GPU work
    /// doesn't complete, e.g. because the app went to the background.
    func rawTexture(_ name: String, cap: Int? = nil) -> MTLTexture? {
        let limit = cap ?? self.limit
        guard let device = Self.device, let queue = Self.queue, let raw = takePixels(name) else { return nil }
        let (w, h, pixels) = (raw.width, raw.height, raw.rgba)
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
