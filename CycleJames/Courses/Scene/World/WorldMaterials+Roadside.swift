import SceneKit
import UIKit

/// The Riviera's roadside materials (`BuildingBuilder.PropPart` masonry,
/// galvanised, chainLink, shadeNet; `WorldShaders+Roadside`).
extension WorldMaterials {
    /// In `PropPart` order after `signFace`. On a Flemish course plain
    /// stand-ins: nothing there is drawn with them.
    func makeRoadsideProps() -> [SCNMaterial] {
        guard art.look.isRiviera else {
            return [pbr(UIColor(white: 0.6, alpha: 1)), makeGalvanised(), pbr(UIColor(white: 0.5, alpha: 1)),
                    pbr(UIColor(red: 0.2, green: 0.28, blue: 0.23, alpha: 1))]
        }
        return [makeMasonry(), makeGalvanised(), makeChainLink(), makeShadeNet()]
    }

    /// Stone and concrete over cj_stone_lig_detail and cj_concrete_lig_detail
    /// (scripts/courses/textures/bake_roadside.py), weathered with cj_grime,
    /// lit by the light raster. A plain honey stone without the textures.
    func makeMasonry() -> SCNMaterial {
        let m = pbr(UIColor(red: 0.66, green: 0.58, blue: 0.44, alpha: 1), roughness: 0.9)
        guard let stone = textures.metal("cj_stone_lig_detail", srgb: false),
              let concrete = textures.metal("cj_concrete_lig_detail", srgb: false),
              let grime = textures.metal("cj_grime", srgb: false) else { return m }
        bind(m, "stoneDetail", stone)
        bind(m, "concreteDetail", concrete)
        bind(m, "grimeTex", grime)
        bindLight(m)
        m.shaderModifiers = [.geometry: WorldShaders.masonryGeometry, .surface: WorldShaders.masonrySurface]
        return m
    }

    /// Galvanised steel: unpainted, sunlit about #acb6bb, weathered to
    /// #8d9396 (look.md section 3). Double-sided: a guardrail's beam is one
    /// sheet, seen from the hairpin legs below as well.
    func makeGalvanised() -> SCNMaterial {
        let m = pbr(UIColor(red: 0.74, green: 0.77, blue: 0.78, alpha: 1), roughness: 0.45, metalness: 0.75)
        m.isDoubleSided = true
        if let grime = textures.metal("cj_grime", srgb: false) {
            bind(m, "grimeTex", grime)
            m.shaderModifiers = [.surface: WorldShaders.galvanisedSurface]
        }
        return m
    }

    /// Chain-link mesh and balustrade bars, blended over what is behind them
    /// (`chainLinkSurface`).
    func makeChainLink() -> SCNMaterial {
        let m = pbr(UIColor(white: 0.5, alpha: 0.5), roughness: 0.5)
        m.transparencyMode = .aOne
        m.blendMode = .alpha
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.shaderModifiers = [.geometry: WorldShaders.chainLinkGeometry, .surface: WorldShaders.chainLinkSurface]
        return m
    }

    /// Dark-green shade netting, #33473a in the bible, teal-green where the
    /// sun is on it (the 2024 frames at 2130-2160 m): knitted tape blended
    /// over what is behind (`shadeNetSurface`), about three quarters cover.
    /// As an opaque sheet of the paint it read as a near-black hoarding.
    func makeShadeNet() -> SCNMaterial {
        // (0.27/0.4/0.35 read a stop dark, near-black teal, in the 2400-2470
        // eye views against the frames' mid teal-green.)
        let m = pbr(UIColor(red: 0.34, green: 0.5, blue: 0.44, alpha: 0.75), roughness: 0.75)
        m.isDoubleSided = true
        if let grime = textures.metal("cj_grime", srgb: false) {
            bind(m, "grimeTex", grime)
            m.transparencyMode = .aOne
            m.blendMode = .alpha
            m.writesToDepthBuffer = false
            m.shaderModifiers = [.geometry: WorldShaders.shadeNetGeometry, .surface: WorldShaders.shadeNetSurface,
                                 .fragment: WorldShaders.shadeNetFragment]
        }
        return m
    }
}
