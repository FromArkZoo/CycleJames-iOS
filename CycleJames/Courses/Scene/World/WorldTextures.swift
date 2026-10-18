import UIKit
import SceneKit
import Metal

/// Texture lookup for the world. Generic material textures are baked by
/// scripts/courses/textures/bake_materials.py into
/// CycleJames/Resources/CourseTextures/ (flattened into the app bundle);
/// course-specific maps (ground-only ortho, splat map) by
/// bake_course_maps.py as `<course-id>_<name>`. Everything has a plain
/// fallback so a missing file never stops a ride.
final class WorldTextures: @unchecked Sendable {
    let limit: Int
    private var cache: [String: UIImage] = [:]
    /// GPU textures by name and colour space, so materials sharing a map
    /// (terrain and verge, asphalt and kerb) share one upload.
    private var gpuCache: [String: MTLTexture] = [:]
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

    /// A bundled texture by base name (e.g. "cj_cobble_albedo"), downscaled
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
    func ortho(bundle: CourseBundle) -> UIImage? {
        if let baked = image("\(bundle.id)_ortho_ground") { return baked }
        guard let url = bundle.orthoURL, let img = UIImage(contentsOfFile: url.path) else { return nil }
        return downscaled(img)
    }

    private func downscaled(_ img: UIImage) -> UIImage {
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
