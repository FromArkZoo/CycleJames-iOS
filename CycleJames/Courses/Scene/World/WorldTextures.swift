import UIKit
import SceneKit
import Metal

/// Texture lookup for the world. The generic textures are baked into
/// CycleJames/Resources/CourseTextures/ (flattened into the app bundle) by
/// the scripts in scripts/courses/textures/: bake_materials.py (ground,
/// asphalt, plants, facades, far fields, sky), bake_setts.py (the setts'
/// grain, joint fill and wear), bake_buildings.py (the roof atlas and the
/// walls' and roofs' grime) and bake_signs.py (the sign atlas and its map).
/// Course-specific maps (ground-only ortho, splat map) come from
/// bake_course_maps.py and the light raster from bake_light_maps.py, as
/// `<course-id>_<name>`. Everything has a plain fallback so a missing file
/// never stops a ride.
final class WorldTextures: @unchecked Sendable {
    /// Decoded RGBA8 pixels: width, height and rows, north first.
    typealias Pixels = (width: Int, height: Int, rgba: Data)

    let limit: Int
    private var cache: [String: UIImage] = [:]
    /// GPU textures by name and colour space, so materials sharing a map
    /// (terrain and verge, asphalt and kerb) share one upload.
    private var gpuCache: [String: MTLTexture] = [:]
    /// `.rgbz` files already decoded for this build, by name (`adopt`).
    private var decoded: [String: Pixels] = [:]
    private var _uploadFailed = false
    private let lock = NSLock()

    init(limit: Int) {
        self.limit = limit
    }

    /// True once a GPU upload has failed (Metal refuses work from a
    /// backgrounded app); the textures made from this instance are suspect.
    var uploadFailed: Bool {
        lock.lock(); defer { lock.unlock() }
        return _uploadFailed
    }

    func noteUploadFailed() {
        lock.lock(); _uploadFailed = true; lock.unlock()
    }

    /// The cached GPU texture for `key`, or `make()`'s, cached when it works.
    func gpuTexture(_ key: String, make: () -> MTLTexture?) -> MTLTexture? {
        lock.lock()
        if let hit = gpuCache[key] { lock.unlock(); return hit }
        lock.unlock()
        guard let tex = make() else { return nil }
        lock.lock(); gpuCache[key] = tex; lock.unlock()
        return tex
    }

    /// A bundled texture by base name (e.g. "cj_sett_fill"), downscaled
    /// to the tier's size limit. Nil when it isn't in the bundle.
    func image(_ name: String) -> UIImage? {
        lock.lock()
        if let hit = cache[name] { lock.unlock(); return hit }
        lock.unlock()
        var found: UIImage?
        for ext in ["jpg", "png"] {
            let url = Bundle.main.url(forResource: name, withExtension: ext)
                ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "CourseTextures")
            if let url, let img = UIImage(contentsOfFile: url.path) {
                found = downscaled(img)
                break
            }
        }
        if let found {
            lock.lock(); cache[name] = found; lock.unlock()
        }
        return found
    }

    /// The course's own ortho photo, preferring the baked ground-only one.
    ///
    /// Above the battery tier's limit it may be larger than `limit`: about
    /// 0.75 m per pixel, up to 4096, so a long course (the 2.9 km Oude
    /// Kwaremont) keeps the ground detail of a short one.
    func ortho(bundle: CourseBundle) -> UIImage? {
        // Cached like `image(_:)`: the terrain and verge materials share one
        // image, and so one GPU texture.
        let key = "ortho|\(bundle.id)"
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        var cap = limit
        if limit > 1024, let o = bundle.course.ortho {
            cap = max(limit, min(4096, Int((max(o.widthM, o.heightM) / 0.75).rounded(.up))))
        }
        let name = "\(bundle.id)_ortho_ground"
        var source: UIImage?
        for ext in ["jpg", "png"] where source == nil {
            if let url = Bundle.main.url(forResource: name, withExtension: ext)
                ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "CourseTextures") {
                source = UIImage(contentsOfFile: url.path)
            }
        }
        if source == nil, let url = bundle.orthoURL { source = UIImage(contentsOfFile: url.path) }
        guard let source else { return nil }
        let img = downscaled(source, to: cap)
        lock.lock(); cache[key] = img; lock.unlock()
        return img
    }

    private func downscaled(_ img: UIImage, to cap: Int? = nil) -> UIImage {
        let limit = cap ?? self.limit
        guard let cg = img.cgImage else { return img }
        let w = cg.width, h = cg.height
        let longest = max(w, h)
        guard longest > limit else { return img }
        let f = Double(limit) / Double(longest)
        let nw = max(Int(Double(w) * f), 1), nh = max(Int(Double(h) * f), 1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = cg.alphaInfo == .none || cg.alphaInfo == .noneSkipLast || cg.alphaInfo == .noneSkipFirst
        let out = UIGraphicsImageRenderer(size: CGSize(width: nw, height: nh), format: format).image { _ in
            img.draw(in: CGRect(x: 0, y: 0, width: nw, height: nh))
        }
        return out
    }

    /// A 1 x 1 image of a colour, for fallbacks.
    static func solid(_ c: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { ctx in
            c.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    /// A bundled `<name>.rgbz` (the format `rawTexture` documents)
    /// decoded: width, height and RGBA8 rows, north first, for the CPU or
    /// for `rawTexture` to upload. Nil when it isn't in the bundle or
    /// doesn't decode.
    static func rawPixels(_ name: String) -> Pixels? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "rgbz")
                ?? Bundle.main.url(forResource: name, withExtension: "rgbz", subdirectory: "CourseTextures"),
              let file = try? Data(contentsOf: url), file.count > 8 else { return nil }
        let w = file.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian) }
        let h = file.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian) }
        guard w > 0, h > 0,
              let rgba = try? (file.subdata(in: 8..<file.count) as NSData).decompressed(using: .zlib) as Data,
              rgba.count == w * h * 4 else { return nil }
        #if DEBUG
        decodeLock.lock(); decodeCounts[name, default: 0] += 1; decodeLock.unlock()
        #endif
        return (w, h, rgba)
    }

    /// Hands in `<name>.rgbz` already decoded (`CourseWorldBuilder` decodes
    /// the light raster once, for the plants and the lane meter too), for
    /// `rawTexture` to upload in place of decoding the file again.
    func adopt(_ pixels: Pixels?, as name: String) {
        guard let pixels else { return }
        lock.lock(); decoded[name] = pixels; lock.unlock()
    }

    /// `<name>.rgbz` decoded: the pixels handed in (`adopt`), let go of
    /// here so this object doesn't keep them, or else the file's.
    func takePixels(_ name: String) -> Pixels? {
        lock.lock()
        let handed = decoded.removeValue(forKey: name)
        lock.unlock()
        return handed ?? Self.rawPixels(name)
    }

    /// Once the world is built: the materials hold the images and GPU
    /// textures they use, and the rest go now rather than staying for the
    /// ride (the live tier steps keep the materials, and so this object):
    /// the images that were only uploaded (cj_facade's 2048 px among them)
    /// and anything handed in and not taken.
    func releaseCaches() {
        lock.lock()
        cache = [:]
        gpuCache = [:]
        decoded = [:]
        lock.unlock()
    }

    #if DEBUG
    nonisolated(unsafe) private static var decodeCounts: [String: Int] = [:]
    private static let decodeLock = NSLock()

    /// How often `<name>.rgbz` has been decoded in this run (the world log
    /// counts the light raster's).
    static func decodes(_ name: String) -> Int {
        decodeLock.lock(); defer { decodeLock.unlock() }
        return decodeCounts[name, default: 0]
    }
    #endif
}

extension SCNMaterialProperty {
    /// Repeating, mipmapped, anisotropic.
    func tiled(_ contents: Any?) {
        self.contents = contents
        wrapS = .repeat
        wrapT = .repeat
        mipFilter = .linear
        minificationFilter = .linear
        magnificationFilter = .linear
        maxAnisotropy = 8
    }

    func clamped(_ contents: Any?) {
        self.contents = contents
        wrapS = .clamp
        wrapT = .clamp
        mipFilter = .linear
        minificationFilter = .linear
        magnificationFilter = .linear
        maxAnisotropy = 8
    }
}
