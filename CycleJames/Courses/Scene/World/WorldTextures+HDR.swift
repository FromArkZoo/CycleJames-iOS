import Foundation
import Metal

/// High-dynamic-range cube maps: the Riviera's sky as the camera response
/// (`CoursePost`) needs it, radiance to thousands of times white round the
/// sun where the 8-bit faces stop at 1.6.
extension WorldTextures {
    /// A bundled `<name>.hdrc` decoded: the face size and, face after face
    /// in SceneKit's order (+x, -x, +y, -y, +z, -z), rows top first, its
    /// texels packed as `MTLPixelFormat.rgb9e5Float`. The file is "CJHC",
    /// u32 face size, u32 face count (6), u32 format (1), then raw deflate
    /// (scripts/courses/textures/bake_sky_hdr.py `save_hdr_cube`).
    static func hdrCubeTexels(_ name: String) -> (size: Int, texels: Data)? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "hdrc")
                ?? Bundle.main.url(forResource: name, withExtension: "hdrc", subdirectory: "CourseTextures"),
              let file = try? Data(contentsOf: url), file.count > 16,
              file.prefix(4) == Data("CJHC".utf8) else { return nil }
        func u32(_ at: Int) -> Int {
            file.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian) }
        }
        let n = u32(4), faces = u32(8), format = u32(12)
        guard n > 0, n <= 4096, faces == 6, format == 1,
              let texels = try? (file.subdata(in: 16..<file.count) as NSData).decompressed(using: .zlib) as Data,
              texels.count == n * n * 4 * 6 else { return nil }
        return (n, texels)
    }

    /// `<name>.hdrc` as a cube texture, or nil (not in the bundle, or the
    /// GPU won't take it): the caller falls back to the 8-bit faces.
    func hdrCube(_ name: String) -> MTLTexture? {
        gpuTexture("\(name)|hdrc") {
            guard let device = MTLCreateSystemDefaultDevice(), let cube = Self.hdrCubeTexels(name) else { return nil }
            let d = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgb9e5Float, size: cube.size, mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .shared
            guard let tex = device.makeTexture(descriptor: d) else { return nil }
            let face = cube.size * cube.size * 4
            cube.texels.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                for k in 0..<6 {
                    tex.replace(region: MTLRegionMake2D(0, 0, cube.size, cube.size), mipmapLevel: 0, slice: k,
                                withBytes: b.baseAddress! + k * face, bytesPerRow: cube.size * 4, bytesPerImage: face)
                }
            }
            return tex
        }
    }

    /// One texel of `hdrCubeTexels` as linear RGB (the shared-exponent
    /// format: three 9-bit mantissas and a 5-bit exponent).
    static func rgb9e5(_ v: UInt32) -> SIMD3<Double> {
        let scale = pow(2.0, Double(v >> 27) - 15 - 9)
        return SIMD3(Double(v & 0x1FF), Double((v >> 9) & 0x1FF), Double((v >> 18) & 0x1FF)) * scale
    }
}
