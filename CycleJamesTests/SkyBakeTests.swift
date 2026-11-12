import XCTest
import UIKit
@testable import CycleJames

/// The baked skies (scripts/courses/textures/bake_materials.py `bake_sky`)
/// and the Swift side agree. Below the horizon the background faces carry
/// the haze the far terrain fogs to (`SkyLighting.horizon`), so a re-bake
/// that moves the haze without updating the region's `horizonLinear`
/// (from cj_sky_horizon*.json) would show as a bright or dark ring where
/// the terrain meets the sky.
final class SkyBakeTests: XCTestCase {
    /// Mean linear colour of a face's bottom row, as the background shows
    /// it (sRGB-decoded, times the stored scale).
    private func bottomRow(_ name: String) throws -> SIMD3<Double> {
        let textures = WorldTextures(limit: 4096)
        guard let cg = textures.image(name)?.cgImage else {
            throw XCTSkip("\(name) not in the test host bundle")
        }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = px.withUnsafeMutableBytes { buf -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        XCTAssertTrue(drawn, name)
        func linear(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        // The bitmap's rows run top first.
        let row = (h - 1) * w * 4
        var sum = SIMD3<Double>(0, 0, 0)
        for x in 0..<w {
            let k = row + x * 4
            sum += SIMD3(linear(px[k]), linear(px[k + 1]), linear(px[k + 2]))
        }
        return sum / Double(w) * SkyLighting.skyScale
    }

    /// The four side faces' bottom edges look 45 degrees down, and the
    /// bottom face looks straight down: all haze. (The top face's bottom
    /// edge is up in the sky.)
    func test_facesBelowTheHorizonMatchTheFogColour() throws {
        try checkBelowHorizon(look: .flanders)
        XCTAssertEqual(WorldLook.flanders.horizonLinear, SkyLighting.horizonLinear)
    }

    /// The Riviera's sky (the 8-bit faces cj_sky_lig_*, kept for a device
    /// that can't take the HDR cube; scripts/courses/textures/
    /// bake_sky_hdr.py): below the horizon, the light of its air in each
    /// direction (`WorldLook.airBase`, `airGlow`: brighter under the sun),
    /// which the far sea and land fade to. CoursePostTests checks the HDR
    /// cube the same way.
    func test_rivieraFacesBelowTheHorizonMatchItsFogColour() throws {
        try checkBelowHorizon(look: .riviera)
    }

    /// Compass azimuths (radians) along a face's bottom row, as
    /// bake_materials.py `cube_dirs` lays the faces out, z mirrored as the
    /// Riviera's bake has it.
    private func bottomRowAzimuths(_ face: String, count: Int) -> [Double] {
        (0..<count).map { i in
            let u = (Double(i) + 0.5) / Double(count) * 2 - 1
            switch face {
            case "px": return atan2(1, -u)
            case "nx": return atan2(-1, u)
            case "pz": return atan2(u, 1)
            case "nz": return atan2(-u, -1)
            default: return atan2(u, -1)
            }
        }
    }

    private func checkBelowHorizon(look: WorldLook) throws {
        for face in ["px", "nx", "pz", "nz", "ny"] {
            let name = "\(look.skyPrefix)_\(face)"
            let got = try bottomRow(name)
            var want = look.horizonLinear
            if look.isRiviera {
                // The row's mean of the air's light by direction.
                let sun = WorldSun.azimuthDeg * .pi / 180
                let az = bottomRowAzimuths(face, count: 256)
                want = az.reduce(SIMD3<Double>(0, 0, 0)) { sum, a in
                    sum + look.airBase + look.airGlow * pow(0.5 + 0.5 * cos(a - sun), look.airPower)
                } / Double(az.count)
            }
            for c in 0..<3 {
                XCTAssertEqual(got[c], want[c], accuracy: want[c] * (look.isRiviera ? 0.03 : 0.02),
                               "\(name) channel \(c): \(got) against the horizon's \(want)")
            }
        }
    }
}
