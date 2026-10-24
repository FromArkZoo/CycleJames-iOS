import SceneKit
import UIKit

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
        let m = plant(atlas: "cj_foliage", flutter: 1, wind: 1, translucency: 0.55,
                      alphaCut: 0.42, fallback: UIColor(red: 0.2, green: 0.32, blue: 0.1, alpha: 1))
        m.setValue(NSNumber(value: Double(m.diffuse.maxAnisotropy)), forKey: "anisotropy")
        leafSheen(m)
        return m
    }

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
        let m = plant(atlas: "cj_grass", flutter: 1.6, wind: 1, translucency: 0.35,
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
        let m = plant(atlas: "cj_impostor", flutter: 0, wind: 0.5, translucency: 0.2,
                      alphaCut: 0.5, fallback: UIColor(red: 0.2, green: 0.3, blue: 0.1, alpha: 1))
        m.shaderModifiers?[.geometry] = WorldShaders.impostorGeometry
        m.shaderModifiers?[.surface] = WorldShaders.impostorSurface
        leafSheen(m)
        let detail = textures.metal("cj_impostor_detail", srgb: false)
        m.setValue(NSNumber(value: detail == nil ? 0.0 : 1.0), forKey: "impostorNormals")
        bind(m, "impDetail", detail ?? textures.gpuTexture("impDetail|flat") {
            textures.metal(image: WorldTextures.solid(UIColor(red: 0.5, green: 0.5, blue: 1, alpha: 1)), srgb: false)
        })
        return m
    }

    func makeBark() -> SCNMaterial {
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
}
