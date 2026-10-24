import SceneKit
import CoreGraphics
import simd

/// Kit and bike colours, sRGB 0–1. The brand values mirror `CJColors`
/// (DesignSystem/Colors.swift); they are restated here as plain components
/// because the render thread can't touch SwiftUI colours.
enum RiderPalette {
    static let brandWarm1 = SIMD3<Float>(1.000, 0.784, 0.341) // CJColors.brandWarm1 #FFC857
    static let brandWarm2 = SIMD3<Float>(1.000, 0.549, 0.180) // CJColors.brandWarm2 #FF8C2E
    static let brandWarm3 = SIMD3<Float>(0.914, 0.294, 0.235) // CJColors.brandWarm3 #E94B3C
    static let accent     = SIMD3<Float>(0.000, 0.706, 0.847) // CJColors.accent #00b4d8
    static let navy       = SIMD3<Float>(0.059, 0.204, 0.376) // CJColors.card #0f3460
    static let midnight   = SIMD3<Float>(0.086, 0.129, 0.243) // CJColors.bgSecondary #16213e
    static let ink        = SIMD3<Float>(0.102, 0.102, 0.180) // CJColors.bgPrimary #1a1a2e

    static let skin       = SIMD3<Float>(0.80, 0.57, 0.44)
    static let hair       = SIMD3<Float>(0.17, 0.12, 0.09)
    static let lycraBlack = SIMD3<Float>(0.035, 0.037, 0.045)
    static let white      = SIMD3<Float>(0.93, 0.93, 0.92)
    static let tan        = SIMD3<Float>(0.62, 0.44, 0.26)

    /// Brand gradient (amber → orange → red) at `t ∈ [0, 1]`.
    static func warm(_ t: Float) -> SIMD3<Float> {
        let t = min(max(t, 0), 1)
        return t < 0.5
            ? simd_mix(brandWarm1, brandWarm2, SIMD3(repeating: t * 2))
            : simd_mix(brandWarm2, brandWarm3, SIMD3(repeating: t * 2 - 1))
    }

    static func cg(_ c: SIMD3<Float>, _ a: Float = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: CGFloat(a))
    }
}

/// Small textures painted pixel by pixel at init (no image assets).
enum RiderTexture {
    /// `f(u, v)` returns sRGB colour + alpha. Row 0 is v = 0 (SceneKit's top).
    static func image(_ w: Int, _ h: Int, _ f: (Float, Float) -> SIMD4<Float>) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for r in 0..<h {
            let v = (Float(r) + 0.5) / Float(h)
            for c in 0..<w {
                let u = (Float(c) + 0.5) / Float(w)
                let px = simd_clamp(f(u, v), SIMD4(repeating: 0), SIMD4(repeating: 1))
                let k = (r * w + c) * 4
                bytes[k] = UInt8(px.x * px.w * 255 + 0.5)
                bytes[k + 1] = UInt8(px.y * px.w * 255 + 0.5)
                bytes[k + 2] = UInt8(px.z * px.w * 255 + 0.5)
                bytes[k + 3] = UInt8(px.w * 255 + 0.5)
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func rgb(_ c: SIMD3<Float>, _ a: Float = 1) -> SIMD4<Float> { SIMD4(c, a) }

    /// Distance to a rounded box centred at `c` with half size `h`.
    static func roundBox(_ p: SIMD2<Float>, _ c: SIMD2<Float>, _ h: SIMD2<Float>, _ r: Float) -> Float {
        let q = abs(p - c) - h + SIMD2(repeating: r)
        return length(simd_max(q, .zero)) + min(max(q.x, q.y), 0) - r
    }
}

/// Every material the rider and bike use, created once and shared.
final class RiderMaterials {
    let paint: SCNMaterial
    let carbon: SCNMaterial
    let rubber: SCNMaterial
    let alloy: SCNMaterial
    let steel: SCNMaterial
    let chain: SCNMaterial
    let glove: SCNMaterial
    let bottle: SCNMaterial
    let tyre: SCNMaterial
    let rim: SCNMaterial
    let spokes: SCNMaterial
    let spokeBlur: SCNMaterial

    let jersey: SCNMaterial
    let bib: SCNMaterial
    let thigh: SCNMaterial
    let shank: SCNMaterial
    let sleeve: SCNMaterial
    let skin: SCNMaterial
    let head: SCNMaterial
    let shoe: SCNMaterial
    let helmet: SCNMaterial
    let lens: SCNMaterial
    let frameBlack: SCNMaterial

    /// Every material above, each carrying `skySurface`.
    var all: [SCNMaterial] {
        [paint, carbon, rubber, alloy, steel, chain, glove, bottle, tyre, rim, spokes, spokeBlur,
         jersey, bib, thigh, shank, sleeve, skin, head, shoe, helmet, lens, frameBlack]
    }

    /// The rider's share of the sky light (`RiderRig.setSkyVisibility`):
    /// the image-based light only, so the sun and its shadows are kept.
    /// `riderSky` is 1 in the open; an unset float would read 0 and black
    /// out the ambient.
    static let skySurface = """
    #pragma arguments
    float riderSky;
    #pragma body
    _surface.ambientOcclusion *= riderSky;
    """

    /// Signed distance (metres) to a 7 cm "CJ" monogram centred on `p`
    /// (x right, y up as seen by the viewer).
    static func monogram(_ p: SIMD2<Float>) -> Float {
        let w: Float = 0.0055
        func segment(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            let ab = b - a
            let t = min(max(dot(p - a, ab) / dot(ab, ab), 0), 1)
            return length(p - (a + ab * t))
        }
        // C: a ring open on the right.
        let c = SIMD2<Float>(-0.024, 0), r: Float = 0.028, gap: Float = 0.75
        let dc = p - c
        var dC = abs(length(dc) - r)
        if abs(atan2(dc.y, dc.x)) < gap {
            let e1 = c + SIMD2(cos(gap), sin(gap)) * r, e2 = c + SIMD2(cos(gap), -sin(gap)) * r
            dC = min(length(p - e1), length(p - e2))
        }
        // J: a stem ending in a hook.
        let jx: Float = 0.034, top: Float = 0.030, hookY: Float = -0.012, hr: Float = 0.016
        let dStem = segment(SIMD2(jx, top), SIMD2(jx, hookY))
        let hc = SIMD2<Float>(jx - hr, hookY)
        let dh = p - hc
        let dHook = dh.y <= 0 ? abs(length(dh) - hr) : min(length(p - SIMD2(jx, hookY)), length(p - SIMD2(jx - 2 * hr, hookY)))
        return min(dC, dStem, dHook) - w
    }

    /// Paint atlas regions (u ranges) for the frame tubes.
    enum PaintRegion: Int { case plain = 0, fade, band, badge }

    static func paintUV(_ region: PaintRegion, _ th: Float, _ t: Float) -> SIMD2<Float> {
        let u0 = Float(region.rawValue) * 0.25
        return SIMD2(u0 + 0.03 + 0.19 * (th / (2 * .pi)), t)
    }

    init(quality: GraphicsQuality, layout: RiderBodyLayout) {
        let texScale = quality == .battery ? 1 : 2

        func pbr(_ color: Any, metal: Float, rough: Float, name: String) -> SCNMaterial {
            let m = SCNMaterial()
            m.name = name
            m.lightingModel = .physicallyBased
            m.diffuse.contents = color
            m.metalness.contents = NSNumber(value: metal)
            m.roughness.contents = NSNumber(value: rough)
            m.diffuse.mipFilter = .linear
            m.diffuse.wrapS = .repeat
            m.diffuse.wrapT = .clamp
            return m
        }

        let P = RiderPalette.self

        // Frame paint atlas: plain midnight, fork fade, down-tube band, head-tube badge.
        let paintImg = RiderTexture.image(64 * texScale, 128 * texScale) { u, v in
            let base = simd_mix(P.midnight, P.navy, SIMD3(repeating: 0.35))
            let region = Int(u * 4)
            let lu = (u * 4 - Float(region) - 0.15) / 0.7
            switch region {
            case 1:
                let w = RiderMath.smoothstep(0.35, 0.95, v)
                return RiderTexture.rgb(simd_mix(base, P.warm(0.2 + 0.8 * v), SIMD3(repeating: w)))
            case 2:
                let d = abs(v - 0.55)
                if d < 0.20 {
                    let edge = abs(d - 0.20) < 0.012
                    return RiderTexture.rgb(edge ? P.accent : P.warm((v - 0.35) / 0.4))
                }
                return RiderTexture.rgb(base)
            case 3:
                let front = abs(lu - 0.75) < 0.12 && abs(v - 0.5) < 0.18
                return RiderTexture.rgb(front ? P.warm((v - 0.32) / 0.36) : base)
            default:
                return RiderTexture.rgb(base)
            }
        }
        paint = pbr(paintImg as Any, metal: 0.45, rough: 0.32, name: "rider.paint")
        paint.clearCoat.contents = NSNumber(value: 1.0)
        paint.clearCoatRoughness.contents = NSNumber(value: 0.06)

        carbon = pbr(P.cg(SIMD3(0.045, 0.047, 0.052)), metal: 0.1, rough: 0.32, name: "rider.carbon")
        carbon.clearCoat.contents = NSNumber(value: 0.6)
        carbon.clearCoatRoughness.contents = NSNumber(value: 0.15)
        rubber = pbr(P.cg(SIMD3(0.03, 0.03, 0.032)), metal: 0, rough: 0.82, name: "rider.rubber")
        alloy = pbr(P.cg(SIMD3(0.20, 0.21, 0.23)), metal: 0.85, rough: 0.33, name: "rider.alloy")
        steel = pbr(P.cg(SIMD3(0.62, 0.63, 0.65)), metal: 1.0, rough: 0.28, name: "rider.steel")
        frameBlack = pbr(P.cg(SIMD3(0.02, 0.02, 0.025)), metal: 0.2, rough: 0.25, name: "rider.frameBlack")

        let chainImg = RiderTexture.image(16, 32) { u, v in
            // One 25.4 mm pitch: outer plate, roller, inner plate, roller.
            let side = abs(sin(u * 2 * .pi)) > 0.5
            let roller = abs(v - 0.0) < 0.08 || abs(v - 1.0) < 0.08 || abs(v - 0.5) < 0.08
            var c: SIMD3<Float> = v < 0.5 ? SIMD3(0.30, 0.30, 0.31) : SIMD3(0.20, 0.20, 0.21)
            if roller { c = SIMD3(0.36, 0.36, 0.37) }
            return RiderTexture.rgb(side ? c : c * 0.75)
        }
        chain = pbr(chainImg as Any, metal: 0.85, rough: 0.45, name: "rider.chain")
        chain.diffuse.wrapT = .repeat

        glove = pbr(P.cg(simd_mix(P.midnight, P.ink, SIMD3(repeating: 0.5))), metal: 0, rough: 0.7, name: "rider.glove")

        let bottleImg = RiderTexture.image(8, 64) { _, v in
            if v > 0.86 { return RiderTexture.rgb(SIMD3(0.06, 0.06, 0.07)) }      // cap
            if abs(v - 0.45) < 0.12 { return RiderTexture.rgb(P.warm((v - 0.33) / 0.24)) }
            return RiderTexture.rgb(P.white)
        }
        bottle = pbr(bottleImg as Any, metal: 0, rough: 0.45, name: "rider.bottle")

        // Tyre section: v runs once around the casing, 0.25 = tread.
        let tyreImg = RiderTexture.image(4, 128) { _, v in
            let d = abs(v - 0.25)
            if d < 0.105 { return RiderTexture.rgb(SIMD3(0.035, 0.035, 0.037)) }
            if d < 0.115 { return RiderTexture.rgb(SIMD3(0.02, 0.02, 0.02)) }
            if d > 0.40 { return RiderTexture.rgb(SIMD3(0.03, 0.03, 0.03)) }
            return RiderTexture.rgb(P.tan)
        }
        tyre = pbr(tyreImg as Any, metal: 0, rough: 0.78, name: "rider.tyre")
        tyre.diffuse.wrapT = .repeat

        rim = pbr(P.cg(SIMD3(0.035, 0.036, 0.04)), metal: 0.15, rough: 0.28, name: "rider.rim")
        rim.clearCoat.contents = NSNumber(value: 0.8)
        rim.clearCoatRoughness.contents = NSNumber(value: 0.1)
        spokes = pbr(P.cg(SIMD3(0.05, 0.05, 0.055)), metal: 0.7, rough: 0.35, name: "rider.spokes")

        // Spinning-spoke haze: denser toward the hub, where spokes converge.
        let blurImg = RiderTexture.image(4, 64) { _, v in
            let a = 0.10 + 0.22 * (1 - v) * (1 - v)
            return SIMD4(0.10, 0.10, 0.11, a)
        }
        spokeBlur = SCNMaterial()
        spokeBlur.name = "rider.spokeBlur"
        spokeBlur.lightingModel = .physicallyBased
        spokeBlur.diffuse.contents = blurImg
        spokeBlur.metalness.contents = NSNumber(value: 0.3)
        spokeBlur.roughness.contents = NSNumber(value: 0.5)
        spokeBlur.transparencyMode = .aOne
        spokeBlur.blendMode = .alpha
        spokeBlur.isDoubleSided = true
        spokeBlur.writesToDepthBuffer = false

        // MARK: Kit

        let L = layout
        let jerseyImg = RiderTexture.image(256 * texScale, 256 * texScale) { u, v in
            // u: 0 right side, 0.25 back, 0.5 left, 0.75 front. v: 0 hem → 1 collar.
            let side = min(abs(u - 0.0), abs(u - 1.0), abs(u - 0.5))
            var c = side < 0.055 ? P.midnight : P.navy
            if v > 0.965 { return RiderTexture.rgb(P.brandWarm3) }
            if v > 0.60 && v < 0.80 {
                c = P.warm(1 - (v - 0.60) / 0.20)
            }
            if abs(v - 0.565) < 0.008 { c = P.accent }
            // Full-length zip on the front.
            if abs(u - 0.75) < 0.0035 { c = SIMD3(0.75, 0.75, 0.78) }
            // "CJ" between the shoulder blades, read from behind.
            let lp = SIMD2((0.25 - u) * 0.86, (v - 0.47) * 0.56)
            if abs(lp.x + 0.009) < 0.056 && abs(lp.y) < 0.042 {
                let logo = Self.monogram(lp)
                if logo < 0 { c = P.white } else if logo < 0.0025 { c = simd_mix(c, P.white, SIMD3(repeating: 0.5)) }
            }
            // Three rear pockets with a reflective hem.
            if abs(u - 0.25) < 0.17 && v < 0.24 {
                c = simd_mix(c, P.midnight, SIMD3(repeating: 0.55))
                if abs(v - 0.235) < 0.006 { c = SIMD3(0.72, 0.72, 0.74) }
                if abs(abs(u - 0.25) - 0.057) < 0.003 { c = P.ink }
            }
            return RiderTexture.rgb(c)
        }
        jersey = pbr(jerseyImg as Any, metal: 0, rough: 0.62, name: "rider.jersey")

        let bibImg = RiderTexture.image(128, 64) { u, _ in
            let side = min(abs(u - 0.0), abs(u - 1.0), abs(u - 0.5))
            var c = side < 0.06 ? simd_mix(P.lycraBlack, P.midnight, SIMD3(repeating: 0.6)) : P.lycraBlack
            // Flatlock seams down the centre back and front, and along the panels.
            let seam = min(abs(u - 0.25), abs(u - 0.75), abs(side - 0.06))
            if seam < 0.004 { c = c * 0.55 } else if seam < 0.009 { c = c * 1.35 }
            return RiderTexture.rgb(c)
        }
        bib = pbr(bibImg as Any, metal: 0, rough: 0.56, name: "rider.bib")

        // Banded limb textures: v is metres from the top of the proximal cap / total length.
        // Matching roughness maps keep skin identical across segments, so
        // the joints don't show seams.
        func band(_ total: Float, _ f: @escaping (Float) -> (SIMD3<Float>, Float), name: String) -> SCNMaterial {
            let color = RiderTexture.image(8, 256 * texScale) { _, v in RiderTexture.rgb(f(v * total).0) }
            let rough = RiderTexture.image(8, 128) { _, v in
                let r = f(v * total).1
                return SIMD4(r, r, r, 1)
            }
            let m = pbr(color as Any, metal: 0, rough: 0.55, name: name)
            m.roughness.contents = rough
            m.roughness.wrapS = .repeat
            return m
        }
        let skinRough: Float = 0.55
        thigh = band(L.thighTotal, { s in
            let end = L.thighShortsEnd
            if s < end - 0.035 { return (P.lycraBlack, 0.56) }
            if s < end {
                // Leg gripper with a warm stripe.
                if abs(s - (end - 0.0175)) < 0.005 { return (P.warm(0.5), 0.6) }
                return (P.midnight, 0.6)
            }
            return (P.skin, skinRough)
        }, name: "rider.thigh")

        shank = band(L.shankTotal, { s in
            let sockTop = L.shankSockTop
            if s < sockTop { return (P.skin, skinRough) }
            let d = s - sockTop
            if d < 0.012 { return (P.white, 0.8) }
            if d < 0.040 { return (P.warm((d - 0.012) / 0.028), 0.8) }
            return (P.white, 0.8)
        }, name: "rider.shank")

        sleeve = band(L.upperArmTotal, { s in
            let end = L.sleeveEnd
            if s < end - 0.016 { return (P.navy, 0.62) }
            if s < end { return (P.warm(1 - (s - (end - 0.016)) / 0.016), 0.62) }
            return (P.skin, skinRough)
        }, name: "rider.sleeve")

        skin = pbr(P.cg(P.skin), metal: 0, rough: skinRough, name: "rider.skin")

        let headImg = RiderTexture.image(128 * texScale, 128 * texScale) { u, v in
            // u: 0.25 back, 0.75 face. v: 0 chin → 1 crown.
            let back = cos((u - 0.25) * 2 * .pi)       // 1 at the back, −1 at the face
            let hairline = 0.42 - 0.20 * back           // lower at the back
            if v > hairline && back > -0.45 { return RiderTexture.rgb(P.hair) }
            if v > 0.80 { return RiderTexture.rgb(P.hair) }
            // Lips with a soft parting line, and a touch of colour on the cheeks.
            let du = abs(u - 0.75)
            let across = 1 - RiderMath.smoothstep(0.030, 0.062, du)
            let lips = across * (1 - RiderMath.smoothstep(0.006, 0.026, abs(v - 0.19)))
            let parting = across * (1 - RiderMath.smoothstep(0.0, 0.006, abs(v - 0.192)))
            let cheeks = (1 - RiderMath.smoothstep(0.03, 0.07, abs(du - 0.10))) * (1 - RiderMath.smoothstep(0.03, 0.08, abs(v - 0.40)))
            var c = simd_mix(P.skin, SIMD3(0.80, 0.47, 0.42), SIMD3(repeating: 0.25 * cheeks))
            c = simd_mix(c, SIMD3(0.70, 0.43, 0.39), SIMD3(repeating: 0.55 * lips))
            c *= 1 - 0.30 * parting
            return RiderTexture.rgb(c)
        }
        head = pbr(headImg as Any, metal: 0, rough: skinRough, name: "rider.head")

        // Shoe: v along heel → toe, u around the section (0.75 = sole).
        let shoeImg = RiderTexture.image(128, 128) { u, v in
            let sole = abs(u - 0.75) < 0.19
            if sole { return RiderTexture.rgb(SIMD3(0.05, 0.05, 0.055)) }
            let sideStripe = (abs(u - 0.0) < 0.05 || abs(u - 1.0) < 0.05 || abs(u - 0.5) < 0.05) && v > 0.25 && v < 0.62
            if sideStripe { return RiderTexture.rgb(P.warm(v * 1.6 - 0.4)) }
            return RiderTexture.rgb(P.white)
        }
        shoe = pbr(shoeImg as Any, metal: 0, rough: 0.35, name: "rider.shoe")
        shoe.clearCoat.contents = NSNumber(value: 0.5)

        // Helmet: u around (0.75 = front), v from crown (0) to rim (1).
        let helmetImg = RiderTexture.image(256 * texScale, 128 * texScale) { u, v in
            let p = SIMD2(u, v)
            var vent = Float.greatestFiniteMagnitude
            if v > 0.37 && v < 0.77 {
                // Only the slots near this column can be within the outline width.
                for k in 0..<5 where abs(u - 0.75 - (Float(k) - 2) * 0.042) < 0.03 {    // front slots
                    let cu = 0.75 + (Float(k) - 2) * 0.042
                    vent = min(vent, RiderTexture.roundBox(p, SIMD2(cu, 0.56), SIMD2(0.012, 0.17 - abs(Float(k) - 2) * 0.03), 0.01))
                }
                for k in 0..<4 where abs(u - 0.25 - (Float(k) - 1.5) * 0.05) < 0.03 {   // rear slots
                    let cu = 0.25 + (Float(k) - 1.5) * 0.05
                    vent = min(vent, RiderTexture.roundBox(p, SIMD2(cu, 0.62), SIMD2(0.014, 0.13), 0.012))
                }
                for k in 0..<2 where abs(u - (k == 0 ? 0.04 : 0.46)) < 0.08 {          // side slots
                    let cu: Float = k == 0 ? 0.04 : 0.46
                    vent = min(vent, RiderTexture.roundBox(p, SIMD2(cu, 0.55), SIMD2(0.06, 0.03), 0.02))
                }
            }
            if vent < 0 { return RiderTexture.rgb(SIMD3(0.03, 0.03, 0.035)) }
            if vent < 0.004 { return RiderTexture.rgb(SIMD3(0.55, 0.55, 0.56)) }
            if v > 0.84 && v < 0.92 { return RiderTexture.rgb(P.warm(abs(u - 0.75) * 2)) }
            if v >= 0.92 { return RiderTexture.rgb(P.ink) }
            return RiderTexture.rgb(P.white)
        }
        helmet = pbr(helmetImg as Any, metal: 0, rough: 0.3, name: "rider.helmet")
        helmet.clearCoat.contents = NSNumber(value: 1.0)
        helmet.clearCoatRoughness.contents = NSNumber(value: 0.05)

        let lensImg = RiderTexture.image(8, 64) { _, v in RiderTexture.rgb(P.warm(1 - v)) }
        lens = pbr(lensImg as Any, metal: 0.9, rough: 0.08, name: "rider.lens")
        lens.emission.contents = lensImg
        lens.emission.intensity = 0.18

        // Open sky until the ride says otherwise.
        for m in all {
            m.setValue(NSNumber(value: Float(1)), forKey: "riderSky")
            m.shaderModifiers = [.surface: Self.skySurface]
        }
    }
}
