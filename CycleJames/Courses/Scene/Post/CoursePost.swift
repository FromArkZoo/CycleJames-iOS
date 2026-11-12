import SceneKit
import Metal

/// The Riviera's camera response: a full-screen pass after SceneKit's own
/// rendering that turns the scene's light into a photograph's tones.
///
/// SceneKit's HDR camera maps radiance to the display with an extended
/// Reinhard curve per channel, y = x (1 + x / W^2) / (1 + x), W being the
/// camera's white point (measured with the chart in `WorldDebugShots` at W
/// = 1, 4 and 16; at W = 1 it is the identity, clipped at 1, which is how
/// the Flemish climbs are drawn). A technique's pass is handed the image
/// after that curve, so the Riviera's camera uses W = 16: sixteen times
/// white still fits under 1, nothing clips, and this pass undoes the curve
/// exactly, per channel, to get the scene's radiance back. Bloom, ambient
/// occlusion and the multisample resolve have already happened, in SceneKit,
/// on the unclipped image.
///
/// On that radiance it applies the exposure, the lens's vignetting, and
/// the AgX display transform (Troy Sobotka's, as Blender 4 ships it, in
/// Benjamin Wrensch's polynomial fit): a log encoding of 16.5 stops round
/// middle grey through a sigmoid, so shadows keep their depth, a sunlit wall
/// rolls off towards white instead of clipping to lemon, and bright colours
/// pale as they do on film. A contrast and saturation "look" follows, then
/// a little grain, which also hides the banding of the 8-bit image the
/// pass reads.
///
/// The Metal source is compiled at run time, like SceneKit's shader
/// modifiers: building the app needs no Metal toolchain. If it doesn't
/// compile on a device, `isAvailable` is false and the Riviera keeps the
/// camera and the 8-bit sky the Flemish climbs have.
enum CoursePost {
    /// The white point the Riviera's camera encodes with, and this pass
    /// decodes: AgX's own ceiling, 6.5 stops over middle grey (16.3).
    static let whitePoint: Double = 16

    /// The pass's settings (the technique's symbols).
    struct Settings {
        /// Gain on the scene's radiance before the display transform.
        var exposure = 1.0
        /// The look, in AgX's encoded space: an S-curve about the middle,
        /// v^a / (v^a + (1 - v)^a), its exponent `shadows` below it and
        /// `contrast` above (AgX's own shoulder is long: sunlit render sits
        /// at 0.85 of white without it), then the saturation.
        var contrast = 1.3
        var shadows = 1.1
        var saturation = 1.25
        /// Darkening towards the corners, in stops at the corner.
        var vignette = 0.35
        /// Grain, as a share of the encoded range.
        var grain = 0.012
        /// 0 the photograph; 1 SceneKit's image as handed over; 2 the
        /// decoded radiance, clipped at 1 (the camera the Flemish climbs
        /// have).
        var debug = 0.0

        static var launch: Settings {
            var s = Settings()
            #if DEBUG
            // -postExposure 1.1 -postContrast 1.25 -postSaturation 1.1
            // -postVignette 0 -postGrain 0 -postDebug 2: try a look without
            // a rebuild.
            let args = ProcessInfo.processInfo.arguments
            func value(_ flag: String) -> Double? {
                guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
                return Double(args[i + 1])
            }
            s.exposure = value("-postExposure") ?? s.exposure
            s.contrast = value("-postContrast") ?? s.contrast
            s.shadows = value("-postShadows") ?? s.shadows
            s.saturation = value("-postSaturation") ?? s.saturation
            s.vignette = value("-postVignette") ?? s.vignette
            s.grain = value("-postGrain") ?? s.grain
            s.debug = value("-postDebug") ?? s.debug
            #endif
            return s
        }
    }

    /// False with `-coursePost off` (development): the world through
    /// SceneKit's curve alone.
    static var isEnabled: Bool {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-coursePost"), i + 1 < args.count, args[i + 1] == "off" { return false }
        #endif
        return true
    }

    /// True where the pass can be drawn: enabled, and its Metal source
    /// compiled on this GPU. The Riviera's camera, sky and bloom are set
    /// for the pass only then; without it they are the Flemish climbs'
    /// (SceneKit's own curve at a white point of 1, the 8-bit sky).
    static var isAvailable: Bool { isEnabled && library != nil }

    private static let symbols = ["cjExposure", "cjContrast", "cjShadows", "cjSaturation", "cjVignette", "cjGrain",
                                  "cjWhite", "cjDebug"]

    /// The technique for a view or an offscreen renderer, or nil if the
    /// pass can't be compiled.
    static func technique(_ settings: Settings = .launch) -> SCNTechnique? {
        guard isAvailable, let library else { return nil }
        var inputs: [String: Any] = ["colorSampler": "COLOR"]
        var declared: [String: Any] = [:]
        for name in symbols {
            inputs[name] = name + "Symbol"
            declared[name + "Symbol"] = ["type": "float"]
        }
        let pass: [String: Any] = [
            "draw": "DRAW_QUAD",
            "metalVertexShader": "cj_post_vertex",
            "metalFragmentShader": "cj_post_fragment",
            "inputs": inputs,
            "outputs": ["color": "COLOR"],
        ]
        guard let t = SCNTechnique(dictionary: ["passes": ["cj_post": pass], "sequence": ["cj_post"], "symbols": declared]) else {
            return nil
        }
        t.library = library
        apply(settings, to: t)
        return t
    }

    static func apply(_ s: Settings, to technique: SCNTechnique) {
        let values = [s.exposure, s.contrast, s.shadows, s.saturation, s.vignette, s.grain, whitePoint, s.debug]
        for (name, v) in zip(symbols, values) {
            technique.setValue(NSNumber(value: v), forKeyPath: name + "Symbol")
        }
    }

    /// Compiled once.
    private static let library: MTLLibrary? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            #if DEBUG
            print("course post: the pass did not compile: \(error)")
            #endif
            return nil
        }
    }()

    // MARK: - The curves, as the shader has them (for the tests)

    /// SceneKit's tone curve at white point `w`.
    static func sceneKitCurve(_ x: Double, w: Double = whitePoint) -> Double {
        x * (1 + x / (w * w)) / (1 + x)
    }

    /// Its inverse, in the form that keeps its precision near black.
    static func radiance(_ y: Double, w: Double = whitePoint) -> Double {
        let b = 1 - y
        return 2 * y / (b + (b * b + 4 * y / (w * w)).squareRoot())
    }

    /// AgX's sigmoid on a neutral value: radiance to the encoded display
    /// value (before the look and the decode to linear).
    static func agxEncoded(_ x: Double) -> Double {
        let e = (min(max(log2(max(x, 1e-10)), agxMinEV), agxMaxEV) - agxMinEV) / (agxMaxEV - agxMinEV)
        let e2 = e * e, e4 = e2 * e2
        return 15.5 * e4 * e2 - 40.14 * e4 * e + 31.96 * e4 - 6.868 * e2 * e + 0.4298 * e2 + 0.1191 * e - 0.00232
    }

    static let agxMinEV = -12.47393
    static let agxMaxEV = 4.026069

    // MARK: - Metal

    /// `SCNSceneBuffer` is SceneKit's (scn_metal, which a run-time compile
    /// can't include): the pass reads the time from it, for the grain.
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct SCNSceneBuffer {
        float4x4    viewTransform;
        float4x4    inverseViewTransform;
        float4x4    projectionTransform;
        float4x4    viewProjectionTransform;
        float4x4    viewToCubeTransform;
        float4x4    lastFrameViewProjectionTransform;
        float4      ambientLightingColor;
        float4      fogColor;
        float3      fogParameters;
        float2      inverseResolution;
        float       time;
        float       sinTime;
        float       cosTime;
        float       random01;
        float       motionBlurIntensity;
        float       environmentIntensity;
        float4x4    inverseProjectionTransform;
        float4x4    inverseViewProjectionTransform;
        float2      nearFar;
        float4      viewportSize;
        float4x4    inverseTransposeViewTransform;
        float4      clusterScale;
    };

    struct CJPostVertexIn {
        float4 position [[attribute(0)]];
    };

    struct CJPostVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct CJPostSymbols {
        float cjExposure;
        float cjContrast;
        float cjShadows;
        float cjSaturation;
        float cjVignette;
        float cjGrain;
        float cjWhite;
        float cjDebug;
    };

    vertex CJPostVertexOut cj_post_vertex(CJPostVertexIn in [[stage_in]]) {
        CJPostVertexOut out;
        out.position = in.position;
        out.uv = float2(in.position.x * 0.5 + 0.5, 0.5 - in.position.y * 0.5);
        return out;
    }

    static float cjHash(float2 p) {
        float3 q = fract(float3(p.xyx) * 0.1031);
        q += dot(q, q.yzx + 33.33);
        return fract((q.x + q.y) * q.z);
    }

    static float3 cjAgx(float3 v, float contrast, float shadows, float saturation) {
        const float3x3 inset = float3x3(float3(0.842479062253094, 0.0423282422610123, 0.0423756549057051),
                                        float3(0.0784335999999992, 0.878468636469772, 0.0784336),
                                        float3(0.0792237451477643, 0.0791661274605434, 0.879142973793104));
        const float3x3 outset = float3x3(float3(1.19687900512017, -0.0528968517574562, -0.0529716355144438),
                                         float3(-0.0980208811401368, 1.15190312990417, -0.0980434501171241),
                                         float3(-0.0990297440797205, -0.0989611768448433, 1.15107367264116));
        v = inset * max(v, float3(0.0));
        v = (clamp(log2(max(v, float3(1e-10))), \(agxMinEV), \(agxMaxEV)) - (\(agxMinEV))) / \(agxMaxEV - agxMinEV);
        float3 v2 = v * v;
        float3 v4 = v2 * v2;
        v = 15.5 * v4 * v2 - 40.14 * v4 * v + 31.96 * v4 - 6.868 * v2 * v + 0.4298 * v2 + 0.1191 * v - 0.00232;
        // The look: an S-curve about the middle, then saturation about
        // the luma.
        v = saturate(v);
        float3 a = mix(float3(shadows), float3(contrast), smoothstep(float3(0.3), float3(0.7), v));
        float3 p = pow(v, a);
        v = p / max(p + pow(1.0 - v, a), float3(1e-6));
        float l = dot(v, float3(0.2126, 0.7152, 0.0722));
        v = l + saturation * (v - l);
        return outset * v;
    }

    fragment half4 cj_post_fragment(CJPostVertexOut in [[stage_in]],
                                    constant SCNSceneBuffer& scn_frame [[buffer(0)]],
                                    constant CJPostSymbols& symbols [[buffer(1)]],
                                    texture2d<float, access::sample> colorSampler [[texture(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float3 y = saturate(colorSampler.sample(s, in.uv).rgb);
        if (symbols.cjDebug > 0.5 && symbols.cjDebug < 1.5) { return half4(half3(y), half(1.0)); }
        // SceneKit's curve undone: y = x (1 + x / W^2) / (1 + x).
        float w2 = symbols.cjWhite * symbols.cjWhite;
        float3 b = 1.0 - y;
        float3 x = 2.0 * y / (b + sqrt(b * b + 4.0 * y / w2));
        if (symbols.cjDebug > 1.5) { return half4(half3(saturate(x)), half(1.0)); }
        x *= symbols.cjExposure;
        // The lens: darker towards the corners, by the square of the
        // distance from the centre (1 at a corner).
        float2 d = in.uv - 0.5;
        float r2 = dot(d, d) * 2.0;
        x *= exp2(-symbols.cjVignette * r2 * r2);
        float3 v = cjAgx(x, symbols.cjContrast, symbols.cjShadows, symbols.cjSaturation);
        // Grain, finer than a pixel can band: two hashes for a triangular
        // spread, new every frame.
        float2 px = in.position.xy + fract(scn_frame.time * float2(7.13, 3.71)) * 1024.0;
        float g = cjHash(px) + cjHash(px + 61.7) - 1.0;
        v += g * symbols.cjGrain * (0.35 + 0.65 * saturate(1.0 - v));
        // To linear, for the sRGB target.
        v = pow(saturate(v), float3(2.2));
        return half4(half3(v), half(1.0));
    }
    """
}
