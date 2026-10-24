import SceneKit
import UIKit

/// Paved surfaces: setts, asphalt, kerbs, concrete lanes and gutters, road
/// markings and cycle lanes, and their draped side-road versions.
extension WorldMaterials {
    func paved(albedo: String, detail: String, tileU: Float, tileV: Float, mud: Double,
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
            bindLight(m)
            m.shaderModifiers = [.geometry: WorldShaders.pavedGeometry, .surface: WorldShaders.pavedSurface]
        }
        return m
    }

    /// Each sett surface's course 0 in the far map, before the climb's first
    /// sett course is taken off: the carriageway, the side roads, the
    /// pavements (the paved strips move on from theirs:
    /// `RoadBuilder.pavedVergeCourses`).
    static let settCourseOffsets: [Float] = [0, 1531, 2861]

    /// Procedural setts (`WorldShaders.settSurface`): laid out per pixel
    /// from the road coordinates, so no stone ever repeats; a course's
    /// layout and colours recur only after 4096 courses (`SettFarMap`). The
    /// textures only lend stone grain (bombed per sett), joint grit (the
    /// diffuse), large-scale wear, and the stones' colours as the far road
    /// sees them (`SettFarMap`). `surface` keeps the carriageway (0), the
    /// side roads (1) and the pavements (2), and the climbs, from sharing
    /// setts where their coordinates coincide.
    func setts(geometry: String, surface: Int) -> SCNMaterial {
        let m = pbr(UIColor(red: 0.33, green: 0.32, blue: 0.30, alpha: 1), roughness: 0.8)
        let look = art.setts, style = look.style
        guard let fill = textures.image("cj_sett_fill"),
              let grain = textures.metal("cj_sett_grain", srgb: false),
              let macro = textures.metal("cj_sett_macro", srgb: false),
              let far = textures.settFarMap(style, seed: look.seed) else { return m }
        m.diffuse.tiled(fill)
        m.diffuse.contentsTransform = Self.scale(1 / 0.37, 1 / 0.37)
        bind(m, "grainTex", grain)
        bind(m, "macroTex", macro)
        bind(m, "farTex", far)
        m.setValue(NSNumber(value: 1.0), forKey: "mudAmount")
        m.setValue(NSNumber(value: Float(look.seed * 4 + surface)), forKey: "settSeed")
        // Each surface starts its own courses of the far map; the
        // carriageway's first sett course is the map's first, so the
        // Koppenberg's and the Paterberg's cobbles never repeat a course.
        let courseOffset = Self.settCourseOffsets[surface] - Float(SettFarMap.firstCourse(bundle.route, depth: style.layout.x))
        m.setValue(NSValue(scnVector4: SCNVector4(SettFarMap.span, Float(SettFarMap.courses), courseOffset,
                                                  Float(look.seed * 4))), forKey: "settFar")
        for (key, v) in style.uniforms {
            m.setValue(NSValue(scnVector4: SCNVector4(v.x, v.y, v.z, v.w)), forKey: key)
        }
        m.setValue(NSNumber(value: style.grainNormal), forKey: "grainNormal")
        let sun = WorldSun.toSun
        m.setValue(NSValue(scnVector3: SCNVector3(sun.x, sun.y, sun.z)), forKey: "toSun")
        bindLight(m)
        setSettTier(m, config.quality)
        m.shaderModifiers = [.geometry: geometry, .surface: WorldShaders.settSurface]
        return m
    }

    /// The setts' tier-dependent uniforms: where they fade to the mean, and
    /// their sun shadows.
    func setSettTier(_ m: SCNMaterial, _ q: GraphicsQuality) {
        var lod = CourseArt.SettStyle.lod(q)
        #if DEBUG
        // -cobbleLod near|far: every sett in full, or only the far mean, to
        // check the two match in brightness (`SettStyle.farMatch`).
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-cobbleLod"), i + 1 < args.count {
            lod.x = args[i + 1] == "far" ? -2 : 98
            lod.y = args[i + 1] == "far" ? -1 : 99
        }
        #endif
        m.setValue(NSValue(scnVector4: SCNVector4(lod.x, lod.y, lod.z, lod.w)), forKey: "settLod")
        m.setValue(NSNumber(value: CourseArt.SettStyle.microShadow(q)), forKey: "microShadow")
    }

    /// A live tier step: the setts' tier uniforms on every sett material.
    func applySettTier(_ q: GraphicsQuality) {
        for m in [cobbles, sideCobbles, pavementSetts] { setSettTier(m, q) }
    }

    func makeCobbles() -> SCNMaterial { setts(geometry: WorldShaders.settGeometry, surface: 0) }

    func makeAsphalt() -> SCNMaterial {
        paved(albedo: "cj_asphalt_albedo", detail: "cj_asphalt_detail",
              tileU: 2, tileV: 2, mud: 0.3, normal: 0.7,
              fallback: UIColor(white: 0.30, alpha: 1))
    }

    func makeSideAsphalt() -> SCNMaterial { draped(asphalt) }
    /// Draped cobbled side roads, each laid from its own origin
    /// (`RoadBuilder.buildSideRoads`). Not `draped(_:)`: its geometry
    /// modifier doesn't pass the setts' road coordinates on.
    func makeSideCobbles() -> SCNMaterial { setts(geometry: WorldShaders.drapedSettGeometry, surface: 1) }

    /// Raised sett pavements and the flush paved verges: laid separately
    /// from the carriageway beside them, with no wheel tracks (a paved
    /// strip's u runs from its own middle line, which would put two
    /// polished bands down the paving).
    func makePavementSetts() -> SCNMaterial {
        let m = setts(geometry: WorldShaders.settGeometry, surface: 2)
        let w = art.setts.style.wear
        m.setValue(NSValue(scnVector4: SCNVector4(w.x, 1e-4, 0, w.w)), forKey: "settWear")
        return m
    }

    func draped(_ base: SCNMaterial) -> SCNMaterial {
        let m = base.copy() as! SCNMaterial
        if m.shaderModifiers != nil { m.shaderModifiers?[.geometry] = WorldShaders.drapedGeometry }
        return m
    }

    /// Pale granite or concrete edge stones with a joint every metre:
    /// paler than the setts beside them (photos of all three climbs).
    func makeKerb() -> SCNMaterial { concrete(slabM: 1.0, tile: 0.8, mud: 0.7, brightness: 1.75) }

    /// Pale, weathered concrete with dark joints every `slabM` metres along
    /// the road: concrete-plate lanes (the Stooktestraat) and precast
    /// gutters (the Paterberg).
    func concrete(slabM: Float, tile: Float, mud: Double, brightness: CGFloat = 2.15) -> SCNMaterial {
        let m = paved(albedo: "cj_asphalt_albedo", detail: "cj_asphalt_detail", tileU: tile, tileV: tile, mud: mud,
                      normal: 0.45, fallback: UIColor(white: 0.6, alpha: 1), brightness: brightness)
        if m.shaderModifiers != nil {
            m.shaderModifiers?[.surface] = WorldShaders.concreteSurface
            m.setValue(NSNumber(value: slabM / tile), forKey: "slabV")
            m.setValue(NSNumber(value: 0.012 / tile), forKey: "jointV")
        }
        return m
    }

    func makeRoadPaint() -> SCNMaterial { pbr(UIColor(white: 0.78, alpha: 1), roughness: 0.6) }

    func makeCycleLane() -> SCNMaterial {
        let m = paved(albedo: "cj_asphalt_albedo", detail: "cj_asphalt_detail", tileU: 2, tileV: 2, mud: 0.2,
                      normal: 0.6, fallback: UIColor(red: 0.55, green: 0.2, blue: 0.16, alpha: 1), brightness: 1.0)
        if m.shaderModifiers != nil {
            m.shaderModifiers?[.surface] = WorldShaders.tintedPavedSurface
            // About (0.3, 0.05, 0.035) linear: Belgian brick-red cycle lanes.
            m.setValue(NSValue(scnVector3: SCNVector3(5.6, 1.0, 0.72)), forKey: "tint3")
        }
        return m
    }

    func makeConcrete() -> SCNMaterial { concrete(slabM: 5, tile: 2, mud: 0.25) }
    func makeGutter() -> SCNMaterial { concrete(slabM: 1, tile: 0.8, mud: 0.5, brightness: 1.5) }
}
