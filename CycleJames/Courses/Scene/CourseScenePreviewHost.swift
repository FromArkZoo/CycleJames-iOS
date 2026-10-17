import SwiftUI
import QuartzCore

/// Development-only entry point that opens straight into the 3D scene with a
/// scripted rider, for screenshots and visual checks in the Simulator.
///
///     -coursePreview koppenberg     course id (required)
///     -courseStartS 450             start distance along the route, m
///     -courseSpeedKph 8             constant speed; 0 = parked
///     -courseCadence 70             crank rpm
///     -courseCamera chase           chase | close | firstPerson | broadcast
///     -courseQuality high           high | balanced | battery
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
    }

    static let request: Request? = {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let id = value("-coursePreview") else { return nil }
        return Request(
            courseID: id,
            startS: value("-courseStartS").flatMap(Double.init) ?? 0,
            speedKph: value("-courseSpeedKph").flatMap(Double.init) ?? 10,
            cadence: value("-courseCadence").flatMap(Double.init) ?? 80,
            camera: value("-courseCamera").flatMap(CameraMode.init(rawValue:)) ?? .chase,
            quality: value("-courseQuality").flatMap(GraphicsQuality.init(rawValue:)) ?? .high
        )
    }()

    let request: Request
    @State private var bundle: CourseBundle?
    @State private var error: String?
    @State private var progressLabel = "Loading"
    @State private var camera: CameraMode
    @State private var driver: PreviewDriver?
    private let stateBox = RideStateBox()

    init(request: Request) {
        self.request = request
        _camera = State(initialValue: request.camera)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let bundle {
                CourseSceneView(
                    bundle: bundle,
                    stateBox: stateBox,
                    cameraMode: camera,
                    quality: request.quality,
                    onProgress: { _, label in progressLabel = label },
                    onReady: { progressLabel = "" },
                    onError: { error = $0.localizedDescription }
                )
                .ignoresSafeArea()
                .onTapGesture { camera = camera.next }
            }
            if let error {
                Text(error).foregroundStyle(.red).padding()
            } else if !progressLabel.isEmpty {
                Text(progressLabel).foregroundStyle(.white).padding()
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

    init(route: CourseRoute, request: CourseScenePreviewHost.Request, box: RideStateBox) {
        self.route = route
        self.request = request
        self.box = box
        self.s = request.startS
    }

    func start() {
        last = CACurrentMediaTime()
        publish()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step() }
        }
    }

    private func step() {
        let now = CACurrentMediaTime()
        s += request.speedKph / 3.6 * (now - last)
        if s >= route.length { s = request.startS }
        last = now
        publish()
    }

    private func publish() {
        box.write(RideSnapshot(
            s: s, speedMps: request.speedKph / 3.6, cadenceRpm: request.cadence,
            powerW: 250, gradePct: route.grade(at: s), lateralM: 0.4,
            timestamp: CACurrentMediaTime(), isRunning: request.speedKph > 0
        ))
    }
}
