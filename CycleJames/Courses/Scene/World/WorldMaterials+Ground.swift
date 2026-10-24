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
        bind(m, "farTex", textures.metal("cj_farfields", srgb: true)
             ?? textures.metal(image: WorldTextures.solid(UIColor(red: 0.36, green: 0.44, blue: 0.25, alpha: 1)), srgb: true))
        m.setValue(NSNumber(value: config.terrainNormalDetail ? 1.0 : 0.0), forKey: "detailNormals")
        bindLight(m)
        m.shaderModifiers = [.geometry: geometry, .surface: WorldShaders.terrainSurface]
        return m
    }

    func makeTerrain() -> SCNMaterial { groundMaterial(geometry: WorldShaders.terrainGeometry) }
    /// The verge, with the mud's reflection damped (`vergeFragment`).
    func makeVerge() -> SCNMaterial {
        let m = groundMaterial(geometry: WorldShaders.vergeGeometry)
        m.shaderModifiers?[.fragment] = WorldShaders.vergeFragment
        return m
    }
}
