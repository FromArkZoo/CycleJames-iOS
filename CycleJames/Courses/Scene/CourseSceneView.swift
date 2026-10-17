import SwiftUI
import SceneKit
import QuartzCore

/// SwiftUI host for the 3D course. Builds the world off the main thread,
/// then on every rendered frame reads the latest `RideSnapshot`, places the
/// rider and moves the camera.
struct CourseSceneView: UIViewRepresentable {
    let bundle: CourseBundle
    let stateBox: RideStateBox
    var cameraMode: CameraMode = .chase
    var quality: GraphicsQuality = .balanced
    var onProgress: (Double, String) -> Void = { _, _ in }
    var onReady: () -> Void = {}
    var onError: (Error) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(stateBox: stateBox)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        view.backgroundColor = .black
        view.antialiasingMode = quality == .battery ? .none : .multisampling4X
        view.isPlaying = true
        view.rendersContinuously = true
        view.isJitteringEnabled = false
        view.delegate = context.coordinator
        context.coordinator.cameraMode = cameraMode

        let bundle = bundle, quality = quality
        let onProgress = onProgress, onReady = onReady, onError = onError
        let coordinator = context.coordinator
        coordinator.buildTask = Task.detached(priority: .userInitiated) { [weak view] in
            do {
                let world = try await CourseWorldBuilder.build(bundle: bundle, quality: quality) { p, label in
                    Task { @MainActor in onProgress(p, label) }
                }
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let view else { return }
                    coordinator.attach(world: world, to: view)
                    onReady()
                }
            } catch {
                await MainActor.run { onError(error) }
            }
        }
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.cameraMode = cameraMode
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.buildTask?.cancel()
        view.isPlaying = false
        view.delegate = nil
        view.scene = nil
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        let stateBox: RideStateBox
        var buildTask: Task<Void, Never>?
        private let lock = NSLock()
        private var world: CourseWorld?
        private var rider: RiderRig?
        private var cameraRig: CameraRig?
        private var lastFrameTime: CFTimeInterval = 0
        private var _cameraMode: CameraMode = .chase

        var cameraMode: CameraMode {
            get { lock.lock(); defer { lock.unlock() }; return _cameraMode }
            set { lock.lock(); _cameraMode = newValue; lock.unlock() }
        }

        init(stateBox: RideStateBox) {
            self.stateBox = stateBox
        }

        @MainActor
        func attach(world: CourseWorld, to view: SCNView) {
            let rider = RiderRig(quality: world.quality)
            let cameraRig = CameraRig(world: world)
            cameraRig.mode = cameraMode
            world.dynamicRoot.addChildNode(rider.node)
            world.dynamicRoot.addChildNode(cameraRig.node)

            // Pose everything once before the first frame so nothing pops.
            let snap = stateBox.read()
            let pose = world.route.pose(at: snap.s, lateral: snap.lateralM)
            rider.update(pose: pose, snapshot: snap, deltaTime: 0)
            cameraRig.update(riderPose: pose, s: snap.s, route: world.route, snapshot: snap, deltaTime: 0)

            lock.lock()
            self.world = world
            self.rider = rider
            self.cameraRig = cameraRig
            lock.unlock()

            view.preferredFramesPerSecond = world.preferredFramesPerSecond
            view.scene = world.scene
            view.pointOfView = cameraRig.node
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            lock.lock()
            let world = self.world, rider = self.rider, cameraRig = self.cameraRig
            let mode = _cameraMode
            lock.unlock()
            guard let world, let rider, let cameraRig else { return }

            let now = CACurrentMediaTime()
            let dt = lastFrameTime > 0 ? min(now - lastFrameTime, 0.1) : 0
            lastFrameTime = now

            let snap = stateBox.read()
            let s = snap.extrapolatedS(at: now, routeLength: world.route.length)
            let pose = world.route.pose(at: s, lateral: snap.lateralM)
            cameraRig.mode = mode
            rider.update(pose: pose, snapshot: snap, deltaTime: dt)
            cameraRig.update(riderPose: pose, s: s, route: world.route, snapshot: snap, deltaTime: dt)
            world.onFrame(cameraRig.node.simdWorldPosition, time)
        }
    }
}
