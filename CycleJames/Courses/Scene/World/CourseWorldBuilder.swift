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
        let tier = WorldConfig.make(quality)
        progress(0.02, "Reading the map")

        let corridor = RoadCorridor(bundle: bundle, vergeWidth: tier.vergeWidth)
        // The Riviera's own tier knobs (`WorldBudget`); the verge width is
        // the tier's either way.
        let config = corridor.art.look.isRiviera ? tier.riviera() : tier
        try Task.checkCancellation()
        log.mark("corridor")
        progress(0.1, "Shaping the hills")

        let scenery = bundle.scenery
        // A coast's sea and the land out to its skyline (the Poggio).
        let look = corridor.art.look
        let seaLevel = SeaBuilder.level(bundle: bundle)
        let horizonRaster = TerrainBuilder.horizonRaster(bundle: bundle)
        // Each builder's own time, for the log (they run side by side).
        let times = WorldBuildTimes(origin: started)
        async let nearChunks = times.handOver("terrain near") {
            TerrainBuilder.buildNear(corridor: corridor, config: config, seaLevel: seaLevel)
        }
        async let farChunks = times.handOver("terrain far") {
            TerrainBuilder.buildFar(corridor: corridor, config: config, seaLevel: seaLevel)
        }
        async let horizonChunks = times.handOver("terrain horizon") {
            horizonRaster.map {
                TerrainBuilder.buildHorizon(corridor: corridor, raster: $0, config: config, seaLevel: seaLevel)
            } ?? []
        }
        async let seaMesh = times.handOver("sea") {
            seaLevel.map { SeaBuilder.build(corridor: corridor, levelM: $0, horizon: horizonRaster) }
        }
        async let roadMeshes = times.handOver("road") { RoadBuilder.build(corridor: corridor, coarse: quality == .battery) }
        // The canopy raster is decoded for this build only (`CourseBundle.canopy`).
        async let houses = times.handOver("buildings, roadside, summit") {
            BuildingBuilder.build(corridor: corridor, scenery: scenery, canopy: bundle.canopy,
                                  rivieraDetail: .make(quality))
        }
        async let sideRoads = times.handOver("side roads") {
            RoadBuilder.buildSideRoads(corridor: corridor, scenery: scenery, reach: config.terrain1mRadius - 4)
        }

        // The course's light raster, decoded once while those build: for the
        // plants' sky (`SkyRaster`), the light along the route that meters
        // the lane exposure (`LightProfile`) and, handed to the textures,
        // the GPU (`WorldMaterials+Light`). Let go of once all three have it.
        let lightName = "\(bundle.id)_light"
        #if DEBUG
        let lightDecodes = WorldTextures.decodes(lightName)
        #endif
        var lightPixels = WorldTextures.rawPixels(lightName)
        let sky = SkyRaster(pixels: lightPixels, bundle: bundle, config: config)
        let light = LightProfile.make(bundle: bundle, pixels: lightPixels)
        log.mark("light raster")
        async let plants = times.handOver("plants") {
            VegetationBuilder.build(corridor: corridor, scenery: scenery, config: config,
                                    ground: config.grassDensity > 0 ? GroundColor(bundle: bundle) : nil, sky: sky)
        }

        // Textures and materials load while the meshes build. Their GPU
        // uploads need the app in the foreground; if it left part way
        // through, an upload failed and they are made again on return.
        var textures: WorldTextures
        var materials: WorldMaterials
        var seaMaterial: SCNMaterial?
        var attempts = 0
        repeat {
            try await waitForForeground()
            textures = WorldTextures(limit: config.textureLimit)
            textures.adopt(lightPixels, as: lightName)
            materials = WorldMaterials(config: config, textures: textures, bundle: bundle, art: corridor.art)
            for m in materials.warmUp { _ = m }
            seaMaterial = seaLevel == nil ? nil : materials.makeSea()
            attempts += 1
            #if DEBUG
            if textures.uploadFailed { print("world textures: GPU upload failed (attempt \(attempts)), retrying") }
            #endif
            try Task.checkCancellation()
        } while textures.uploadFailed && attempts < 3
        lightPixels = nil
        let scene = SCNScene()
        let sun = SkyLighting.install(in: scene, config: config, textures: textures, look: look)
        log.mark("sky, textures, materials")

        var near = await nearChunks.take()
        var far = await farChunks.take()
        try Task.checkCancellation()
        log.mark("terrain meshes (wait)")
        progress(0.45, "Laying the cobbles")
        var road = await roadMeshes.take()
        try Task.checkCancellation()
        var town = await houses.take()
        try Task.checkCancellation()
        var side = await sideRoads.take()
        try Task.checkCancellation()
        // The plants take longest (on the Poggio's high tier 12.5 s of a
        // Debug build against the buildings' 11 s): the terrain, road and
        // building geometry is made while they finish, and they are awaited
        // after it.
        log.mark("road, buildings (wait)")
        // On the Riviera each built mesh is let go of once its geometry is
        // made (SceneKit keeps its own copy), so the end of the build holds
        // one copy of the world, not two (`release` below, and the builders'
        // results taken out of their `async let`s by `WorldHandOver`): the
        // Poggio's high tier ended its build at 1018 MB, now 570-610 MB. A
        // Flemish course keeps them to the end, as before.
        let release = look.isRiviera
        #if DEBUG
        var budget = WorldBudgetReport.enabled ? WorldBudgetReport(corridor: corridor) : nil
        if budget != nil {
            for chunk in near { budget?.add("terrain near", chunk.mesh) }
            for (mesh, name) in [(road.asphalt, "road asphalt"), (road.verge, "road verge"), (road.gutter, "road gutter"),
                                 (road.markings, "road markings"), (side, "side roads")] {
                budget?.add(name, mesh)
            }
            budget?.add("building walls", town.walls)
            budget?.add("building roofs", town.roofs, perPart: true)
            budget?.add("props", town.props, perPart: true)
        }
        #endif

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
            log.bytes["terrain near", default: 0] += chunk.mesh.byteCount + (chunk.lod?.byteCount ?? 0)
        }
        if release { near = [] }
        for chunk in far {
            guard let g = chunk.mesh.geometry(materials: [materials.farTerrain]) else { continue }
            let node = SCNNode(geometry: g)
            node.castsShadow = false
            terrainRoot.addChildNode(node)
            log.triangles["terrain far", default: 0] += chunk.mesh.triangleCount
            log.bytes["terrain far", default: 0] += chunk.mesh.byteCount
        }
        if release { far = [] }
        for chunk in await horizonChunks.take() {
            guard let g = chunk.mesh.geometry(materials: [materials.farTerrain]) else { continue }
            let node = SCNNode(geometry: g)
            node.castsShadow = false
            terrainRoot.addChildNode(node)
            log.triangles["terrain horizon", default: 0] += chunk.mesh.triangleCount
            log.bytes["terrain horizon", default: 0] += chunk.mesh.byteCount
        }
        // The sea stays at the origin: its shader bends it with the earth
        // from world positions.
        if let sea = await seaMesh.take(), let seaMaterial, let g = sea.geometry(materials: [seaMaterial]) {
            let node = SCNNode(geometry: g)
            node.name = "sea"
            node.castsShadow = false
            terrainRoot.addChildNode(node)
            log.triangles["sea", default: 0] += sea.triangleCount
            log.bytes["sea", default: 0] += sea.byteCount
        }
        scene.rootNode.addChildNode(terrainRoot)

        // On the Riviera the whole-course meshes (road strips, buildings,
        // props) go in as tiles (`WorldTiles`); a Flemish course keeps one
        // node each.
        let tiled = look.isRiviera
        var tiles = 0

        // Road and verges.
        let roadRoot = SCNNode()
        roadRoot.name = "road"
        for (mesh, material, name) in [(road.asphalt, materials.asphalt, "asphalt"),
                                        (road.cobbles, materials.cobbles, "cobbles"),
                                        (road.concrete, materials.concrete, "concrete"),
                                        (road.kerb, materials.kerb, "kerb"),
                                        (road.gutter, materials.gutter, "gutter"),
                                        (road.pavements, materials.pavementSetts, "pavements"),
                                        (road.markings, materials.roadPaint, "markings"),
                                        (road.cycleLanes, materials.cycleLane, "cycle lanes"),
                                        (road.verge, materials.verge, "verge")] {
            if tiled {
                guard !mesh.isEmpty else { continue }
                // Paint is under a pixel long before 450 m.
                let nodes = WorldTiles.nodes(mesh, materials: [material], size: WorldTiles.roadSize,
                                             hideBeyond: name == "markings" ? 450 : nil, casts: name == "verge", name: name)
                for node in nodes { roadRoot.addChildNode(node) }
                tiles += nodes.count
                log.triangles["road " + name, default: 0] += mesh.triangleCount
                log.bytes["road " + name, default: 0] += mesh.byteCount
                continue
            }
            guard let g = mesh.geometry(materials: [material]) else { continue }
            let node = SCNNode(geometry: g)
            node.name = name
            // The road is flat and only receives; casting onto itself
            // would only add shadow acne.
            node.castsShadow = name == "verge"
            roadRoot.addChildNode(node)
            log.triangles["road " + name, default: 0] += mesh.triangleCount
            log.bytes["road " + name, default: 0] += mesh.byteCount
        }
        if release { road = RoadBuilder.Output() }
        // (Side roads and hedges stay whole: their shaders move vertices by
        // their model position, the side roads towards the camera, the
        // hedges in the wind.)
        if let g = side.geometry(materials: [materials.sideAsphalt, materials.sideCobbles]) {
            let node = SCNNode(geometry: g)
            node.name = "side roads"
            node.castsShadow = false
            roadRoot.addChildNode(node)
            log.triangles["side roads", default: 0] += side.triangleCount
            log.bytes["side roads", default: 0] += side.byteCount
        }
        if release { side = MeshBuffer() }
        scene.rootNode.addChildNode(roadRoot)
        log.mark("terrain + road geometry")

        // Buildings, props, water.
        let builtRoot = SCNNode()
        builtRoot.name = "buildings"
        // Fence and power wire is a few millimetres thick: its shadow would
        // only alias into dotted lines across the grass.
        let wirePart = BuildingBuilder.PropPart.wire.rawValue
        var solidProps = town.props, wires = town.props
        solidProps.parts[wirePart] = []
        for k in wires.parts.indices where k != wirePart { wires.parts[k] = [] }
        if tiled {
            // Walls and roofs whole wherever they are. Of the props, the
            // stone walls and guardrails, which still read as lines along
            // the far legs of the road, stay; from 500 m (a tile's nearest
            // corner up to 180 m nearer) the rest let go: copings and
            // slabs, pergolas, signs and lamp posts; the wires from 300 m.
            // The ironwork, lamp glass and nets are tiles of their own,
            // which let go from the tier's `RivieraDetail.ironM` (420 m on
            // high).
            let far: Set<BuildingBuilder.PropPart> = [.masonry, .galvanised]
            let ironParts = Set(RivieraDetail.ironParts.map(\.rawValue))
            var iron = solidProps
            for k in solidProps.parts.indices {
                if ironParts.contains(k) { solidProps.parts[k] = [] } else { iron.parts[k] = [] }
            }
            let detail = RivieraDetail.make(quality)
            var meshes: [(MeshBuffer, [SCNMaterial], String, Bool, Float?, Set<BuildingBuilder.PropPart>?)] = [
                (town.walls, [materials.walls], "building walls", true, nil, nil),
                (town.roofs, materials.roofParts, "building roofs", true, nil, nil),
                (solidProps, materials.props, "props", true, 500, far),
                (iron, materials.props, "props", true, detail.ironM, nil),
                (wires, materials.props, "props", false, 300, nil),
                (town.water, [materials.water], "water", false, nil, nil),
                (town.streams, [materials.stream], "streams", false, nil, nil),
            ]
            // Only `meshes` holds them now, and each is let go of once its
            // tiles are made (`release`). (The props' three meshes share
            // their vertices: their bytes are counted once.)
            log.bytes["props", default: 0] += town.props.byteCount
            (town.walls, town.roofs, town.props, town.water, town.streams) = (.init(), .init(), .init(), .init(), .init())
            (solidProps, wires, iron) = (.init(), .init(), .init())
            for i in meshes.indices where !meshes[i].0.isEmpty {
                let (mesh, mats, name, casts, beyond, keep) = meshes[i]
                meshes[i].0 = MeshBuffer()
                let farParts = keep.map { Set($0.map(\.rawValue)) }
                let nodes = WorldTiles.nodes(mesh, materials: mats, size: WorldTiles.builtSize, hideBeyond: beyond,
                                             keepBeyond: farParts, casts: casts, name: name)
                for node in nodes { builtRoot.addChildNode(node) }
                tiles += nodes.count
                log.triangles[name, default: 0] += mesh.triangleCount
                if name != "props" { log.bytes[name, default: 0] += mesh.byteCount }
            }
        } else {
            if let g = town.walls.geometry(materials: [materials.walls]) {
                builtRoot.addChildNode(SCNNode(geometry: g))
                log.triangles["building walls", default: 0] += town.walls.triangleCount
                log.bytes["building walls", default: 0] += town.walls.byteCount
            }
            if let g = town.roofs.geometry(materials: materials.roofParts) {
                builtRoot.addChildNode(SCNNode(geometry: g))
                log.triangles["building roofs", default: 0] += town.roofs.triangleCount
                log.bytes["building roofs", default: 0] += town.roofs.byteCount
            }
            for (mesh, casts) in [(solidProps, true), (wires, false)] {
                guard let g = mesh.geometry(materials: materials.props) else { continue }
                let node = SCNNode(geometry: g)
                node.castsShadow = casts
                builtRoot.addChildNode(node)
                log.triangles["props", default: 0] += mesh.triangleCount
                log.bytes["props", default: 0] += mesh.byteCount
            }
            for (mesh, material, name) in [(town.water, materials.water, "water"),
                                            (town.streams, materials.stream, "streams")] {
                guard let g = mesh.geometry(materials: [material]) else { continue }
                let node = SCNNode(geometry: g)
                node.castsShadow = false
                builtRoot.addChildNode(node)
                log.triangles[name, default: 0] += mesh.triangleCount
            }
        }
        log.mark("building geometry")
        progress(0.6, "Planting the hedges")
        var veg = await plants.take()
        try Task.checkCancellation()
        log.mark("plants (wait)")
        #if DEBUG
        if budget != nil {
            budget?.add("hedges", veg.hedges)
            for c in veg.clusters {
                budget?.add("trees+shrubs full", c.full)
                if c.full.isEmpty { budget?.add("trees+shrubs light only", c.light) }
            }
            for cell in veg.grassCells { budget?.add("grass", cell.mesh) }
            budget?.write(quality: quality)
            budget = nil
        }
        #endif

        // Trees and shrubs, clustered with three levels of detail.
        let plantRoot = SCNNode()
        plantRoot.name = "vegetation"
        let plantMats = [materials.bark, materials.leaves]
        // On the Riviera the clusters with no full trees (all beyond the
        // full trees' reach of the route) go in four to a node
        // (`WorldTiles.mergeLightClusters`): each cost two draws for its
        // light trees, or one for its impostors, for a few hundred
        // triangles.
        var clusters = tiled ? WorldTiles.mergeLightClusters(veg.clusters) : veg.clusters
        if release { veg.clusters = [] }
        for i in clusters.indices {
            var c = clusters[i]
            if release { clusters[i] = VegetationBuilder.Cluster() }
            log.bytes["trees+shrubs", default: 0] += c.full.byteCount + c.light.byteCount + c.impostor.byteCount
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

        // Part 2 (copper beech) is drawn with the plain leaves: its
        // purple-red is a per-vertex colour (`TreeArchetype.packColour`).
        if let g = veg.hedges.geometry(materials: [materials.bark, materials.leaves, materials.leaves]) {
            let node = SCNNode(geometry: g)
            node.name = "hedges"
            plantRoot.addChildNode(node)
            log.triangles["hedges", default: 0] += veg.hedges.triangleCount
            log.bytes["hedges", default: 0] += veg.hedges.byteCount
        }

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
            log.bytes["grass (all cells)", default: 0] += cell.mesh.byteCount
        }
        if release {
            clusters = []
            veg.hedges = MeshBuffer()
            veg.grassCells = []
        }
        log.mark("vegetation geometry")

        progress(0.75, "Building the houses")
        scene.rootNode.addChildNode(builtRoot)
        log.counts = veg.counts
        log.counts["buildings"] = town.count
        if tiled { log.counts["tiled nodes"] = tiles }
        #if DEBUG
        log.counts["light raster decodes"] = WorldTextures.decodes(lightName) - lightDecodes
        #endif
        progress(0.85, "Painting the light")

        let dynamicRoot = SCNNode()
        dynamicRoot.name = "dynamic"
        scene.rootNode.addChildNode(dynamicRoot)

        // Every material is made: the ride needn't keep what they don't hold.
        textures.releaseCaches()
        log.mark("texture caches released")

        log.total = CACurrentMediaTime() - started
        log.builders = times.all
        log.write()

        let frame = FrameUpdater(sun: sun, corridor: corridor, grass: grassCells, grassMaterial: materials.grass,
                                 grassRadius: config.grassRadius)
        // The lane exposure, metered from `light`: the lights (and the
        // leaves' light through them) that it scales.
        let glow = [materials.leaves, materials.grass, materials.impostor] + [seaMaterial].compactMap { $0 }
        let exposure: (Float) -> Void = sun.light.map {
            SkyLighting.exposure(scene: scene, sun: $0, glow: glow, look: look)
        } ?? { _ in }
        #if DEBUG
        if let dir = WorldDebugShots.directory {
            progress(1, "Taking world shots")
            WorldDebugShots.run(scene: scene, route: bundle.route, quality: quality,
                                configure: { SkyLighting.configure($0, config: config, look: look) },
                                frame: frame, dir: dir,
                                terrainHeight: { e, n in corridor.terrain.height(east: Double(e), north: Double(n)) },
                                light: light, setExposure: exposure,
                                partNames: Dictionary(zip(materials.props.map(ObjectIdentifier.init),
                                                          BuildingBuilder.PropPart.allCases.map { "\($0)" }),
                                                      uniquingKeysWith: { a, _ in a }))
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
            configureCamera: { camera in SkyLighting.configure(camera, config: config, look: look) },
            onFrame: { position, time in frame.update(camera: position, time: time) },
            // Keeps the materials for the ride; their textures' caches are
            // already let go of (`releaseCaches` above).
            applyLiveConfig: { [materials] live in
                if let light = sun.light { SkyLighting.applyShadows(light, config: live, look: look) }
                frame.setGrassRadius(min(live.grassRadius, config.grassRadius))
                materials.applyLive(live)
            },
            light: light,
            setExposure: exposure
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
    /// Each step's time and the app's memory footprint at its end (MB).
    var steps: [(String, Double, Int)] = []
    var triangles: [String: Int] = [:]
    /// Triangles once distant levels of detail have switched in.
    var distant: [String: Int] = [:]
    var counts: [String: Int] = [:]
    /// Bytes of the meshes made into geometry, by the names above.
    var bytes: [String: Int] = [:]
    /// Each builder's own time (`WorldBuildTimes`).
    var builders: [WorldBuildTimes.Entry] = []
    var total: Double = 0
    private var last = CACurrentMediaTime()
    /// CPU time over every thread, at the start and at each step's end.
    private var cpu: [Double] = [WorldBuildTimes.processCPU()]

    init(quality: GraphicsQuality) { self.quality = quality }

    mutating func mark(_ step: String) {
        let now = CACurrentMediaTime()
        steps.append((step, now - last, Self.footprintMB().now))
        cpu.append(WorldBuildTimes.processCPU())
        last = now
    }

    /// The app's memory footprint (what iOS holds it to) now, and its peak
    /// so far, in MB; 0 if the kernel won't say.
    static func footprintMB() -> (now: Int, peak: Int) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        return (Int(info.phys_footprint >> 20), Int(info.ledger_phys_footprint_peak >> 20))
    }

    func write() {
        var lines = ["world build \(quality.rawValue): \(String(format: "%.2f", total)) s"]
        for (k, v, mb) in steps { lines.append(String(format: "  %@ %.3f s, %d MB", k, v, mb)) }
        let footprint = Self.footprintMB()
        lines.append("memory footprint \(footprint.now) MB, peak so far \(footprint.peak) MB")
        lines.append("triangles built \(triangles.values.reduce(0, +))")
        for (k, v) in triangles.sorted(by: { $0.key < $1.key }) { lines.append("  \(k): \(v)") }
        for (k, v) in distant.sorted(by: { $0.key < $1.key }) { lines.append("  distant LOD \(k): \(v)") }
        for (k, v) in counts.sorted(by: { $0.key < $1.key }) { lines.append("  count \(k): \(v)") }
        lines.append(String(format: "mesh MB made into geometry %.1f", Double(bytes.values.reduce(0, +)) / 1_048_576))
        for (k, v) in bytes.sorted(by: { $0.key < $1.key }) {
            lines.append(String(format: "  MB %@: %.1f", k, Double(v) / 1_048_576))
        }
        // CPU time over all threads by step, and each builder's own.
        lines.append(String(format: "CPU (all threads) %.2f s over %.2f s", (cpu.last ?? 0) - cpu[0], total))
        for (i, step) in steps.enumerated() where i + 1 < cpu.count {
            lines.append(String(format: "  CPU %@ %.2f s", step.0, cpu[i + 1] - cpu[i]))
        }
        for b in builders {
            lines.append(String(format: "  builder %@: from %.2f s, %.2f s wall, %.2f s CPU", b.name, b.start, b.wall, b.cpu))
        }
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
