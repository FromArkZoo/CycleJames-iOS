import SceneKit
import UIKit

/// The sea and the far photo the Riviera's land and shallows are drawn
/// from. Made by `CourseWorldBuilder` only for a course that has a sea (or
/// the Riviera look), so the Flemish worlds hold none of it.
extension WorldMaterials {
    /// The course's aerial photo over the far grid (north up, exactly the
    /// far grid's footprint, about 2.5 m per pixel; the pipeline's
    /// `<id>_ortho_far.jpg`), or nil.
    var farPhoto: MTLTexture? {
        guard bundle.course.terrain.far != nil else { return nil }
        return textures.metal("\(bundle.id)_ortho_far", srgb: true)
    }

    /// World (x, z) to the far photo's uv as `xz * xy + zw` (scene z points
    /// south), like `lightUV` over the near grid.
    var farUV: SCNVector4 {
        guard let f = bundle.course.terrain.far else { return SCNVector4(0, 0, 0, 0) }
        let w = f.cellM * Double(f.cols), h = f.cellM * Double(f.rows)
        return SCNVector4(Float(1 / w), Float(1 / h), Float(-f.originEast / w), Float(f.originNorth / h))
    }

    /// The sea (`WorldShaders.seaSurface`), unlit: its shader works out the
    /// light itself. Opaque and level; the node casts no shadow.
    func makeSea() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor(red: 0.2, green: 0.36, blue: 0.52, alpha: 1)
        m.isDoubleSided = false
        bind(m, "seaWaves", textures.metal("cj_sea_detail", srgb: false)
             ?? textures.metal(image: WorldTextures.solid(UIColor(red: 0.5, green: 0.5, blue: 0, alpha: 1)), srgb: false))
        bind(m, "seaSky", textures.metal("cj_sea_sky", srgb: true)
             ?? textures.metal(image: WorldTextures.solid(UIColor(red: 0.62, green: 0.71, blue: 0.80, alpha: 1)), srgb: true))
        let photo = farPhoto
        bind(m, "seaPhoto", photo ?? textures.metal(image: WorldTextures.solid(.black), srgb: true))
        m.setValue(NSValue(scnVector4: farUV), forKey: "seaPhotoUV")
        // x: the sun's irradiance (a white board facing it reads 4.8 times
        // the calibrated ambient of 0.454, `lightK`); y: white water's
        // radiance in that sun and sky (albedo 0.7); z: the photo is
        // there; w: its gain from the photo's sRGB to the water's own
        // radiance (the aerial camera saw the sea at about this level).
        let sun = 4.8 * WorldMaterials.envIrradiance * Double.pi
        m.setValue(NSValue(scnVector4: SCNVector4(Float(sun), 1.2, photo == nil ? 0 : 1, 0.55)), forKey: "seaK")
        let s = WorldSun.toSun
        m.setValue(NSValue(scnVector3: SCNVector3(s.x, s.y, s.z)), forKey: "lightSun")
        m.setValue(NSNumber(value: 1.0), forKey: "exposureGain")
        var debug = 0.0
        #if DEBUG
        // -seaDebug 1: the sea one flat colour; 2: (texels per pixel / 100,
        // the waves' share in the roughness, Fresnel) as colour; 9: the
        // screen in four bands (water, sky reflection, glitter, mode 2).
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-seaDebug"), i + 1 < args.count, let v = Double(args[i + 1]) { debug = v }
        #endif
        m.setValue(NSNumber(value: debug), forKey: "seaDebug")
        m.shaderModifiers = [.geometry: WorldShaders.seaGeometry, .surface: WorldShaders.seaSurface]
        return m
    }

    /// Up-facing irradiance / pi of the calibrated lighting environment
    /// (bake_materials.py `ENV_IRRADIANCE`; both regions' bakes keep it).
    static let envIrradiance = 0.454
}
