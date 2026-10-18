import UIKit

/// The course's ground photo on the CPU, at about 1 px per metre, for
/// matching placed things (verge grass) to the ground under them. Linear
/// RGB.
struct GroundColor: Sendable {
    private let pixels: [UInt8]
    private let width: Int, height: Int
    private let originEast: Double, originNorth: Double
    private let metresPerPixel: Double

    init?(bundle: CourseBundle) {
        guard let o = bundle.course.ortho else { return nil }
        let url = Bundle.main.url(forResource: "\(bundle.id)_ortho_ground", withExtension: "jpg")
            ?? Bundle.main.url(forResource: "\(bundle.id)_ortho_ground", withExtension: "jpg", subdirectory: "CourseTextures")
            ?? bundle.orthoURL
        guard let url, let img = UIImage(contentsOfFile: url.path)?.cgImage else { return nil }
        let w = max(Int(o.widthM.rounded()), 1), h = max(Int(o.heightM.rounded()), 1)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        pixels = px
        width = w; height = h
        originEast = o.originEast; originNorth = o.originNorth
        metresPerPixel = o.widthM / Double(w)
    }

    private static let decode: [Float] = (0..<256).map { i in
        let c = Float(i) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    /// Linear colour at a point, or nil outside the photo.
    func color(east: Double, north: Double) -> SIMD3<Float>? {
        let x = Int((east - originEast) / metresPerPixel)
        let y = Int((originNorth - north) / metresPerPixel)
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let k = (y * width + x) * 4
        return SIMD3(Self.decode[Int(pixels[k])], Self.decode[Int(pixels[k + 1])], Self.decode[Int(pixels[k + 2])])
    }
}
