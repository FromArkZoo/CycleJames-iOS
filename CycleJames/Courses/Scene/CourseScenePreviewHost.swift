import SwiftUI
import SceneKit
import QuartzCore

/// Development-only entry point that opens straight into the 3D scene with a
/// scripted rider, for screenshots and visual checks in the Simulator.
///
///     -coursePreview koppenberg     course id (required)
///     -courseStartS 450             start distance along the route, m
///     -courseSpeedKph 8             constant speed; 0 = parked (camera holds)
///     -courseCadence 70             crank rpm
///     -courseCamera chase           chase | close | firstPerson | broadcast
///     -courseQuality high           high | balanced | battery
///     -courseAdaptive               let the tier step down live when slow,
///                                   as an automatic tier does in a ride
///     -courseCameraOrbit            parked and not riding: the idle orbit
///     -courseCameraBlend 3          mode-change blend time, s
///     -courseCameraSwitchAfter 6    switch to the next mode this long after
///                                   the world is ready (catch a blend)
///     -courseLandscape              render a landscape frame (shown rotated)
///     -courseInsets 190,300         points covered by a ride HUD at the top
///                                   and bottom (camera framing; nothing drawn)
///     -courseStats                  SceneKit statistics overlay
///     -courseShotPlan [part]        snapshot every camera mode at s = 10,
///                                   330, 590 and 1060, a mode change, the
///                                   orbit and the return from it, then show
///                                   a contact sheet; `part` limits it to a
///                                   station list ("10,590"), blend or orbit
///     -courseCameraSweep            ride every mode over the whole route
///                                   without drawing and report clearance
///     -courseHUD                    render-loop and camera numbers on screen
///     -courseShotDir /path          where the plan and sweep write files
///                                   (default: the app's Documents folder)
///
/// No-op unless `-coursePreview` is passed at launch.
struct CourseScenePreviewHost: View {
    struct Request {
        let courseID: String
        let startS: Double
        let speedKph: Double
        let cadence: Double
        let camera: CameraMode
        let quality: GraphicsQuality
        var adaptive = false
        var orbit = false
        var transitionSeconds: Double?
        var switchAfter: Double?
        var landscape = false
        var showStats = false
        var shotPlan = false
        /// "all", a station list like "10,590", "blend" or "orbit".
        var shotPlanPart = "all"
        var sweep = false
        var shotDir: String?
        var hud = false
        var overlayInsets = EdgeInsets()
    }

    static let request: Request? = {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        func flag(_ name: String) -> Bool {
            guard let i = args.firstIndex(of: name) else { return false }
            // Accept both "-flag" and "-flag YES/1/true".
            guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else { return true }
            return ["1", "yes", "true"].contains(args[i + 1].lowercased())
        }
        guard let id = value("-coursePreview") else { return nil }
        var r = Request(
            courseID: id,
            startS: value("-courseStartS").flatMap(Double.init) ?? 0,
            speedKph: value("-courseSpeedKph").flatMap(Double.init) ?? 10,
            cadence: value("-courseCadence").flatMap(Double.init) ?? 80,
            camera: value("-courseCamera").flatMap(CameraMode.init(rawValue:)) ?? .chase,
            quality: value("-courseQuality").flatMap(GraphicsQuality.init(rawValue:)) ?? .high
        )
        r.adaptive = flag("-courseAdaptive")
        r.orbit = flag("-courseCameraOrbit")
        r.transitionSeconds = value("-courseCameraBlend").flatMap(Double.init)
        r.switchAfter = value("-courseCameraSwitchAfter").flatMap(Double.init)
        r.landscape = flag("-courseLandscape")
        r.showStats = flag("-courseStats")
        // Takes an optional part rather than YES/NO.
        r.shotPlan = args.contains("-courseShotPlan")
        if let part = value("-courseShotPlan"), !part.hasPrefix("-") { r.shotPlanPart = part }
        r.sweep = flag("-courseCameraSweep")
        r.shotDir = value("-courseShotDir")
        r.hud = flag("-courseHUD")
        if let parts = value("-courseInsets")?.split(separator: ",").compactMap({ Double($0) }), parts.count == 2 {
            r.overlayInsets = EdgeInsets(top: parts[0], leading: 0, bottom: parts[1], trailing: 0)
        }
        return r
    }()

    let request: Request
    @State private var bundle: CourseBundle?
    @State private var error: String?
    @State private var progressLabel = "Loading"
    @State private var camera: CameraMode
    @State private var driver: PreviewDriver?
    @State private var scnView: SCNView?
    @State private var world: CourseWorld?
    @State private var report: String?
    @State private var sheet: [(String, UIImage)] = []
    @State private var planStatus = ""
    @State private var coordinator: CourseSceneView.Coordinator?
    @State private var hudText = ""
    // @State, not let: RootView re-creates this struct whenever it
    // re-renders, and a fresh mailbox each time would leave the scene
    // reading one the driver never writes.
    @State private var stateBox = RideStateBox()

    init(request: Request) {
        self.request = request
        _camera = State(initialValue: request.camera)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let bundle {
                GeometryReader { geo in
                    scene(bundle)
                        .frame(
                            width: request.landscape ? geo.size.height : geo.size.width,
                            height: request.landscape ? geo.size.width : geo.size.height
                        )
                        .rotationEffect(.degrees(request.landscape ? 90 : 0))
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
                .ignoresSafeArea()
            }
            if let error {
                Text(error).foregroundStyle(.red).padding()
            } else if !progressLabel.isEmpty {
                Text(progressLabel).foregroundStyle(.white).padding()
            } else if !planStatus.isEmpty {
                Text(planStatus).font(.caption2.monospaced()).foregroundStyle(.yellow).padding(.top, 50).padding(.leading)
            }
            if request.hud {
                Text(hudText).font(.caption2.monospaced()).foregroundStyle(.yellow)
                    .padding(4).background(.black.opacity(0.5)).padding(.top, 70).padding(.leading)
            }
            if !sheet.isEmpty {
                ContactSheet(items: sheet)
            } else if let report {
                ScrollView {
                    Text(report).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white)
                        .padding(8)
                }
                .background(.black.opacity(0.7))
            }
        }
        .statusBarHidden()
        .task {
            do {
                let id = request.courseID
                let loaded = try await Task.detached { try CourseBundle.load(id: id) }.value
                let d = PreviewDriver(route: loaded.route, request: request, box: stateBox)
                d.start()
                driver = d
                bundle = loaded
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func scene(_ bundle: CourseBundle) -> some View {
        CourseSceneView(
            bundle: bundle,
            stateBox: stateBox,
            cameraMode: camera,
            quality: request.quality,
            adaptsQuality: request.adaptive,
            onProgress: { _, label in progressLabel = label },
            onReady: {
                progressLabel = ""
                Task { await afterReady() }
            },
            onError: { error = $0.localizedDescription },
            overlayInsets: request.overlayInsets,
            debug: CourseSceneDebug(
                showsStatistics: request.showStats,
                transitionSeconds: request.transitionSeconds,
                onView: { scnView = $0 },
                onAttach: { world = $0 },
                onCoordinator: { coordinator = $0 }
            )
        )
        .onTapGesture { camera = camera.next }
    }

    // MARK: Scripted checks

    /// The app's Documents folder always, plus `-courseShotDir` when given
    /// (the Simulator can usually write straight to a folder on the Mac).
    private var outputDirectories: [URL] {
        var dirs = [FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("camera-shots", isDirectory: true)]
        if let dir = request.shotDir { dirs.append(URL(fileURLWithPath: dir, isDirectory: true)) }
        return dirs
    }

    /// Development read-out, polled from the main thread (approximate by design).
    @MainActor
    private func runHUD() async {
        while !Task.isCancelled {
            let snap = stateBox.read()
            let cam = scnView?.pointOfView?.presentation.simdWorldPosition ?? .zero
            let pose = bundle?.route.pose(at: snap.s, lateral: snap.lateralM).position ?? .zero
            let live = coordinator?.liveQualitySteps.map(\.description).joined(separator: ", ") ?? ""
            hudText = String(
                format: "playing %@  frames %d  s %.1f  run %@  mode %@\ncam-rider %.2f m  dy %.2f m%@",
                (scnView?.isPlaying ?? false) ? "yes" : "no", coordinator?.frameCount ?? -1, snap.s,
                snap.isRunning ? "yes" : "no", camera.rawValue, simd_distance(cam, pose), cam.y - pose.y,
                live.isEmpty ? "" : "\nlive: " + live
            )
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    @MainActor
    private func afterReady() async {
        if request.hud { Task { await runHUD() } }
        if let after = request.switchAfter {
            try? await Task.sleep(for: .seconds(after))
            camera = camera.next
        }
        if request.sweep, let world {
            let aspect: Float = request.landscape ? 2.16 : 0.46
            planStatus = "sweeping"
            let text = await CameraSweep.run(world: world, aspect: aspect)
            write(text, to: "camera_sweep\(request.landscape ? "_landscape" : "").txt")
            if !request.shotPlan { report = text }
        planStatus = "sweep done"
        }
        if request.shotPlan, let scnView, let driver {
            await runShotPlan(view: scnView, driver: driver)
        }
    }

    @MainActor
    private func runShotPlan(view: SCNView, driver: PreviewDriver) async {
        let suffix = request.landscape ? "_land" : ""
        let settle = 2.0
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        var taken: [(String, UIImage)] = []
        func shoot(_ name: String) async {
            guard let image = await Self.capture(view) else {
                planStatus = "\(taken.count) \(name) (no image)"
                return
            }
            taken.append((name, image))
            let saved = save(image, name: name + suffix)
            planStatus = "\(taken.count) \(name)\(saved ? "" : " (not saved)")"
        }

        let part = request.shotPlanPart
        let stations: [Double] = part == "all" ? [10, 330, 590, 1060]
            : part.split(separator: ",").compactMap { Double($0) }
        // Let the world settle (streaming, first-frame work) before the first shot.
        await wait(1)
        for s in stations {
            for mode in CameraMode.allCases {
                driver.place(at: s, arrivingIn: settle)
                camera = mode
                await wait(settle)
                await shoot("s\(Int(s))_\(mode.rawValue)")
            }
        }
        guard part == "all" || part == "blend" || part == "orbit" else {
            sheet = taken
            return
        }
        if part != "orbit" {
            // A mode change on the steepest ramp, caught part way.
            driver.place(at: 590, arrivingIn: settle + 0.6)
            camera = .chase
            await wait(settle)
            camera = .broadcast
            await wait(0.3)
            await shoot("blend_chase_to_broadcast_0.3s")
            await wait(0.3)
            await shoot("blend_chase_to_broadcast_0.6s")
            await wait(0.3)
            await shoot("blend_chase_to_broadcast_0.9s")
            // Into rider view: the head must be gone before the lens reaches
            // it. Spaced over the blend time (slow it with -courseCameraBlend).
            let blend = request.transitionSeconds ?? 0.9
            driver.place(at: 590, arrivingIn: settle + blend)
            camera = .close
            await wait(settle)
            camera = .firstPerson
            var done = 0.0
            for f in [0.35, 0.7, 0.9] {
                await wait(blend * (f - done))
                done = f
                await shoot("blend_close_to_firstPerson_\(Int(f * 100))pct")
            }
            await wait(settle)
            camera = .broadcast
            await wait(blend * 0.25)
            await shoot("blend_firstPerson_to_broadcast_25pct")
        }
        guard part != "blend" else {
            sheet = taken
            return
        }
        // Paused: the idle orbit, then riding on again.
        camera = .chase
        driver.place(at: 590, arrivingIn: settle)
        await wait(settle)
        driver.setIdle(true)
        await wait(4)
        await shoot("orbit_4s")
        await wait(8)
        await shoot("orbit_12s")
        driver.setIdle(false)
        await wait(1.2)
        await shoot("resume_1.2s")
        await wait(2.8)
        await shoot("resume_4s")
        sheet = taken
    }

    /// Renders the view's scene from its camera at half resolution with an
    /// offscreen renderer on a background queue. (`SCNView.snapshot()`
    /// blocks the main thread indefinitely in the Simulator while the view is
    /// rendering continuously.) Nil if nothing comes back within 8 s.
    @MainActor
    private static func capture(_ view: SCNView) async -> UIImage? {
        guard let scene = view.scene, let camera = view.pointOfView else { return nil }
        let scale = view.contentScaleFactor * 0.5
        let size = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        // SceneKit objects may be rendered from any thread; the wrapper only
        // tells the compiler so.
        let source = RenderSource(scene: scene, camera: camera, device: view.device)
        let box = ImageBox()
        return await withCheckedContinuation { (done: CheckedContinuation<UIImage?, Never>) in
            box.continuation = done
            DispatchQueue.global(qos: .userInitiated).async {
                let renderer = SCNRenderer(device: source.device, options: nil)
                renderer.scene = source.scene
                renderer.pointOfView = source.camera
                box.finish(renderer.snapshot(atTime: CACurrentMediaTime(), with: size, antialiasingMode: .multisampling4X))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { box.finish(nil) }
        }
    }

    @discardableResult
    private func save(_ image: UIImage, name: String) -> Bool {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return false }
        return write(data, to: name + ".jpg")
    }

    @discardableResult
    private func write(_ text: String, to name: String) -> Bool {
        write(Data(text.utf8), to: name)
    }

    /// True when the last directory (the requested one) took the file.
    private func write(_ data: Data, to name: String) -> Bool {
        var ok = false
        for dir in outputDirectories {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            ok = (try? data.write(to: dir.appendingPathComponent(name))) != nil
        }
        return ok
    }
}

private struct RenderSource: @unchecked Sendable {
    let scene: SCNScene
    let camera: SCNNode
    let device: MTLDevice?
}

/// Hands one image to a continuation, from whichever side finishes first.
private final class ImageBox: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<UIImage?, Never>?

    func finish(_ image: UIImage?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: image)
    }
}

/// Grid of labelled snapshots from the shot plan.
private struct ContactSheet: View {
    let items: [(String, UIImage)]

    var body: some View {
        GeometryReader { geo in
            let columns = 4
            let width = geo.size.width / CGFloat(columns)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 0), count: columns), spacing: 0) {
                    ForEach(items.indices, id: \.self) { i in
                        ZStack(alignment: .bottomLeading) {
                            Image(uiImage: items[i].1).resizable().scaledToFit()
                            Text(items[i].0).font(.system(size: 7)).foregroundStyle(.yellow)
                                .padding(1).background(.black.opacity(0.6))
                        }
                    }
                }
            }
            .background(.black)
        }
        .ignoresSafeArea()
    }
}

/// Moves the preview rider along the route at a constant speed.
@MainActor
private final class PreviewDriver {
    private let route: CourseRoute
    private let request: CourseScenePreviewHost.Request
    private let box: RideStateBox
    private var timer: Timer?
    private var s: Double
    private var last: CFTimeInterval = 0
    private var idle: Bool

    init(route: CourseRoute, request: CourseScenePreviewHost.Request, box: RideStateBox) {
        self.route = route
        self.request = request
        self.box = box
        self.s = request.startS
        self.idle = request.orbit
    }

    func start() {
        last = CACurrentMediaTime()
        publish()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step() }
        }
    }

    /// Jumps back so the rider reaches `target` in `seconds` at the preview speed.
    func place(at target: Double, arrivingIn seconds: Double) {
        s = max(0, target - (idle ? 0 : speed * seconds))
        last = CACurrentMediaTime()
        publish()
    }

    /// Parks the rider with the ride not running (ready / paused).
    func setIdle(_ value: Bool) {
        idle = value
        last = CACurrentMediaTime()
        publish()
    }

    private var speed: Double { idle ? 0 : request.speedKph / 3.6 }

    private func step() {
        let now = CACurrentMediaTime()
        s += speed * (now - last)
        if s >= route.length { s = request.startS }
        last = now
        publish()
    }

    private func publish() {
        box.write(RideSnapshot(
            s: s, speedMps: speed, cadenceRpm: idle ? 0 : request.cadence,
            powerW: idle ? 0 : 250, gradePct: route.grade(at: s), lateralM: 0.4,
            // Parked at speed 0 still counts as riding, so the chosen camera
            // holds still for screenshots; only -courseCameraOrbit (or the
            // shot plan's pause) is "not running".
            timestamp: CACurrentMediaTime(), isRunning: !idle
        ))
    }
}
