import SceneKit
import UIKit
import Metal

/// Plants: leaf cards, hedges, verge grass, distant tree impostors and bark.
extension WorldMaterials {
    /// Every `foliageSurface` argument is set here: an unset one reads 0.
    func plant(atlas: String, flutter: Double, wind: Double, translucency: Double,
               alphaCut: Double, fallback: UIColor) -> SCNMaterial {
        // Fully rough: a card stands for many leaves at all angles, so no
        // single sun reflection; at roughness 0.75 cards bent up towards a
        // low sun glared white.
        let m = pbr(fallback, roughness: 1)
        m.isDoubleSided = true
        var atlasPx = 1024
        if let img = textures.image(atlas) {
            m.diffuse.clamped(img)
            atlasPx = img.cgImage?.width ?? atlasPx
        }
        m.setValue(NSNumber(value: wind), forKey: "windStrength")
        m.setValue(NSNumber(value: flutter), forKey: "flutter")
        let s = WorldSun.toSun
        m.setValue(NSValue(scnVector3: SCNVector3(s.x, s.y, s.z)), forKey: "toSun")
        m.setValue(NSNumber(value: translucency), forKey: "translucency")
        m.setValue(NSNumber(value: alphaCut), forKey: "alphaCut")
        m.setValue(NSNumber(value: Double(atlasPx)), forKey: "atlasPx")
        m.setValue(NSNumber(value: 1.0), forKey: "anisotropy")
        m.setValue(NSNumber(value: 1.0), forKey: "throughCrown")
        m.setValue(NSNumber(value: 1.0), forKey: "exposureGain")
        m.setValue(NSNumber(value: 0.0), forKey: "mipCoverage")
        m.shaderModifiers = [
            .geometry: WorldShaders.windGeometry,
            .surface: WorldShaders.foliageSurface,
            .fragment: WorldShaders.opaqueFragment,
        ]
        return m
    }

    /// The alpha cut follows the level the anisotropic filter samples
    /// (`clamped`: up to 8 samples). Fixed cards (hedge faces, ivy on a
    /// bank) are mostly seen at grazing angles, where a cut raised for the
    /// footprint's long axis ate their crisp leaves to vertical streaks.
    /// Billboards face the viewer, so a crown's cut is as it was.
    func makeLeaves() -> SCNMaterial {
        let m = plant(atlas: art.look.isRiviera ? "cj_foliage_med" : "cj_foliage", flutter: 1, wind: 1, translucency: 0.55,
                      alphaCut: 0.42, fallback: UIColor(red: 0.2, green: 0.32, blue: 0.1, alpha: 1))
        m.setValue(NSNumber(value: Double(m.diffuse.maxAnisotropy)), forKey: "anisotropy")
        if art.look.isRiviera { m.setValue(NSNumber(value: Self.mipCoverageMed.leaves), forKey: "mipCoverage") }
        leafSheen(m)
        return m
    }

    /// The Riviera's leaves and impostors keep their coverage down the mip
    /// chain by scaling the alpha up per level (`foliageSurface`'s
    /// `mipCoverage`) instead of raising the cut: its needles, fronds,
    /// Norfolk Island pine tiers and the impostors' slender boles average
    /// out below a raised cut a few levels down (an Aleppo pine's impostor
    /// lost its bole at level 4, a Norfolk pine's tiers at 4-5), so distant
    /// pines stood as tufts in the air. At these rates the cells of
    /// cj_foliage_med and cj_impostor_med keep their full-size coverage to
    /// level 4 and gain a quarter at most by level 5 (araucaria more).
    static let mipCoverageMed = (leaves: 0.12, impostors: 0.15)

    /// Leaves and impostors keep little of their specular
    /// (`WorldShaders.leafFragment`).
    private func leafSheen(_ m: SCNMaterial) {
        #if DEBUG
        // -leafSheenFull: the full specular, to judge the cut against it in
        // the same build.
        if ProcessInfo.processInfo.arguments.contains("-leafSheenFull") { return }
        #endif
        m.shaderModifiers?[.fragment] = WorldShaders.leafFragment
    }

    func makeGrass() -> SCNMaterial {
        let m = plant(atlas: art.look.isRiviera ? "cj_grass_med" : "cj_grass", flutter: 1.6, wind: 1, translucency: 0.35,
                      alphaCut: 0.4, fallback: UIColor(red: 0.25, green: 0.38, blue: 0.12, alpha: 1))
        m.shaderModifiers?[.geometry] = WorldShaders.grassGeometry
        // The sward strips run on across u (tuft cells keep inside 0...1).
        m.diffuse.wrapS = .repeat
        m.setValue(NSNumber(value: config.grassRadius), forKey: "grassFadeEnd")
        m.setValue(NSNumber(value: 0.0), forKey: "throughCrown")
        return m
    }

    /// Distant trees, lit through their crown normals (`impostorSurface`);
    /// every argument is set here.
    func makeImpostor() -> SCNMaterial {
        let riviera = art.look.isRiviera
        let m = plant(atlas: riviera ? "cj_impostor_med" : "cj_impostor", flutter: 0, wind: 0.5, translucency: 0.2,
                      alphaCut: 0.5, fallback: UIColor(red: 0.2, green: 0.3, blue: 0.1, alpha: 1))
        m.shaderModifiers?[.geometry] = WorldShaders.impostorGeometry
        m.shaderModifiers?[.surface] = WorldShaders.impostorSurface
        if riviera { m.setValue(NSNumber(value: Self.mipCoverageMed.impostors), forKey: "mipCoverage") }
        leafSheen(m)
        let detail = textures.metal(riviera ? "cj_impostor_med_detail" : "cj_impostor_detail", srgb: false)
        m.setValue(NSNumber(value: detail == nil ? 0.0 : 1.0), forKey: "impostorNormals")
        bind(m, "impDetail", detail ?? textures.gpuTexture("impDetail|flat") {
            textures.metal(image: WorldTextures.solid(UIColor(red: 0.5, green: 0.5, blue: 1, alpha: 1)), srgb: false)
        })
        return m
    }

    func makeBark() -> SCNMaterial {
        if art.look.isRiviera { return makeBarkAtlas() }
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
    }

    /// The Riviera's bark: every trunk, palm stem, prickly-pear pad and
    /// agave leaf from one atlas of tiles (cj_bark_med_*, baked by
    /// bake_riviera_plants.py), each vertex's tile in its u
    /// (`TreeArchetype.setBark`; `WorldShaders.barkAtlasSurface`). The
    /// diffuse slot holds the atlas too, so the surface stage has texture
    /// coordinates; the shader samples it per tile.
    func makeBarkAtlas() -> SCNMaterial {
        let m = pbr(UIColor(red: 0.42, green: 0.38, blue: 0.33, alpha: 1), roughness: 0.9)
        guard let img = textures.image("cj_bark_med_albedo") else { return m }
        m.diffuse.tiled(img)
        bind(m, "albedoTex", barkAtlasAlbedo())
        bind(m, "detailTex", textures.metal("cj_bark_med_detail", srgb: false))
        m.setValue(NSNumber(value: 1.0), forKey: "normalStrength")
        m.setValue(NSNumber(value: 1.0), forKey: "windStrength")
        m.setValue(NSNumber(value: 0.0), forKey: "flutter")
        m.shaderModifiers = [.geometry: WorldShaders.windGeometry, .surface: WorldShaders.barkAtlasSurface]
        return m
    }

    /// The bark atlas's colours for `barkAtlasSurface`, which samples them
    /// itself. Within the tier's texture limit, the shared upload. Over it
    /// (battery: 1024 against the atlas's 2048 x 1024), `WorldTextures`
    /// scales the image down in a wide-colour renderer and the loader
    /// keeps that image's encoded values as linear ones, so every trunk
    /// came out pale pinkish white (the stone pine's tile read 0.52 linear
    /// red where the other tiers read 0.24: sRGB 0.24, undecoded;
    /// TreeArchetypeTests `test_rivieraBarkAtlasKeepsItsColourOnEveryTier`).
    /// Here it is drawn at full size into 8-bit sRGB, uploaded as sRGB with
    /// its mips, and the levels over the limit dropped, as `rawTexture`
    /// drops a data map's.
    private func barkAtlasAlbedo() -> MTLTexture? {
        let name = "cj_bark_med_albedo"
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg")
                ?? Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: "CourseTextures"),
              let cg = UIImage(contentsOfFile: url.path)?.cgImage, max(cg.width, cg.height) > textures.limit else {
            return textures.metal(name, srgb: true)
        }
        return textures.gpuTexture("\(name)|srgb8|\(textures.limit)") {
            let (w, h) = (cg.width, cg.height)
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let px = ctx.data else { return nil }
            var skip = 0
            while max(w >> skip, h >> skip) > textures.limit { skip += 1 }
            func texture(_ tw: Int, _ th: Int) -> MTLTexture? {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: max(tw, 1),
                                                                 height: max(th, 1), mipmapped: true)
                d.usage = .shaderRead
                d.storageMode = .private
                return device.makeTexture(descriptor: d)
            }
            guard let full = texture(w, h), let tex = texture(w >> skip, h >> skip),
                  let staging = device.makeBuffer(bytes: px, length: w * h * 4, options: .storageModeShared),
                  let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else { return nil }
            blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: w * 4, sourceBytesPerImage: w * h * 4,
                      sourceSize: MTLSize(width: w, height: h, depth: 1), to: full, destinationSlice: 0,
                      destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.generateMipmaps(for: full)
            blit.copy(from: full, sourceSlice: 0, sourceLevel: skip, to: tex, destinationSlice: 0,
                      destinationLevel: 0, sliceCount: 1, levelCount: tex.mipmapLevelCount)
            blit.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            guard cmd.status == .completed else {
                textures.noteUploadFailed()
                return nil
            }
            return tex
        }
    }
}
