import SceneKit
import UIKit

/// Buildings, their roofs, street furniture and fences, ponds and streams.
extension WorldMaterials {
    /// cj_facade.jpg, laid out by `BuildingBuilder.emitWall` and sampled by
    /// `WorldShaders.wallSurface` itself (it wraps the blank wall), which
    /// tints and weathers each building and lights it from the light raster.
    /// Without the GPU textures, a plain wall colour: the blank wall's
    /// texcoords run far outside the atlas, so as SceneKit's own diffuse it
    /// would smear one edge texel over every wall. On the Riviera the
    /// Ligurian atlas cj_facade_lig.jpg and its mask (render, shutters);
    /// elsewhere the mask is never read and the grime map stands in for it,
    /// so the argument is always bound.
    func makeWalls() -> SCNMaterial {
        let m = pbr(UIColor(white: 0.8, alpha: 1), roughness: 0.85)
        let lig = art.look.isRiviera
        guard let facade = textures.metal(lig ? "cj_facade_lig" : "cj_facade", srgb: true),
              let grime = textures.metal("cj_grime", srgb: false),
              let mask = lig ? textures.metal("cj_facade_lig_mask", srgb: false) : grime else { return m }
        bind(m, "facadeTex", facade)
        bind(m, "grimeTex", grime)
        bind(m, "facadeMask", mask)
        m.setValue(NSNumber(value: lig ? 1.0 : 0.0), forKey: "riviera")
        bindLight(m)
        m.shaderModifiers = [.geometry: WorldShaders.wallGeometry, .surface: WorldShaders.wallSurface]
        if lig { m.shaderModifiers?[.fragment] = WorldShaders.wallFragment }
        return m
    }

    /// Every roof cover on the cj_roof atlas (`WorldShaders.roofSurface`;
    /// texcoord 1 picks the cover), over a plain fallback colour; on the
    /// Riviera the Ligurian cj_roof_lig (terracotta).
    func roof(fallback: UIColor) -> SCNMaterial {
        let m = pbr(fallback, roughness: 0.7)
        m.isDoubleSided = true
        let lig = art.look.isRiviera
        guard let albedo = textures.metal(lig ? "cj_roof_lig" : "cj_roof", srgb: true),
              let detail = textures.metal(lig ? "cj_roof_lig_detail" : "cj_roof_detail", srgb: false),
              let grime = textures.metal("cj_grime", srgb: false) else { return m }
        bind(m, "roofTex", albedo)
        bind(m, "roofDetail", detail)
        bind(m, "grimeTex", grime)
        m.setValue(NSNumber(value: config.terrainNormalDetail ? 1.0 : 0.0), forKey: "detailNormals")
        m.setValue(NSNumber(value: lig ? 1.0 : 0.0), forKey: "riviera")
        m.shaderModifiers = [.geometry: WorldShaders.roofGeometry, .surface: WorldShaders.roofSurface]
        return m
    }

    func makeRoofPantile() -> SCNMaterial { roof(fallback: UIColor(red: 0.6, green: 0.3, blue: 0.18, alpha: 1)) }

    /// The Riviera has no slate: there part 1 of the roofs is its
    /// greenhouses' glass (`BuildingBuilder.GlassPart`), every roof on part 0.
    func makeRoofSlate() -> SCNMaterial {
        art.look.isRiviera ? makeGreenhouseGlass() : roof(fallback: UIColor(white: 0.3, alpha: 1))
    }

    /// Greenhouse glass and film (`WorldShaders.greenhouseSurface`):
    /// opaque, double-sided (a tunnel's ends and broken houses show their
    /// inner faces), glowing where the sun shines through it. The sky it
    /// mirrors is the sea's (cj_sea_sky.jpg); its inside and the sky are
    /// emission in the scene's radiance, as the sea's (`glassK`).
    func makeGreenhouseGlass() -> SCNMaterial {
        let m = pbr(UIColor(red: 0.62, green: 0.69, blue: 0.67, alpha: 1), roughness: 0.25)
        m.isDoubleSided = true
        let s = WorldSun.toSun
        m.setValue(NSValue(scnVector3: SCNVector3(s.x, s.y, s.z)), forKey: "toSun")
        bind(m, "glassSky", textures.metal("cj_sea_sky", srgb: true)
             ?? textures.metal(image: WorldTextures.solid(UIColor(red: 0.62, green: 0.71, blue: 0.80, alpha: 1)), srgb: true))
        // x: a white board facing the sun (`lightK.x` 4.8 times the
        // calibrated ambient); y: the sky's (that ambient); z: the sky
        // texture's scale.
        let amb = WorldMaterials.envIrradiance
        m.setValue(NSValue(scnVector4: SCNVector4(Float(4.8 * amb), Float(amb), Float(SkyLighting.skyScale), 0)),
                   forKey: "glassK")
        m.shaderModifiers = [.geometry: WorldShaders.greenhouseGeometry, .surface: WorldShaders.greenhouseSurface]
        return m
    }

    /// In `BuildingBuilder.Output.roofs` part order: pantiles, then slate,
    /// sheet and flat roofs (the greenhouses' glass on the Riviera). One
    /// shader and one set of textures for the roofs.
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

    /// On the Riviera the wires are kept a pixel across however far they
    /// are (`WorldShaders.wireGeometry`): the 5-16 mm bundle and telephone
    /// line fell under a pixel on battery (2x scale, no multisampling) and
    /// broke into dashes against the sky.
    func makeWire() -> SCNMaterial {
        let m = pbr(UIColor(white: 0.25, alpha: 1), roughness: 0.5, metalness: 0.8)
        if art.look.isRiviera { m.shaderModifiers = [.geometry: WorldShaders.wireGeometry] }
        return m
    }
    func makeWhitePaint() -> SCNMaterial { pbr(UIColor(white: 0.86, alpha: 1), roughness: 0.75) }
    func makePoleConcrete() -> SCNMaterial { pbr(UIColor(red: 0.6, green: 0.6, blue: 0.58, alpha: 1), roughness: 0.92) }

    func makeDarkWood() -> SCNMaterial {
        let m = wood.copy() as! SCNMaterial
        m.diffuse.intensity = 0.55
        return m
    }

    func makeGreyMetal() -> SCNMaterial { pbr(UIColor(white: 0.42, alpha: 1), roughness: 0.5, metalness: 0.6) }

    /// cj_signs.png (cj_signs_it.png on the Riviera, `WorldLook.signAtlas`):
    /// road signs, street plates, gully grates and the plain paints of a
    /// few props (`BuildingBuilder.SignCell`). Semi-matt
    /// retroreflective sheeting; without the atlas, a pale grey.
    func makeSignFace() -> SCNMaterial {
        let m = pbr(UIColor(white: 0.8, alpha: 1), roughness: 0.5)
        if let img = textures.image(art.look.signAtlas) { m.diffuse.clamped(img) }
        return m
    }

    /// In `BuildingBuilder.PropPart` order.
    var props: [SCNMaterial] {
        [darkMetal, lampGlass, wood, wire, whitePaint, poleConcrete, darkWood, greyMetal, signFace] + roadsideProps
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
