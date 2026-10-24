import SceneKit
import UIKit

/// Buildings, their roofs, street furniture and fences, ponds and streams.
extension WorldMaterials {
    /// cj_facade.jpg, laid out by `BuildingBuilder.emitWall` and sampled by
    /// `WorldShaders.wallSurface` itself (it wraps the blank wall), which
    /// tints and weathers each building and lights it from the light raster.
    /// Without the GPU textures, a plain wall colour: the blank wall's
    /// texcoords run far outside the atlas, so as SceneKit's own diffuse it
    /// would smear one edge texel over every wall.
    func makeWalls() -> SCNMaterial {
        let m = pbr(UIColor(white: 0.8, alpha: 1), roughness: 0.85)
        guard let facade = textures.metal("cj_facade", srgb: true),
              let grime = textures.metal("cj_grime", srgb: false) else { return m }
        bind(m, "facadeTex", facade)
        bind(m, "grimeTex", grime)
        bindLight(m)
        m.shaderModifiers = [.geometry: WorldShaders.wallGeometry, .surface: WorldShaders.wallSurface]
        return m
    }

    /// Every roof cover on the cj_roof atlas (`WorldShaders.roofSurface`;
    /// texcoord 1 picks the cover), over a plain fallback colour.
    func roof(fallback: UIColor) -> SCNMaterial {
        let m = pbr(fallback, roughness: 0.7)
        m.isDoubleSided = true
        guard let albedo = textures.metal("cj_roof", srgb: true),
              let detail = textures.metal("cj_roof_detail", srgb: false),
              let grime = textures.metal("cj_grime", srgb: false) else { return m }
        bind(m, "roofTex", albedo)
        bind(m, "roofDetail", detail)
        bind(m, "grimeTex", grime)
        m.setValue(NSNumber(value: config.terrainNormalDetail ? 1.0 : 0.0), forKey: "detailNormals")
        m.shaderModifiers = [.geometry: WorldShaders.roofGeometry, .surface: WorldShaders.roofSurface]
        return m
    }

    func makeRoofPantile() -> SCNMaterial { roof(fallback: UIColor(red: 0.6, green: 0.3, blue: 0.18, alpha: 1)) }
    func makeRoofSlate() -> SCNMaterial { roof(fallback: UIColor(white: 0.3, alpha: 1)) }

    /// In `BuildingBuilder.Output.roofs` part order: pantiles, then slate,
    /// sheet and flat roofs. One shader and one set of textures.
    var roofParts: [SCNMaterial] {
        [roofPantile, roofSlate]
    }

    func makeDarkMetal() -> SCNMaterial { pbr(UIColor(white: 0.05, alpha: 1), roughness: 0.45, metalness: 0.5) }
    func makeLampGlass() -> SCNMaterial { pbr(UIColor(white: 0.85, alpha: 1), roughness: 0.2) }

    func makeWood() -> SCNMaterial {
        let m = pbr(UIColor(red: 0.34, green: 0.27, blue: 0.2, alpha: 1), roughness: 0.9)
        if let img = textures.image("cj_bark_albedo") {
            m.diffuse.tiled(img)
            m.diffuse.contentsTransform = Self.scale(4, 1)
            m.diffuse.intensity = 1.25
        }
        return m
    }

    func makeWire() -> SCNMaterial { pbr(UIColor(white: 0.25, alpha: 1), roughness: 0.5, metalness: 0.8) }
    func makeWhitePaint() -> SCNMaterial { pbr(UIColor(white: 0.86, alpha: 1), roughness: 0.75) }
    func makePoleConcrete() -> SCNMaterial { pbr(UIColor(red: 0.6, green: 0.6, blue: 0.58, alpha: 1), roughness: 0.92) }

    func makeDarkWood() -> SCNMaterial {
        let m = wood.copy() as! SCNMaterial
        m.diffuse.intensity = 0.55
        return m
    }

    func makeGreyMetal() -> SCNMaterial { pbr(UIColor(white: 0.42, alpha: 1), roughness: 0.5, metalness: 0.6) }

    /// cj_signs.png: road signs, street plates, gully grates and the plain
    /// paints of a few props (`BuildingBuilder.SignCell`). Semi-matt
    /// retroreflective sheeting; without the atlas, a pale grey.
    func makeSignFace() -> SCNMaterial {
        let m = pbr(UIColor(white: 0.8, alpha: 1), roughness: 0.5)
        if let img = textures.image("cj_signs") { m.diffuse.clamped(img) }
        return m
    }

    /// In `BuildingBuilder.PropPart` order.
    var props: [SCNMaterial] {
        [darkMetal, lampGlass, wood, wire, whitePaint, poleConcrete, darkWood, greyMetal, signFace]
    }

    func makeWater() -> SCNMaterial {
        let m = pbr(UIColor(red: 0.02, green: 0.035, blue: 0.03, alpha: 1), roughness: 0.06)
        return m
    }

    func makeStream() -> SCNMaterial {
        let m = pbr(UIColor(red: 0.03, green: 0.04, blue: 0.03, alpha: 1), roughness: 0.4)
        m.shaderModifiers = [.geometry: WorldShaders.streamGeometry, .surface: WorldShaders.streamSurface,
                             .fragment: WorldShaders.streamFragment]
        return m
    }
}
