import SceneKit

/// The Riviera's air between the eye and what it looks at.
extension WorldShaders {
    /// Aerial perspective, appended to a material's fragment stage
    /// (`WorldMaterials.air`): what is seen fades by the air's
    /// transmittance and takes its light, on the lit colour, in place of
    /// SceneKit's fog (one colour all round, by distance alone).
    ///
    /// The air thins with height: its extinction is 1 / `airLengthM` at
    /// the sea and falls by e every `airScaleHeightM`, so a view along the
    /// water hazes sooner than one up to a ridge. Along a ray climbing dy
    /// over a distance d from a height y0 the optical depth is
    /// (d / L) e^(-y0 / H) (1 - e^(-dy / H)) / (dy / H). At 10 km visibility
    /// length that is 9 % of the air's light at 1 km, 21 % at 2.5 km, 60 %
    /// along the sea at 10 km, 45 % to a ridge 700 m up at the same
    /// distance, and all of it at the sea's horizon.
    ///
    /// The air's light is the horizon's haze in the direction looked
    /// (`WorldLook.airBase`, `airGlow`, `airPower`, from the sky bake): the
    /// blue-grey the far coast fades to, up to twice as bright and whiter
    /// under the sun, where the haze scatters its light forward. The sky's
    /// faces carry the same colours below the horizon, so the far sea meets
    /// them without a seam.
    ///
    /// The air's light is not scaled with the lane exposure
    /// (`SkyLighting.exposure`), which on this coast road never opens up
    /// by more than a fifth of a stop. Names start `cjA`; needs nothing
    /// from the host but `_surface.position` and `_output`.
    static func aerialFragment(_ look: WorldLook) -> String {
        func f(_ v: Double) -> String { String(format: "%.8f", v) }
        func v3(_ v: SIMD3<Double>) -> String { "float3(\(f(v.x)), \(f(v.y)), \(f(v.z)))" }
        let s = WorldSun.toSun
        let h = (Double(s.x) * Double(s.x) + Double(s.z) * Double(s.z)).squareRoot()
        return """
        float cjAd = length(_surface.position);
        float3 cjAv = (scn_frame.inverseViewTransform * float4(_surface.position / max(cjAd, 1e-3), 0.0)).xyz;
        float cjAk = cjAv.y * cjAd * \(f(1 / look.airScaleHeightM));
        float cjAf = abs(cjAk) > 1e-3 ? (1.0 - exp(-cjAk)) / cjAk : 1.0 - 0.5 * cjAk;
        float cjAt = exp(-cjAd * \(f(1 / look.airLengthM)) * exp(-max(scn_frame.inverseViewTransform[3].y, 0.0) * \(f(1 / look.airScaleHeightM))) * cjAf);
        float2 cjAh = cjAv.xz / max(length(cjAv.xz), 1e-4);
        float cjAg = pow(saturate(0.5 + 0.5 * dot(cjAh, float2(\(f(Double(s.x) / h)), \(f(Double(s.z) / h))))), \(f(look.airPower)));
        float3 cjAc = \(v3(look.airBase)) + \(v3(look.airGlow)) * cjAg;
        _output.color.rgb = _output.color.rgb * cjAt + cjAc * ((1.0 - cjAt) * _output.color.a);
        """
    }
}
