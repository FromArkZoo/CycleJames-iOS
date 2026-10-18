import SwiftUI
import SceneKit
import QuartzCore

/// SwiftUI host for the 3D course. Builds the world off the main thread,
/// then on every rendered frame reads the latest `RideSnapshot`, places the
/// rider and moves the camera.
///
/// Rendering stops while the view is off screen or the app is in the
/// background, and resumes when it's back. The frame rate drops to 30 when
/// the phone runs hot or Low Power Mode is on, and an automatic tier sheds
/// effects live when the phone can't keep up (`LiveQualityGovernor`).
struct CourseSceneView: UIViewRepresentable {
    let bundle: CourseBundle
    let stateBox: RideStateBox
    var cameraMode: CameraMode = .chase
    var quality: GraphicsQuality = .balanced
    /// True when `quality` was picked automatically, so it may step down
    /// mid-ride; an explicit choice in Settings is kept as it is.
    var adaptsQuality = GraphicsQuality.isAutomatic(setting: AppSettings.graphicsQuality)
    var onProgress: (Double, String) -> Void = { _, _ in }
    var onReady: () -> Void = {}
    var onError: (Error) -> Void = { _ in }
    /// How far overlays (a ride HUD) cover the scene from the top and bottom
    /// of this view, in points. The chase, close, broadcast and paused shots
    /// keep the rider in the part left clear.
    var overlayInsets = EdgeInsets()
    /// Development hooks (preview host only); leave nil in the app.
    var debug: CourseSceneDebug?

    func makeCoordinator() -> Coordinator {
        Coordinator(stateBox: stateBox)
    }

    func makeUIView(context: Context) -> SCNView {
        #if DEBUG
        CourseLogDump.scheduleIfRequested()
        #endif
        let view = CourseRenderView(frame: .zero, options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue,
        ])
        view.backgroundColor = .black
        view.antialiasingMode = Self.antialiasing(for: quality)
        if quality == .battery {
            // ~45 % fewer pixels than native 3x; the biggest single saving.
            view.contentScaleFactor = 2
        }
        view.isJitteringEnabled = false
        view.showsStatistics = debug?.showsStatistics ?? false
        view.delegate = context.coordinator

        let coordinator = context.coordinator
        view.onFramingInsets = { [weak coordinator] top, bottom in
            coordinator?.framingInsets = (top, bottom)
        }
        view.overlayInsets = overlayInsets
        coordinator.cameraMode = cameraMode
        coordinator.transitionSeconds = debug?.transitionSeconds
        coordinator.onAttach = debug?.onAttach
        coordinator.onCoordinator = debug?.onCoordinator
        coordinator.onView = debug?.onView
        coordinator.view = view
        coordinator.adaptsQuality = adaptsQuality

        let bundle = bundle, quality = quality
        let onProgress = onProgress, onReady = onReady, onError = onError
        let opened = CACurrentMediaTime()
        // One world build at a time: a ride closed mid-build and opened again
        // waits for the cancelled build to wind down (it stops within a chunk
        // of work) rather than doubling the peak memory.
        let previous = Self.lastBuild
        let task = Task.detached(priority: .userInitiated) {
            await previous?.value
            do {
                try Task.checkCancellation()
                // The rider (textures, meshes) builds alongside the world, the
                // camera (its clearance model) after it: about a second between
                // them that would otherwise stall the main thread at attach.
                async let riderRig = RiderRig(quality: quality, surfaceNames: bundle.route.surfaceNames)
                let world = try await CourseWorldBuilder.build(bundle: bundle, quality: quality) { p, label in
                    Task { @MainActor in onProgress(p, label) }
                }
                try Task.checkCancellation()
                let cameraRig = CameraRig(world: world)
                let rider = await riderRig
                let built = CACurrentMediaTime()
                try Task.checkCancellation()
                // In the scene before it is prepared, so the rider's materials
                // are uploaded and compiled with the world's.
                world.dynamicRoot.addChildNode(rider.node)
                world.dynamicRoot.addChildNode(cameraRig.node)
                // Upload geometry and textures and compile shaders before the
                // first frame, so the ride doesn't open with a hitch. Capped:
                // if SceneKit is slow to report back, show the world anyway.
                // GPU work needs the app in the foreground.
                await MainActor.run { onProgress(0.99, "Warming up") }
                try await CourseWorldBuilder.waitForForeground()
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    let once = ResumeOnce(done)
                    Task { @MainActor in
                        guard let view = coordinator.view else { return once.resume() }
                        view.prepare([world.scene]) { _ in once.resume() }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 4) { once.resume() }
                }
                try Task.checkCancellation()
                let prepared = CACurrentMediaTime()
                await MainActor.run {
                    guard let view = coordinator.view, !coordinator.isDismantled else { return }
                    let attached = CACurrentMediaTime()
                    // Ready once the first frames are drawn: the camera's HDR,
                    // bloom and SSAO passes compile on the first frame, behind
                    // the loading screen rather than as a frozen first view.
                    coordinator.attach(world: world, rider: rider, cameraRig: cameraRig, to: view) {
                        onReady()
                        #if DEBUG
                        Self.logTiming(quality: quality, build: built - opened, prepare: prepared - built,
                                       attach: attached - prepared, firstFrames: CACurrentMediaTime() - attached)
                        #endif
                    }
                }
            } catch is CancellationError {
                // The view went away mid-build.
            } catch {
                await MainActor.run {
                    if !coordinator.isDismantled { onError(error) }
                }
            }
        }
        coordinator.buildTask = task
        Self.lastBuild = task
        return view
    }

    /// The most recent world build, finished or not (main thread).
    @MainActor private static var lastBuild: Task<Void, Never>?

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.cameraMode = cameraMode
        // Follow a caller that hands over a different mailbox (e.g. one
        // re-created with its view), or the scene would read a stale one.
        context.coordinator.stateBox = stateBox
        if let view = view as? CourseRenderView, view.overlayInsets != overlayInsets {
            view.overlayInsets = overlayInsets
        }
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.isDismantled = true
        coordinator.buildTask?.cancel()
        (view as? CourseRenderView)?.stopObserving()
        view.isPlaying = false
        view.delegate = nil
        view.scene = nil
        coordinator.detach()
    }

    #if DEBUG
    /// Development aid: how long the view took to show the world, written to
    /// the app's temporary directory (cj_scene_timing.txt).
    private static func logTiming(quality: GraphicsQuality, build: Double, prepare: Double, attach: Double,
                                  firstFrames: Double) {
        let total = build + prepare + attach + firstFrames
        let text = String(format: "scene %@: build (world, rider, camera) %.2f s, prepare %.2f s, attach %.2f s, first frames %.2f s, total %.2f s\n",
                          quality.rawValue, build, prepare, attach, firstFrames, total)
        print(text, terminator: "")
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cj_scene_timing.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
    #endif

    static func antialiasing(for quality: GraphicsQuality) -> SCNAntialiasingMode {
        switch quality {
        case .high: .multisampling4X
        case .balanced: .multisampling2X
        case .battery: .none
        }
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        var buildTask: Task<Void, Never>?
        /// Main thread only.
        var isDismantled = false
        /// Whether the tier may step down live (main thread, before attach).
        var adaptsQuality = false
        var onAttach: ((CourseWorld) -> Void)?
        var onCoordinator: ((Coordinator) -> Void)?
        var onView: ((SCNView) -> Void)?
        weak var view: SCNView?
        private let lock = NSLock()
        private var world: CourseWorld?
        private var rider: RiderRig?
        private var cameraRig: CameraRig?
        private var lastFrameTime: CFTimeInterval = 0
        /// Frames drawn so far (development HUD).
        private(set) var frameCount = 0
        private var _cameraMode: CameraMode = .chase
        private var _transitionSeconds: Double?
        private var _stateBox: RideStateBox
        private var _framingInsets: (top: Float, bottom: Float) = (0, 0)
        /// Render thread only.
        private var headHidden = false
        /// Frames drawn since attach, and what to call once enough are.
        private var framesSinceAttach = 0
        private var onFirstFrames: (() -> Void)?
        /// Frames drawn before the world counts as ready.
        private static let warmupFrames = 2
        private var governor: LiveQualityGovernor?

        /// Live fallback steps taken so far (development read-outs).
        var liveQualitySteps: [LiveQualityGovernor.Rung] {
            lock.lock(); defer { lock.unlock() }
            return governor?.taken ?? []
        }

        var cameraMode: CameraMode {
            get { lock.lock(); defer { lock.unlock() }; return _cameraMode }
            set { lock.lock(); _cameraMode = newValue; lock.unlock() }
        }

        var transitionSeconds: Double? {
            get { lock.lock(); defer { lock.unlock() }; return _transitionSeconds }
            set { lock.lock(); _transitionSeconds = newValue; lock.unlock() }
        }

        var stateBox: RideStateBox {
            get { lock.lock(); defer { lock.unlock() }; return _stateBox }
            set { lock.lock(); _stateBox = newValue; lock.unlock() }
        }

        /// Fractions of the view height covered at the top and bottom.
        var framingInsets: (top: Float, bottom: Float) {
            get { lock.lock(); defer { lock.unlock() }; return _framingInsets }
            set { lock.lock(); _framingInsets = newValue; lock.unlock() }
        }

        init(stateBox: RideStateBox) {
            _stateBox = stateBox
        }

        /// Shows the world, with the rider and camera already in its scene.
        /// `ready` runs on the main thread once the first frames are drawn
        /// (or after a few seconds if nothing draws, e.g. in the background).
        @MainActor
        func attach(world: CourseWorld, rider: RiderRig, cameraRig: CameraRig, to view: SCNView,
                    ready: @escaping () -> Void) {
            cameraRig.mode = cameraMode
            cameraRig.riderEye = rider.eyeNode
            cameraRig.framingInsets = framingInsets
            if let t = transitionSeconds { cameraRig.transitionDuration = t }
            let size = view.bounds.size
            if size.width > 0, size.height > 0 {
                cameraRig.viewportAspect = Float(size.width / size.height)
            }
            // Pose everything once before the first frame so nothing pops.
            let snap = stateBox.read()
            let pose = world.route.pose(at: snap.s, lateral: snap.lateralM)
            rider.update(pose: pose, snapshot: snap, deltaTime: 0)
            cameraRig.update(riderPose: pose, s: snap.s, route: world.route, snapshot: snap, deltaTime: 0)
            headHidden = cameraRig.hidesRiderHead
            rider.setHeadVisible(!headHidden)

            var readyOnce: (() -> Void)? = ready
            let fireReady: @MainActor () -> Void = { [weak self] in
                let r = readyOnce
                readyOnce = nil
                guard let self, !self.isDismantled else { return }
                r?()
            }
            let governor = adaptsQuality
                ? LiveQualityGovernor(built: world.quality, screenScale: Double(view.traitCollection.displayScale),
                                      targetFps: world.preferredFramesPerSecond)
                : nil
            lock.lock()
            self.world = world
            self.rider = rider
            self.cameraRig = cameraRig
            self.governor = governor
            lastFrameTime = 0
            framesSinceAttach = 0
            onFirstFrames = { DispatchQueue.main.async { MainActor.assumeIsolated { fireReady() } } }
            lock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { fireReady() } }

            if let view = view as? CourseRenderView {
                view.governor = governor
                view.baseFramesPerSecond = world.preferredFramesPerSecond
            } else {
                view.preferredFramesPerSecond = world.preferredFramesPerSecond
            }
            view.scene = world.scene
            view.pointOfView = cameraRig.node
            (view as? CourseRenderView)?.sceneReady = true
            onView?(view)
            onAttach?(world)
            onCoordinator?(self)
        }

        /// Drops the world so its memory goes with the view.
        func detach() {
            lock.lock()
            world = nil
            rider = nil
            cameraRig = nil
            governor = nil
            onFirstFrames = nil
            lock.unlock()
        }

        func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
            lock.lock()
            let world = self.world, governor = self.governor
            framesSinceAttach += 1
            var firstFrames: (() -> Void)?
            if framesSinceAttach >= Self.warmupFrames, let f = onFirstFrames {
                firstFrames = f
                onFirstFrames = nil
            }
            lock.unlock()
            firstFrames?()
            guard let world, let rung = governor?.frameRendered(at: CACurrentMediaTime()) else { return }
            apply(rung, world: world, renderer: renderer)
        }

        /// One live fallback step: scene parts here on the render thread
        /// (sun shadows, grass reach, the camera's SSAO and bloom), view
        /// parts (MSAA, render scale, frame rate) on the main thread.
        private func apply(_ rung: LiveQualityGovernor.Rung, world: CourseWorld, renderer: SCNSceneRenderer) {
            switch rung {
            case .tier(let q):
                let config = WorldConfig.make(q)
                world.applyLiveConfig(config)
                if let camera = renderer.pointOfView?.camera { SkyLighting.applyEffects(camera, config: config) }
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let view = self?.view as? CourseRenderView else { return }
                        view.antialiasingMode = CourseSceneView.antialiasing(for: q)
                        view.baseFramesPerSecond = min(view.baseFramesPerSecond, config.fps)
                        if q == .battery, view.contentScaleFactor > 2 { view.contentScaleFactor = 2 }
                    }
                }
            case .renderScale(let scale):
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let view = self?.view, view.contentScaleFactor > CGFloat(scale) else { return }
                        view.contentScaleFactor = CGFloat(scale)
                    }
                }
            }
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            lock.lock()
            let world = self.world, rider = self.rider, cameraRig = self.cameraRig
            let mode = _cameraMode, stateBox = _stateBox, insets = _framingInsets
            lock.unlock()
            guard let world, let rider, let cameraRig else { return }

            frameCount &+= 1
            let now = CACurrentMediaTime()
            // Clamped so a resume after a pause doesn't fling the springs.
            let dt = lastFrameTime > 0 ? min(now - lastFrameTime, 0.1) : 0
            lastFrameTime = now

            let viewport = renderer.currentViewport
            if viewport.width > 0, viewport.height > 0 {
                cameraRig.viewportAspect = Float(viewport.width / viewport.height)
            }
            let snap = stateBox.read()
            let s = snap.extrapolatedS(at: now, routeLength: world.route.length)
            let pose = world.route.pose(at: s, lateral: snap.lateralM)
            cameraRig.mode = mode
            cameraRig.framingInsets = insets
            rider.update(pose: pose, snapshot: snap, deltaTime: dt)
            cameraRig.update(riderPose: pose, s: s, route: world.route, snapshot: snap, deltaTime: dt)
            // Rider view: the camera is inside the head, so it goes (and comes
            // back as the camera leaves).
            if cameraRig.hidesRiderHead != headHidden {
                headHidden = cameraRig.hidesRiderHead
                rider.setHeadVisible(!headHidden)
            }
            world.onFrame(cameraRig.node.simdWorldPosition, time)
        }
    }
}

/// Resumes a continuation exactly once, whichever caller gets there first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}

/// Development hooks for the preview host.
struct CourseSceneDebug {
    var showsStatistics = false
    /// Overrides the camera's mode-change blend time.
    var transitionSeconds: Double?
    /// Called once with the scene view when the world is showing, e.g. to
    /// take snapshots.
    var onView: ((SCNView) -> Void)?
    /// Called on the main thread once the world is showing.
    var onAttach: ((CourseWorld) -> Void)?
    var onCoordinator: ((CourseSceneView.Coordinator) -> Void)?
}

/// SCNView that only draws while it is in a window and the app is in the
/// foreground: no GPU work in the background (iOS kills apps for it) and no
/// battery spent on a ride screen that's covered. A system alert or Control
/// Centre over the ride leaves it running. A ride lasts an hour with the
/// phone on the bars, so it also drops to 30 fps when the phone is hot or in
/// Low Power Mode.
final class CourseRenderView: SCNView {
    /// Set once the world is attached; nothing to draw before that.
    var sceneReady = false { didSet { updatePlaying() } }
    /// The world's frame rate, before any thermal or power cap.
    var baseFramesPerSecond = 60 { didSet { updateFrameRate() } }
    /// Live fallback for an automatic tier: told the frame rate asked for,
    /// and asked to step down when the phone turns hot.
    var governor: LiveQualityGovernor? { didSet { updateFrameRate() } }
    /// Overlay cover in points; reported as fractions of the height.
    var overlayInsets = EdgeInsets() { didSet { reportFraming() } }
    var onFramingInsets: ((Float, Float) -> Void)?
    private var inForeground = UIApplication.shared.applicationState != .background
    private var observers: [NSObjectProtocol] = []

    override init(frame: CGRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setForeground(false) }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setForeground(true) }
            },
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.thermalStateChanged() }
            },
            center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateFrameRate() }
            },
        ]
        isPlaying = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    func stopObserving() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        sceneReady = false
    }

    private func setForeground(_ foreground: Bool) {
        inForeground = foreground
        updatePlaying()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updatePlaying()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportFraming()
    }

    private var reportedFraming: (Float, Float)?

    private func reportFraming() {
        let height = bounds.height
        guard height > 1 else { return }
        let top = Float(max(overlayInsets.top, 0) / height)
        let bottom = Float(max(overlayInsets.bottom, 0) / height)
        if let last = reportedFraming, last == (top, bottom) { return }
        reportedFraming = (top, bottom)
        onFramingInsets?(top, bottom)
    }

    private func updatePlaying() {
        let play = sceneReady && inForeground && window != nil
        if isPlaying != play { isPlaying = play }
        rendersContinuously = play
    }

    private func updateFrameRate() {
        let info = ProcessInfo.processInfo
        let constrained = info.thermalState == .serious || info.thermalState == .critical || info.isLowPowerModeEnabled
        let fps = constrained ? min(baseFramesPerSecond, 30) : baseFramesPerSecond
        if preferredFramesPerSecond != fps { preferredFramesPerSecond = fps }
        governor?.setTargetFps(fps)
    }

    private var lastThermal = ProcessInfo.processInfo.thermalState

    /// Caps the frame rate and, for an automatic tier, sheds effects each
    /// time the phone gets hotter from serious upwards: the frame cap alone
    /// does nothing once the frame rate is already under it.
    private func thermalStateChanged() {
        let state = ProcessInfo.processInfo.thermalState
        if state.rawValue > lastThermal.rawValue, state == .serious || state == .critical {
            governor?.requestStep(reason: "thermal state \(state == .critical ? "critical" : "serious")")
        }
        lastThermal = state
        updateFrameRate()
    }
}
