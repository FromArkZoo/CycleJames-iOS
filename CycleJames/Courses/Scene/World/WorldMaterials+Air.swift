import SceneKit

/// The region's air on the world's materials (`WorldShaders.aerialFragment`).
extension WorldMaterials {
    /// True where the materials draw the air themselves and SceneKit's fog
    /// is off: the Riviera.
    var drawsAir: Bool { art.look.isRiviera }

    /// Appends the air to a material's fragment stage, after whatever it
    /// does there already. Once per material (`aired`).
    func air(_ m: SCNMaterial) {
        guard drawsAir else { return }
        let snippet = WorldShaders.aerialFragment(art.look)
        if let has = m.shaderModifiers?[.fragment] {
            guard !has.contains("cjAd") else { return }
            m.shaderModifiers?[.fragment] = has + "\n" + snippet
        } else {
            var mods = m.shaderModifiers ?? [:]
            mods[.fragment] = "#pragma body\n" + snippet
            m.shaderModifiers = mods
        }
    }

    /// Every material of the world, copies included: on the Riviera each
    /// must draw the air (one that doesn't stands out unhazed at any
    /// distance).
    var everyMaterial: [SCNMaterial] {
        warmUp + props + [water, stream]
    }

    /// The air on all of them (`CourseWorldBuilder`, once they are made).
    func airEverything() {
        guard drawsAir else { return }
        for m in everyMaterial { air(m) }
    }
}
