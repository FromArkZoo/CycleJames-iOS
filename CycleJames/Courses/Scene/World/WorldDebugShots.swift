#if DEBUG
import SceneKit
import UIKit
import Metal

/// Development aid: renders views of the finished world offscreen, from its
/// own simple cameras, before the world is handed to the scene view. Lets the
/// environment be judged without the rider and camera rigs, and survives
/// other processes driving the Simulator.
///
///     -worldShots /abs/dir            enable; PNGs are written there
///     -worldShotList 150:chase,590:broadcast,760:back
///                                     distances and views (chase, broadcast,
///                                     back, high, top, sun, plan, plan30,
///                                     graze, eye, strip<metres>); default
///                                     covers the climb
///     -worldShotTag v3                file name suffix
enum WorldDebugShots {
    struct Spec {
        let s: Double
        let view: String
    }

    static var directory: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-worldShots"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func specs() -> [Spec] {
        let args = ProcessInfo.processInfo.arguments
        let list: String
        if let i = args.firstIndex(of: "-worldShotList"), i + 1 < args.count {
            list = args[i + 1]
        } else {
            list = "150:chase,330:chase,590:chase,760:chase,760:back,900:chase,330:broadcast,590:broadcast,900:broadcast"
        }
        return list.split(separator: ",").compactMap { item in
            let parts = item.split(separator: ":")
            guard let s = Double(parts.first ?? "") else { return nil }
            return Spec(s: s, view: parts.count > 1 ? String(parts[1]) : "chase")
        }
    }

    static var tag: String {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-worldShotTag"), i + 1 < args.count { return "_" + args[i + 1] }
        return ""
    }

    /// Views from the road are exposed as a rider settled there would see
    /// them (`LaneExposure`, applied with `setExposure`); the calibration,
    /// map and high views stay at exposure 0, and so does the scene after.
    static func run(scene: SCNScene, route: CourseRoute, quality: GraphicsQuality,
                    configure: (SCNCamera) -> Void, frame: FrameUpdater, dir: String,
                    terrainHeight: (Float, Float) -> Float,
                    light: LightProfile = .open, setExposure: (Float) -> Void = { _ in }) {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.autoenablesDefaultLighting = false
        let camNode = SCNNode()
        let camera = SCNCamera()
        configure(camera)
        camera.fieldOfView = 62
        camera.projectionDirection = .vertical
        camNode.camera = camera
        scene.rootNode.addChildNode(camNode)
        renderer.pointOfView = camNode
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let size = CGSize(width: 603, height: 1311)
        var t: TimeInterval = 1
        var report = ""
        for spec in specs() {
            setExposure(0)
            if spec.view.hasPrefix("litchart") || spec.view.hasPrefix("litgraze") {
                // Lighting calibration: a horizontal board of patches
                // (physically based and Lambert, two albedos), seen from
                // above at about 25 degrees; "-nosun" hides the sun so only
                // the ambient light remains.
                let sunNode = scene.rootNode.childNode(withName: "sun", recursively: false)
                let noSun = spec.view.hasSuffix("nosun")
                sunNode?.isHidden = noSun
                let eyeH: Float = spec.view.hasPrefix("litgraze") ? 0.3 : 1.6
                camNode.simdPosition = SIMD3(0, 600 + eyeH, 0)
                camNode.simdLook(at: SIMD3(0, 600, -3.4), up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
                let board = litChart()
                board.simdPosition = SIMD3(0, 600, 0)
                scene.rootNode.addChildNode(board)
                frame.update(camera: SIMD3(0, 601.6, 0), time: t)
                _ = renderer.snapshot(atTime: t, with: CGSize(width: 64, height: 128), antialiasingMode: .none)
                t += 0.5
                let img = renderer.snapshot(atTime: t, with: size, antialiasingMode: .none)
                t += 0.5
                board.removeFromParentNode()
                sunNode?.isHidden = false
                let name = "w_0_\(spec.view)_\(quality.rawValue)\(tag).png"
                if let data = img.pngData() {
                    try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
                }
                continue
            }
            if spec.view.hasPrefix("chart") || spec.view == "zenith" {
                // Variants switch parts of the camera's look off:
                // chart-nobloom, chart-nolut, chart-nocontrast, chart-raw.
                configure(camera)
                if spec.view.hasSuffix("nobloom") || spec.view.hasSuffix("raw") { camera.bloomIntensity = 0 }
                if spec.view.hasSuffix("nolut") || spec.view.hasSuffix("raw") { camera.colorGrading.contents = nil }
                if spec.view.hasSuffix("nocontrast") || spec.view.hasSuffix("raw") { camera.contrast = 0 }
                if spec.view.hasSuffix("raw") { camera.vignettingIntensity = 0; camera.screenSpaceAmbientOcclusionIntensity = 0 }
                // Tone-curve calibration: unlit patches of known linear
                // radiance (see `chart`), or the sky straight up, from high
                // above the course.
                camNode.simdPosition = SIMD3(0, 600, 0)
                let isChart = spec.view.hasPrefix("chart")
                let target: SIMD3<Float> = isChart ? SIMD3(0, 600, -10) : SIMD3(0, 700, -0.001)
                camNode.simdLook(at: target, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
                let board = isChart ? chart() : nil
                if let board {
                    board.simdPosition = SIMD3(0, 600, -2)
                    scene.rootNode.addChildNode(board)
                }
                _ = renderer.snapshot(atTime: t, with: CGSize(width: 64, height: 128), antialiasingMode: .none)
                t += 0.5
                let img = renderer.snapshot(atTime: t, with: size, antialiasingMode: .none)
                t += 0.5
                board?.removeFromParentNode()
                configure(camera)
                camera.fieldOfView = 62
                let name = "w_0_\(spec.view)_\(quality.rawValue)\(tag).png"
                if let data = img.pngData() {
                    try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
                }
                continue
            }
            if spec.view.hasPrefix("strip"), let length = Double(spec.view.dropFirst(5)) {
                // The road straight down for `length` metres from s, 6 m
                // across, unrolled into one image (far end at the top), 40
                // px/m: scripts/courses/debug/sett_repeat.py finds a repeat
                // anywhere along it. Orthographic tiles 3 m long, each
                // square to the road at its middle; the near plane cuts away
                // anything over the road.
                let tile = 3.0, pxm = 40.0
                let n = Int(length / tile)
                let size = CGSize(width: 6 * pxm, height: tile * pxm)
                let clip = (camera.zNear, camera.zFar)
                camera.usesOrthographicProjection = true
                camera.orthographicScale = tile / 2
                camera.zNear = 18.5
                camera.zFar = 21.5
                var tiles: [UIImage] = []
                for i in 0..<n {
                    let p = route.pose(at: spec.s + (Double(i) + 0.5) * tile, lateral: 0)
                    let f = simd_normalize(SIMD3(p.forward.x, 0, p.forward.z))
                    camNode.simdPosition = p.position + SIMD3(0, 20, 0)
                    camNode.simdLook(at: p.position, up: f, localFront: SIMD3(0, 0, -1))
                    frame.update(camera: camNode.simdPosition, time: t)
                    tiles.append(renderer.snapshot(atTime: t, with: size, antialiasingMode: .multisampling4X))
                    t += 0.1
                }
                configure(camera)
                camera.fieldOfView = 62
                camera.usesOrthographicProjection = false
                (camera.zNear, camera.zFar) = clip
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let strip = UIGraphicsImageRenderer(size: CGSize(width: size.width, height: size.height * CGFloat(n)),
                                                    format: format).image { _ in
                    for (i, img) in tiles.enumerated() {
                        img.draw(in: CGRect(x: 0, y: size.height * CGFloat(n - 1 - i), width: size.width, height: size.height))
                    }
                }
                let name = "w_\(Int(spec.s))_\(spec.view)_\(quality.rawValue)\(tag).png"
                if let data = strip.pngData() {
                    try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
                }
                continue
            }
            let pose = route.pose(at: spec.s, lateral: 0.4)
            let fwdH = simd_normalize(SIMD3(pose.forward.x, 0, pose.forward.z))
            let right = pose.right
            let eye: SIMD3<Float>
            let target: SIMD3<Float>
            switch spec.view {
            case "broadcast":
                eye = pose.position + right * 6.5 + fwdH * 5 + SIMD3(0, 1.9, 0)
                target = pose.position + SIMD3(0, 1.0, 0) - fwdH * 1.5
            case "back":
                eye = route.pose(at: spec.s + 6, lateral: 0.2).position + SIMD3(0, 2.4, 0)
                target = route.pose(at: spec.s - 60).position + SIMD3(0, 3, 0)
            case "sun":
                // Looking towards the sun: its disc in the baked sky must sit
                // where the light comes from (shadows run towards the camera).
                let ts = WorldSun.toSun
                eye = pose.position + SIMD3(0, 2.0, 0)
                target = eye + simd_normalize(SIMD3(ts.x, ts.y * 0.6, ts.z)) * 20
            case "top":
                // Straight down from 110 m, north up: every footprint near
                // this distance should show as a roof.
                eye = pose.position + SIMD3(0, 110, 0)
                target = pose.position + SIMD3(0, 0, -0.01)
            case "high":
                eye = pose.position - fwdH * 30 + SIMD3(0, 28, 0)
                target = route.pose(at: spec.s + 40).position
            case "plan", "plan30":
                // Straight down on the road, which runs up the frame: from 6 m
                // about 3.3 x 7.2 m (182 px/m: setts, joints, any tile repeat;
                // scripts/courses/debug/sett_repeat.py); from 30 m about
                // 17 x 36 m (the 10-100 m variation).
                let h: Float = spec.view == "plan" ? 6 : 30
                eye = route.pose(at: spec.s, lateral: 0).position + SIMD3(0, h, 0)
                target = route.pose(at: spec.s, lateral: 0).position
            case "graze":
                // Low along the lane, 40 m of road ahead: where a repeat would
                // show as a rhythm, and where the setts fade to their mean.
                eye = pose.position - fwdH * 2 + SIMD3(0, 1.2, 0)
                target = route.pose(at: spec.s + 40).position + SIMD3(0, 0.4, 0)
            case "eye":
                // A photographer standing in the road, landscape and a
                // normal lens, looking 20 m up the road and 4 m above it:
                // to set beside a photo taken from the same spot.
                eye = pose.position + SIMD3(0, 1.6, 0)
                target = route.pose(at: spec.s + 20).position + SIMD3(0, 4.0, 0)
            default:
                eye = pose.position - fwdH * 5.2 + SIMD3(0, 2.3, 0)
                target = route.pose(at: spec.s + 14).position + SIMD3(0, 1.1, 0)
            }
            // Keep the debug camera above the ground (the sunken lane); the
            // graze view is meant to be low.
            var eyeY = eye
            let ground = Float(terrainHeight(eye.x, -eye.z))
            if ground.isFinite, spec.view != "graze" { eyeY.y = max(eye.y, ground + 1.6) }
            camNode.simdPosition = eyeY
            let up: SIMD3<Float> = spec.view == "top" ? SIMD3(0, 0, -1) : spec.view.hasPrefix("plan") ? fwdH : SIMD3(0, 1, 0)
            camNode.simdLook(at: target, up: up, localFront: SIMD3(0, 0, -1))
            let ev = ["top", "high", "plan", "plan30"].contains(spec.view) ? 0 : LaneExposure.target(at: spec.s, profile: light)
            setExposure(ev)
            frame.update(camera: eyeY, time: t)
            let photo = spec.view == "eye"
            camera.fieldOfView = photo ? 46 : 62
            // Two frames so streamed grass and LOD settle.
            _ = renderer.snapshot(atTime: t, with: CGSize(width: 64, height: 128), antialiasingMode: .none)
            t += 0.5
            let img = renderer.snapshot(atTime: t, with: photo ? CGSize(width: 1140, height: 900) : size,
                                        antialiasingMode: quality == .battery ? .none : .multisampling4X)
            t += 0.5
            camera.fieldOfView = 62
            // Whole metres; a fraction kept (330.08:chase, a step of half a
            // course, to compare two frames for shimmer).
            let at = spec.s == spec.s.rounded() ? "\(Int(spec.s))" : "\(spec.s)"
            let name = "w_\(at)_\(spec.view)_\(quality.rawValue)\(tag).png"
            if let data = img.pngData() {
                try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
            report += "\(name): ~\(visibleTriangles(scene: scene, renderer: renderer, camera: camNode)) triangles in view, exposure \(String(format: "%+.2f", ev)) EV\n"
        }
        setExposure(0)
        camNode.removeFromParentNode()
        try? report.write(to: URL(fileURLWithPath: dir).appendingPathComponent("triangles_\(quality.rawValue)\(tag).txt"),
                          atomically: true, encoding: .utf8)
    }

    /// Linear radiances of the calibration chart, row by row (5 per row,
    /// top row first): greys, then colours as (r, g, b) chroma times a
    /// luminance. Kept in step with scripts/courses/textures/read_chart.py.
    static let chartRows: [(SIMD3<Float>, [Float])] = [
        (SIMD3(1, 1, 1), [0.0, 0.01, 0.03, 0.06, 0.1]),
        (SIMD3(1, 1, 1), [0.15, 0.22, 0.32, 0.45, 0.6]),
        (SIMD3(1, 1, 1), [0.8, 1.0, 1.3, 1.7, 2.5]),
        (SIMD3(0.47, 1.1, 2.7), [0.1, 0.2, 0.3, 0.45, 0.6]),
        (SIMD3(0.47, 1.1, 2.7), [0.8, 1.0, 1.3, 1.7, 2.5]),
        (SIMD3(0.9, 1.0, 1.2), [0.2, 0.4, 0.6, 0.8, 1.0]),
        (SIMD3(1.2, 1.15, 0.4), [0.04, 0.08, 0.15, 0.3, 0.5]),
        (SIMD3(2.2, 0.62, 0.4), [0.05, 0.1, 0.2, 0.4, 0.8]),
    ]

    /// Unlit patches, 0.18 m square, 1.0 m wide by 1.7 m tall.
    static func chart() -> SCNNode {
        let node = SCNNode()
        for (row, (chroma, lums)) in chartRows.enumerated() {
            for (col, y) in lums.enumerated() {
                let plane = SCNPlane(width: 0.18, height: 0.18)
                let m = SCNMaterial()
                m.lightingModel = .constant
                m.diffuse.contents = UIColor(white: 1, alpha: 1)
                m.emission.contents = UIColor.black
                plane.materials = [m]
                // White diffuse scaled per channel by multiply, overall by
                // intensity (linear).
                let c = chroma * y
                let peak = max(c.x, c.y, c.z, 1e-6)
                func enc(_ v: Float) -> CGFloat {
                    CGFloat(v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055)
                }
                m.multiply.contents = UIColor(red: enc(c.x / peak), green: enc(c.y / peak), blue: enc(c.z / peak), alpha: 1)
                m.diffuse.intensity = CGFloat(peak)
                let p = SCNNode(geometry: plane)
                p.simdPosition = SIMD3(Float(col) * 0.2 - 0.4, 0.75 - Float(row) * 0.2, 0)
                node.addChildNode(p)
            }
        }
        node.enumerateHierarchy { n, _ in n.castsShadow = false }
        return node
    }

    /// Columns: PBR roughness 1; the same with ambient occlusion 0.5 set
    /// in a surface modifier; the same with `_surface.specular` zeroed;
    /// Lambert. Rows near to far (z -1.6 to -5.2): albedo 0.5 then 0.18,
    /// twice. "litgraze" views it from 0.3 m up.
    static func litChart() -> SCNNode {
        let node = SCNNode()
        let albedos: [CGFloat] = [0.5, 0.18, 0.5, 0.18]
        for (row, a) in albedos.enumerated() {
            for col in 0..<4 {
                let plane = SCNPlane(width: 0.42, height: 0.7)
                let m = SCNMaterial()
                if col < 3 {
                    m.lightingModel = .physicallyBased
                    m.roughness.contents = 1.0
                    m.metalness.contents = 0.0
                    if col == 1 { m.shaderModifiers = [.surface: "_surface.ambientOcclusion = 0.5;"] }
                    if col == 2 { m.shaderModifiers = [.surface: "_surface.specular = float4(0.0, 0.0, 0.0, 1.0);"] }
                } else {
                    m.lightingModel = .lambert
                }
                // Albedo given in linear terms.
                let enc = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055
                m.diffuse.contents = UIColor(white: enc, alpha: 1)
                plane.materials = [m]
                let p = SCNNode(geometry: plane)
                p.eulerAngles.x = -.pi / 2
                p.simdPosition = SIMD3(Float(col) * 0.48 - 0.72, 0, -1.6 - Float(row) * 0.9)
                p.castsShadow = false
                node.addChildNode(p)
            }
        }
        return node
    }

    /// Triangles SceneKit would draw from this camera: nodes whose bounds
    /// meet the frustum, at the level of detail their distance selects.
    static func visibleTriangles(scene: SCNScene, renderer: SCNRenderer, camera: SCNNode) -> Int {
        var total = 0
        let eye = camera.simdWorldPosition
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let g = node.geometry, !node.isHidden, renderer.isNode(node, insideFrustumOf: camera) else { return }
            let (c, _) = node.boundingSphere
            let centre = node.simdConvertPosition(SIMD3(Float(c.x), Float(c.y), Float(c.z)), to: nil)
            let d = CGFloat(simd_distance(centre, eye))
            var geo = g
            for lod in g.levelsOfDetail ?? [] where d >= lod.worldSpaceDistance {
                if let lg = lod.geometry { geo = lg }
            }
            total += geo.elements.reduce(0) { $0 + $1.primitiveCount }
        }
        return total
    }
}
#endif
