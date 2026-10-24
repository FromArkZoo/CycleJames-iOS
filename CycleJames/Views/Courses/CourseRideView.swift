import SwiftUI
import SwiftData
import UIKit

/// Full-screen 3D course ride: loading screen, then the scene with the HUD,
/// countdown, stop confirmation and finish card. Presented from
/// `CourseDetailView`.
struct CourseRideView: View {
    let courseID: String

    @StateObject private var controller = CourseRideController()
    @EnvironmentObject private var trainer: FTMSManager
    @EnvironmentObject private var hr: HRManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var cameraMode: CameraMode = CourseLaunchArgs.rideCamera ?? .chase
    /// Resolved once per ride; "auto" depends on battery and temperature.
    @State private var quality = GraphicsQuality.resolved(setting: AppSettings.graphicsQuality)
    @State private var sceneReady = false
    @State private var buildProgress: Double = 0
    @State private var buildLabel = "Loading course data"
    @State private var sceneError: String?
    @State private var showStopConfirm = false
    @State private var resumeOnCancel = false
    /// Set after Save & Stop; shows the finish card for a partial ride.
    @State private var stoppedOutcome: CourseRideOutcome?
    /// The ride in History. It is saved as soon as it ends (`.finished`),
    /// like a finished workout, so leaving the app on the finish card loses
    /// nothing.
    @State private var savedSession: RideSessionModel?
    @State private var saveFailed = false
    @State private var tooShortToSave = false
    @State private var riderWeightKg = AppSettings.riderWeightKg
    /// The scene's frame and the HUD's edges, all global, for the camera's
    /// framing: the rider is composed in the band the HUD leaves clear.
    @State private var sceneFrame = CGRect.zero
    @State private var hudTopMaxY: CGFloat?
    @State private var hudBottomMinY: CGFloat?

    private var summary: CourseSummary? { CourseCatalog.summary(id: courseID) }
    private var isDemo: Bool { CourseLaunchArgs.rideDemoCourseID == courseID }
    private var errorText: String? { controller.loadError ?? sceneError }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let bundle = controller.bundle {
                CourseSceneView(
                    bundle: bundle,
                    stateBox: controller.stateBox,
                    cameraMode: cameraMode,
                    quality: quality,
                    onProgress: { p, label in
                        buildProgress = 0.15 + 0.85 * p
                        buildLabel = label
                    },
                    onReady: sceneDidBecomeReady,
                    onError: { sceneError = $0.localizedDescription },
                    overlayInsets: hudInsets
                )
                // Measured inside `ignoresSafeArea` so it is the full-screen
                // frame the scene draws into, not the safe area.
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sceneFrame = $0 }
                .ignoresSafeArea()
            }

            if sceneReady, let summary {
                CourseRideHUD(
                    controller: controller,
                    summary: summary,
                    cameraMode: $cameraMode,
                    onStart: startRide,
                    onStop: requestStop,
                    onCoverChange: { top, bottom in
                        hudTopMaxY = top
                        hudBottomMinY = bottom
                    }
                )
                .transition(.opacity)
            }

            if !sceneReady || errorText != nil {
                CourseLoadingView(
                    summary: summary,
                    progress: buildProgress,
                    label: buildLabel,
                    error: errorText,
                    onClose: close
                )
                .transition(.opacity)
            }

            if controller.phase == .countdown {
                CourseCountdownOverlay(number: controller.countdownNumber)
            }

            #if DEBUG
            if sceneReady, CourseLaunchArgs.screenshotTrainerChips {
                TrainerChipGallery()
            }
            if sceneReady, CourseLaunchArgs.screenshotGearBadges {
                GearBadgeGallery()
            }
            #endif

            if showStopConfirm {
                CourseStopConfirmOverlay(
                    distanceToSummitM: controller.distanceToSummitM,
                    climbTimed: controller.climbElapsedSec != nil,
                    onSave: saveAndStop,
                    onDiscard: discardAndStop,
                    onCancel: cancelStop
                )
            }

            if let outcome = finishOutcome, let summary {
                CourseFinishOverlay(
                    courseName: summary.name,
                    outcome: outcome,
                    riderWeightKg: riderWeightKg,
                    saved: savedSession != nil,
                    saveFailed: saveFailed,
                    tooShortToSave: tooShortToSave,
                    onSave: save,
                    onDone: close,
                    onDiscard: discardAndStop
                )
                .transition(.opacity)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task {
            controller.bind(trainer: trainer, hr: hr)
            buildProgress = 0.05
            await controller.load(courseID: courseID)
            if controller.bundle != nil {
                buildProgress = max(buildProgress, 0.15)
                buildLabel = "Building the world"
            }
        }
        .onAppear {
            OrientationLock.shared.lock(CourseLaunchArgs.rideLandscape ? .landscapeRight : .allButUpsideDown)
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            OrientationLock.shared.lock(.portrait)
            UIApplication.shared.isIdleTimerDisabled = false
            controller.reset()
        }
        .onChange(of: controller.phase) { _, new in
            if new == .finished { save() }
            if new == .riding, isDemo, CourseLaunchArgs.rideStop, !showStopConfirm, stoppedOutcome == nil {
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    requestStop()
                }
            }
        }
        #if DEBUG
        .task(id: sceneReady) {
            // No Wattbike in the Simulator: one stands in, holding a gear
            // or shifting through a scripted run.
            guard sceneReady, CourseLaunchArgs.rideGear != nil || CourseLaunchArgs.rideGearDemo else { return }
            if let gear = CourseLaunchArgs.rideGear {
                GearDemo.hold(controller.gears, gear: gear, flash: CourseLaunchArgs.rideGearFlash)
                await GearDemo.connectTrainer(controller, watts: CourseLaunchArgs.rideWatts ?? 200)
            } else {
                let feed = controller.gears
                async let shifts: Void = GearDemo.run(feed)
                await GearDemo.connectTrainer(controller, watts: CourseLaunchArgs.rideWatts ?? 200)
                await shifts
            }
        }
        #endif
    }

    /// Points of the scene the HUD covers at the top and bottom.
    private var hudInsets: EdgeInsets {
        guard sceneReady, sceneFrame.height > 0 else { return EdgeInsets() }
        let top = hudTopMaxY.map { max(0, $0 - sceneFrame.minY) } ?? 0
        let bottom = hudBottomMinY.map { max(0, sceneFrame.maxY - $0) } ?? 0
        // Whole points, so sub-point layout jitter doesn't nudge the camera.
        return EdgeInsets(top: top.rounded(), leading: 0, bottom: bottom.rounded(), trailing: 0)
    }

    private var finishOutcome: CourseRideOutcome? {
        if let stoppedOutcome { return stoppedOutcome }
        if controller.phase == .finished, let result = controller.result {
            return CourseRideOutcome(result: result, climbOnVirtualPower: controller.climbUsedVirtualPower)
        }
        return nil
    }

    // MARK: Flow

    private func sceneDidBecomeReady() {
        withAnimation(.easeOut(duration: 0.4)) { sceneReady = true }
        if isDemo, !CourseLaunchArgs.rideHold { startRide() }
    }

    private func startRide() {
        guard controller.phase == .ready else { return }
        if isDemo {
            if CourseLaunchArgs.rideFinish, let length = controller.bundle?.route.length {
                controller.debugStartS = max(0, length - 6)
            } else if let s = CourseLaunchArgs.rideStartS {
                controller.debugStartS = s
            }
            if let w = CourseLaunchArgs.rideWatts { controller.virtualPowerW = w }
        }
        Task { await controller.start() }
    }

    private func requestStop() {
        switch controller.phase {
        case .riding:
            controller.pauseOrResume()
            resumeOnCancel = true
            showStopConfirm = true
        case .paused:
            resumeOnCancel = false
            showStopConfirm = true
        case .finished:
            break
        default:
            // Nothing recorded yet: just leave.
            close()
        }
    }

    private func cancelStop() {
        showStopConfirm = false
        if resumeOnCancel, controller.phase == .paused { controller.pauseOrResume() }
        resumeOnCancel = false
    }

    private func saveAndStop() {
        showStopConfirm = false
        resumeOnCancel = false
        save()
        // Saving mid-ride ends it, so the controller's result normally covers
        // the finish card; fall back to the live values if it has none.
        if controller.result == nil {
            withAnimation { stoppedOutcome = CourseRideOutcome(stopped: controller, session: savedSession) }
        }
    }

    /// Discard & Stop, or Discard on the finish card. A finished ride is
    /// already in History by then, so it is deleted there, and a personal
    /// best it set goes with it.
    private func discardAndStop() {
        showStopConfirm = false
        if let savedSession {
            RideHistory.delete(savedSession, in: modelContext)
            self.savedSession = nil
        }
        controller.discard()
        close()
    }

    private func save() {
        guard savedSession == nil, !tooShortToSave else { return }
        savedSession = controller.saveRide(context: modelContext)
        guard savedSession == nil else { return }
        // Nil also means under a second was ridden: nothing to keep rather
        // than a failure.
        if controller.elapsedSec < 1 { tooShortToSave = true } else { saveFailed = true }
    }

    private func close() {
        dismiss()
    }
}

