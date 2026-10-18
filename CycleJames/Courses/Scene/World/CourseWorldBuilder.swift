import SceneKit
import UIKit
import QuartzCore

/// Builds the 3D environment for a course: LiDAR terrain with the road and
/// its verges fitted into it, sky and sun, vegetation and buildings from the
/// scenery file. Runs off the main thread; independent parts build in
/// parallel.
///
/// Cancelling the calling task stops the build within a chunk of work: the
/// builders check `Task.isCancelled` in their long loops and return early,
/// and the stages here throw `CancellationError` between them.
enum CourseWorldBuilder {
    /// Returns once the app is no longer in the background. Metal refuses
    /// command buffers from a backgrounded app, so GPU uploads wait for this.
    static func waitForForeground() async throws {
        while await MainActor.run(body: { UIApplication.shared.applicationState == .background }) {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    static func build(
        bundle: CourseBundle,
        quality: GraphicsQuality,
        progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> CourseWorld {
        let started = CACurrentMediaTime()
        #if DEBUG
        WorldCrashLog.install()
        #endif
        var log = WorldBuildLog(quality: quality)
        let config = WorldConfig.make(quality)
        progress(0.02, "Reading the map")

        let corridor = RoadCorridor(bundle: bundle, vergeWidth: config.vergeWidth)
        try Task.checkCancellation()
        log.mark("corridor")
        progress(0.1, "Shaping the hills")

        let scenery = bundle.scenery
        async let nearChunks = TerrainBuilder.buildNear(corridor: corridor, config: config)
        async let farChunks = TerrainBuilder.buildFar(corridor: corridor, config: config)
        async let roadMeshes = RoadBuilder.build(corridor: corridor, coarse: quality == .battery)
        async let plants = VegetationBuilder.build(corridor: corridor, scenery: scenery, config: config,
                                                   ground: config.grassDensity > 0 ? GroundColor(bundle: bundle) : nil)
        // The canopy raster is decoded for this build only (`CourseBundle.canopy`).
        async let houses = BuildingBuilder.build(corridor: corridor, scenery: scenery, canopy: bundle.canopy)
        async let sideRoads = RoadBuilder.buildSideRoads(corridor: corridor, scenery: scenery,
                                                         reach: config.terrain1mRadius - 4)

        // Textures and materials load while the meshes build. Their GPU
        // uploads need the app in the foreground; if it left part way
        // through, an upload failed and they are made again on return.
        var textures: WorldTextures
        var materials: WorldMaterials
        var attempts = 0
        repeat {
            try await waitForForeground()
            textures = WorldTextures(limit: config.textureLimit)
            materials = WorldMaterials(config: config, textures: textures, bundle: bundle)
            for m in [materials.terrain, materials.verge, materials.cobbles, materials.asphalt, materials.kerb,
                      materials.leaves, materials.bark, materials.impostor, materials.grass, materials.walls,
                      materials.roofPantile, materials.roofSlate] {
                _ = m
            }
            attempts += 1
            #if DEBUG
            if textures.uploadFailed { print("world textures: GPU upload failed (attempt \(attempts)), retrying") }
            #endif
            try Task.checkCancellation()
        } while textures.uploadFailed && attempts < 3
        let scene = SCNScene()
        let sun = SkyLighting.install(in: scene, config: config, textures: textures)
        log.mark("sky, textures, materials")

        let near = await nearChunks
        let far = await farChunks
        try Task.checkCancellation()
        log.mark("terrain meshes (wait)")
        progress(0.45, "Laying the cobbles")
        let road = await roadMeshes
        try Task.checkCancellation()
        progress(0.6, "Planting the hedges")
        let veg = await plants
        try Task.checkCancellation()
        progress(0.75, "Building the houses")
        let town = await houses
        try Task.checkCancellation()
        log.mark("road, plants, buildings (wait)")
        progress(0.85, "Painting the light")

        // Terrain.
        let terrainRoot = SCNNode()
        terrainRoot.name = "terrain"
        for chunk in near {
            // Each node sits at its mesh's centre: SceneKit picks a level of
            // detail by the distance to the node, not to its geometry.
            var mesh = chunk.mesh, lodMesh = chunk.lod
            let centre = mesh.boundsCentre
            mesh.translate(by: -centre)
            lodMesh?.translate(by: -centre)
            guard let g = mesh.geometry(materials: [materials.terrain]) else { continue }
            if let lod = lodMesh?.geometry(materials: [materials.terrain]) {
                g.levelsOfDetail = [SCNLevelOfDetail(geometry: lod, worldSpaceDistance: 240)]
            }
            let node = SCNNode(geometry: g)
            node.simdPosition = centre
            node.castsShadow = chunk.nearRoute
            terrainRoot.addChildNode(node)
            log.triangles["terrain near", default: 0] += chunk.mesh.triangleCount
            log.distant["terrain near", default: 0] += chunk.lod?.triangleCount ?? chunk.mesh.triangleCount
        }
        for chunk in far {
            guard let g = chunk.mesh.geometry(materials: [materials.farTerrain]) else { continue }
            let node = SCNNode(geometry: g)
            node.castsShadow = false
            terrainRoot.addChildNode(node)
            log.triangles["terrain far", default: 0] += chunk.mesh.triangleCount
        }
        scene.rootNode.addChildNode(terrainRoot)

        // Road and verges.
        let roadRoot = SCNNode()
        roadRoot.name = "road"
        for (mesh, material, name) in [(road.asphalt, materials.asphalt, "asphalt"),
                                        (road.cobbles, materials.cobbles, "cobbles"),
                                        (road.kerb, materials.kerb, "kerb"),
                                        (road.verge, materials.verge, "verge")] {
            guard let g = mesh.geometry(materials: [material]) else { continue }
            let node = SCNNode(geometry: g)
            node.name = name
            // The road is flat and only receives; casting onto itself
            // would only add shadow acne.
            node.castsShadow = name == "verge"
            roadRoot.addChildNode(node)
            log.triangles["road " + name, default: 0] += mesh.triangleCount
        }
        let side = await sideRoads
        try Task.checkCancellation()
        if let g = side.geometry(materials: [materials.sideAsphalt, materials.sideCobbles]) {
            let node = SCNNode(geometry: g)
            node.name = "side roads"
            node.castsShadow = false
            roadRoot.addChildNode(node)
            log.triangles["side roads", default: 0] += side.triangleCount
        }
        scene.rootNode.addChildNode(roadRoot)
        log.mark("terrain + road geometry")

        // Trees and shrubs, clustered with three levels of detail.
        let plantRoot = SCNNode()
        plantRoot.name = "vegetation"
        let plantMats = [materials.bark, materials.leaves]
        for var c in veg.clusters {
            // Local to the cluster's centre, so the levels of detail switch
            // by the distance to this cluster (see the terrain above).
            let centre = (c.full.isEmpty ? c.light : c.full).boundsCentre
            c.full.translate(by: -centre)
            c.light.translate(by: -centre)
            c.impostor.translate(by: -centre)
            let lightG = c.light.geometry(materials: plantMats)
            let impG = c.impostor.geometry(materials: [materials.impostor, materials.impostor])
            var lods: [SCNLevelOfDetail] = []
            let primary: SCNGeometry?
            if let fullG = c.full.geometry(materials: plantMats) {
                primary = fullG
                if let lightG { lods.append(SCNLevelOfDetail(geometry: lightG, worldSpaceDistance: CGFloat(config.treeDetailCameraDistance))) }
                log.triangles["trees+shrubs near (full)", default: 0] += c.full.triangleCount
            } else {
                primary = lightG
                log.triangles["trees+shrubs (light)", default: 0] += c.light.triangleCount
            }
            guard let primary else { continue }
            lods.append(SCNLevelOfDetail(geometry: impG, worldSpaceDistance: CGFloat(config.treeImpostorDistance)))
            primary.levelsOfDetail = lods
            log.distant["vegetation", default: 0] += c.impostor.triangleCount
            let node = SCNNode(geometry: primary)
            node.simdPosition = centre
            plantRoot.addChildNode(node)
        }
        scene.rootNode.addChildNode(plantRoot)

        // Streamed verge grass.
        var grassCells: [(s: Double, node: SCNNode)] = []
        for cell in veg.grassCells {
            guard let g = cell.mesh.geometry(materials: [materials.grass]) else { continue }
            let node = SCNNode(geometry: g)
            node.castsShadow = false
            node.isHidden = true
            plantRoot.addChildNode(node)
            grassCells.append((cell.s, node))
            log.triangles["grass (all cells)", default: 0] += cell.mesh.triangleCount
        }
        log.mark("vegetation geometry")

        // Buildings, props, water.
        let builtRoot = SCNNode()
        builtRoot.name = "buildings"
        if let g = town.walls.geometry(materials: [materials.walls]) {
            builtRoot.addChildNode(SCNNode(geometry: g))
            log.triangles["building walls", default: 0] += town.walls.triangleCount
        }
        if let g = town.roofs.geometry(materials: [materials.roofPantile, materials.roofSlate]) {
            builtRoot.addChildNode(SCNNode(geometry: g))
            log.triangles["building roofs", default: 0] += town.roofs.triangleCount
        }
        // Fence wire is a few millimetres thick: its shadow would only
        // alias into dotted lines across the grass.
        var solidProps = town.props, wires = town.props
        solidProps.parts[3] = []
        for k in 0..<3 { wires.parts[k] = [] }
        for (mesh, casts) in [(solidProps, true), (wires, false)] {
            guard let g = mesh.geometry(materials: [materials.darkMetal, materials.lampGlass, materials.wood, materials.wire]) else { continue }
            let node = SCNNode(geometry: g)
            node.castsShadow = casts
            builtRoot.addChildNode(node)
            log.triangles["props", default: 0] += mesh.triangleCount
        }
        for (mesh, material, name) in [(town.water, materials.water, "water"),
                                        (town.streams, materials.stream, "streams")] {
            guard let g = mesh.geometry(materials: [material]) else { continue }
            let node = SCNNode(geometry: g)
            node.castsShadow = false
            builtRoot.addChildNode(node)
            log.triangles[name, default: 0] += mesh.triangleCount
        }
        scene.rootNode.addChildNode(builtRoot)
        log.counts = veg.counts
        log.counts["buildings"] = town.count
        log.mark("building geometry")

        let dynamicRoot = SCNNode()
        dynamicRoot.name = "dynamic"
        scene.rootNode.addChildNode(dynamicRoot)

        log.total = CACurrentMediaTime() - started
        log.write()

        let frame = FrameUpdater(sun: sun, corridor: corridor, grass: grassCells, grassMaterial: materials.grass,
                                 grassRadius: config.grassRadius)
        #if DEBUG
        if let dir = WorldDebugShots.directory {
            progress(1, "Taking world shots")
            WorldDebugShots.run(scene: scene, route: bundle.route, quality: quality,
                                configure: { SkyLighting.configure($0, config: config) },
                                frame: frame, dir: dir,
                                terrainHeight: { e, n in corridor.terrain.height(east: Double(e), north: Double(n)) })
        }
        #endif
        progress(1, "Ready")
        return CourseWorld(
            scene: scene,
            bundle: bundle,
            quality: quality,
            dynamicRoot: dynamicRoot,
            sun: sun,
            preferredFramesPerSecond: config.fps,
            configureCamera: { camera in SkyLighting.configure(camera, config: config) },
            onFrame: { position, time in frame.update(camera: position, time: time) },
            applyLiveConfig: { live in
                if let light = sun.light { SkyLighting.applyShadows(light, config: live) }
                frame.setGrassRadius(min(live.grassRadius, config.grassRadius))
            }
        )
    }
}

/// Per-frame work on the render thread: keeps the sun (and so the shadow
/// cascades) centred on the camera, and shows only the grass near it.
///
/// Grass streams in short route cells. The grass shader shrinks tufts to
/// the ground over the last `WorldShaders.grassFadeLength` metres before
/// `grassRadius` (camera distance), and a cell is shown a few metres before
/// any of its tufts come inside that radius, so cells appear where their
/// tufts are still flat: no hard edge, no visible steps.
final class FrameUpdater: @unchecked Sendable {
    private let sun: SCNNode
    private let corridor: RoadCorridor
    private let grass: [(s: Double, node: SCNNode)]
    private let grassMaterial: SCNMaterial?
    /// Render thread only (live fallback steps also arrive there).
    private var grassRadius: Double
    private var lastS = -1e9
    /// How often (camera travel, metres) the cells are re-checked.
    private static let recheckM = 1.0

    init(sun: SCNNode, corridor: RoadCorridor, grass: [(s: Double, node: SCNNode)], grassMaterial: SCNMaterial?,
         grassRadius: Double) {
        self.sun = sun
        self.corridor = corridor
        self.grass = grass
        self.grassMaterial = grassMaterial
        self.grassRadius = grassRadius
        grassMaterial?.setValue(NSNumber(value: grassRadius), forKey: "grassFadeEnd")
    }

    /// Route distance from the camera within which cells are shown: past
    /// the fade-out by half a cell, the re-check step and a metre.
    private var showRadius: Double {
        grassRadius + VegetationBuilder.grassCellM / 2 + Self.recheckM + 1
    }

    /// Pulls the grass in (a live fallback step); 0 hides it. Render thread.
    func setGrassRadius(_ r: Double) {
        guard r != grassRadius else { return }
        grassRadius = r
        grassMaterial?.setValue(NSNumber(value: r), forKey: "grassFadeEnd")
        lastS = -1e9
    }

    #if DEBUG
    private var frames = 0
    #endif

    func update(camera: SIMD3<Float>, time: TimeInterval) {
        sun.simdPosition = camera
        #if DEBUG
        frames += 1
        if frames % 60 == 0, frames <= 3000 {
            let q = corridor.coarse.query(east: Double(camera.x), north: Double(-camera.z))
            let args = frames == 60 ? " args " + ProcessInfo.processInfo.arguments.dropFirst().joined(separator: " ") : ""
            let line = "frame \(frames) t \(String(format: "%.2f", CACurrentMediaTime())) camera \(camera) nearest s \(q.s) dist \(q.dist)\(args)\n"
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cj_world_frames.txt")
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        #endif
        guard !grass.isEmpty else { return }
        let q = corridor.coarse.query(east: Double(camera.x), north: Double(-camera.z))
        guard abs(q.s - lastS) > Self.recheckM else { return }
        lastS = q.s
        let onRoute = q.dist < 60 && grassRadius > 0
        let radius = showRadius
        for cell in grass {
            let show = onRoute && abs(cell.s - q.s) < radius
            if cell.node.isHidden == show { cell.node.isHidden = !show }
        }
    }
}

/// Build timings and triangle counts, written to the app's temporary
/// directory (cj_world_log.txt) for development.
struct WorldBuildLog {
    let quality: GraphicsQuality
    var steps: [(String, Double)] = []
    var triangles: [String: Int] = [:]
    /// Triangles once distant levels of detail have switched in.
    var distant: [String: Int] = [:]
    var counts: [String: Int] = [:]
    var total: Double = 0
    private var last = CACurrentMediaTime()

    init(quality: GraphicsQuality) { self.quality = quality }

    mutating func mark(_ step: String) {
        let now = CACurrentMediaTime()
        steps.append((step, now - last))
        last = now
    }

    func write() {
        var lines = ["world build \(quality.rawValue): \(String(format: "%.2f", total)) s"]
        for (k, v) in steps { lines.append(String(format: "  %@ %.3f s", k, v)) }
        lines.append("triangles built \(triangles.values.reduce(0, +))")
        for (k, v) in triangles.sorted(by: { $0.key < $1.key }) { lines.append("  \(k): \(v)") }
        for (k, v) in distant.sorted(by: { $0.key < $1.key }) { lines.append("  distant LOD \(k): \(v)") }
        for (k, v) in counts.sorted(by: { $0.key < $1.key }) { lines.append("  count \(k): \(v)") }
        let text = lines.joined(separator: "\n") + "\n"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cj_world_log_\(quality.rawValue).txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        #if DEBUG
        print(text)
        if let dir = WorldDebugShots.directory {
            let copy = URL(fileURLWithPath: dir).appendingPathComponent("world_log_\(quality.rawValue)\(WorldDebugShots.tag).txt")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? text.write(to: copy, atomically: true, encoding: .utf8)
        }
        #endif
    }
}

#if DEBUG
/// Development aid: writes the crashing thread's stack to the app's
/// temporary directory (cj_crash.txt), since Simulator crash reports are
/// not always kept.
enum WorldCrashLog {
    nonisolated(unsafe) private static var installed = false
    nonisolated(unsafe) static var path: [CChar] = []

    static func install() {
        guard !installed else { return }
        installed = true
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cj_crash.txt")
        path = Array(url.path.utf8CString)
        for sig in [SIGABRT, SIGILL, SIGTRAP, SIGSEGV, SIGBUS, SIGFPE] {
            signal(sig) { s in
                let text = "signal \(s) at \(Date())\n" + Thread.callStackSymbols.joined(separator: "\n") + "\n"
                WorldCrashLog.path.withUnsafeBufferPointer { p in
                    if let f = fopen(p.baseAddress, "a") {
                        fputs(text, f)
                        fclose(f)
                    }
                }
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }
}
#endif
