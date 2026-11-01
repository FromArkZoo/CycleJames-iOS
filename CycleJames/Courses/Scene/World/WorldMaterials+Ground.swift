import SceneKit
import UIKit

/// Ground: the terrain and the road verges, over the course's ortho photo.
extension WorldMaterials {
    /// Maps world (x, z) texture coordinates onto the ortho photo.
    var orthoTransform: SCNMatrix4 {
        guard let o = bundle.course.ortho else { return SCNMatrix4Identity }
        let sx = Float(1 / o.widthM), sy = Float(1 / o.heightM)
        return SCNMatrix4Mult(SCNMatrix4MakeScale(sx, sy, 1),
                              SCNMatrix4MakeTranslation(Float(-o.originEast) * sx, Float(o.originNorth) * sy, 0))
    }

    func groundMaterial(geometry: String) -> SCNMaterial {
        let m = pbr(UIColor(red: 0.33, green: 0.42, blue: 0.22, alpha: 1), roughness: 0.95)
        m.diffuse.clamped(textures.ortho(bundle: bundle) ?? WorldTextures.solid(UIColor(red: 0.33, green: 0.42, blue: 0.22, alpha: 1)))
        m.diffuse.contentsTransform = orthoTransform
        // Kept at 1 px per metre above the battery tier, like the ortho.
        let splat = textures.metal("\(bundle.id)_splat", srgb: false, cap: textures.limit > 1024 ? 4096 : nil)
            ?? textures.metal(image: WorldTextures.solid(UIColor(red: 1, green: 0, blue: 0, alpha: 1)), srgb: false)
        bind(m, "splatTex", splat)
        bind(m, "detailTex", textures.metal("cj_ground_detail", srgb: false)
             ?? textures.metal(image: WorldTextures.solid(UIColor(white: 0.5, alpha: 0.5)), srgb: false))
        if art.look.isRiviera {
            // The far grid's own photo beyond the near one, and the
            // Ligurian land past that (`terrainSurfaceRiviera`).
            let photo = farPhoto
            bind(m, "farTex", photo ?? textures.metal(image: WorldTextures.solid(.black), srgb: true))
            m.setValue(NSValue(scnVector4: farUV), forKey: "farUV")
            m.setValue(NSValue(scnVector4: SCNVector4(Self.farPhotoGain, photo == nil ? 0 : 1, 0, 0)), forKey: "farK")
        } else {
            bind(m, "farTex", textures.metal("cj_farfields", srgb: true)
                 ?? textures.metal(image: WorldTextures.solid(UIColor(red: 0.36, green: 0.44, blue: 0.25, alpha: 1)), srgb: true))
        }
        m.setValue(NSNumber(value: config.terrainNormalDetail ? 1.0 : 0.0), forKey: "detailNormals")
        bindLight(m)
        m.shaderModifiers = [.geometry: geometry,
                             .surface: art.look.isRiviera ? WorldShaders.terrainSurfaceRiviera : WorldShaders.terrainSurface]
        if art.look.isRiviera {
            // The land's own haze (`rivieraLandHaze`), not the sea's.
            m.shaderModifiers?[.fragment] = "#pragma body\n" + WorldShaders.rivieraLandHaze
        }
        return m
    }

    /// The far photo's sRGB to the ground's albedo before the detail's
    /// shading (`terrainSurface` darkens it by about 0.78 at a distance):
    /// calibrated so the far land meets the near ortho without a step.
    static let farPhotoGain: Float = 1.0

    func makeTerrain() -> SCNMaterial {
        groundMaterial(geometry: art.look.isRiviera ? WorldShaders.terrainGeometryRiviera : WorldShaders.terrainGeometry)
    }
    /// The verge, with the mud's reflection damped (`vergeFragment`), and
    /// on the Riviera hazed as the land beside it.
    func makeVerge() -> SCNMaterial {
        let m = groundMaterial(geometry: WorldShaders.vergeGeometry)
        m.shaderModifiers?[.fragment] = WorldShaders.vergeFragment
            + (art.look.isRiviera ? "\n" + WorldShaders.rivieraLandHaze : "")
        return m
    }
}
