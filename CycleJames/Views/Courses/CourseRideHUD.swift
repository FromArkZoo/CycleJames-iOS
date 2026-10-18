import SwiftUI

/// Everything drawn over the 3D scene during a course ride. Metrics sit along
/// the top (portrait) or the sides (landscape) so the road in the middle of
/// the screen stays clear.
struct CourseRideHUD: View {
    @ObservedObject var controller: CourseRideController
    let summary: CourseSummary
    @Binding var cameraMode: CameraMode
    var onStart: () -> Void
    var onStop: () -> Void
    /// How far the HUD covers the screen, in global coordinates: the bottom
    /// edge of the cards along the top and the top edge of the panel along
    /// the bottom (nil when there is none). The ride view turns this into the
    /// camera's framing, so the rider isn't drawn under the panels.
    var onCoverChange: (_ topMaxY: CGFloat?, _ bottomMinY: CGFloat?) -> Void = { _, _ in }

    @EnvironmentObject private var trainer: FTMSManager
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var difficultyPct = AppSettings.trainerDifficultyPct
    /// Portrait: the power slider opens on demand above the ride buttons.
    @State private var showPowerSlider = false
    /// Portrait: the camera button is icon-only, so name the new view briefly.
    @State private var showCameraName = false
    /// Set once a trainer has powered this ride, so losing it shows the
    /// reconnect banner rather than silently switching to virtual power.
    @State private var hadTrainer = false
    /// Measured HUD edges, kept per layout so a rotation can't mix the two.
    @State private var cover = HUDCover()

    private var landscape: Bool { verticalSizeClass == .compact }
    private var phase: CourseRideController.Phase { controller.phase }
    private var isReady: Bool { phase == .ready || phase == .countdown }
    private var showTrainerDropped: Bool {
        hadTrainer && !controller.trainerConnected && (phase == .riding || phase == .paused)
    }

    var body: some View {
        Group {
            if landscape { landscapeLayout } else { portraitLayout }
        }
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.2), value: phase)
        .animation(.easeInOut(duration: 0.2), value: showTrainerDropped)
        .onAppear { if controller.trainerConnected { hadTrainer = true } }
        .onChange(of: controller.trainerConnected) { _, connected in
            if connected { hadTrainer = true }
        }
        .onChange(of: cover) { _, _ in reportCover() }
        .onChange(of: landscape) { _, _ in reportCover() }
        .onAppear(perform: reportCover)
    }

    private func reportCover() {
        if landscape {
            onCoverChange(cover.landscapeTop, cover.landscapeBottom)
        } else {
            onCoverChange(cover.portraitTop, cover.portraitBottom)
        }
    }

    // MARK: Layouts

    private var portraitLayout: some View {
        VStack(spacing: CJSpacing.s) {
            VStack(spacing: CJSpacing.s) {
                metricsStrip
                HStack(alignment: .top, spacing: CJSpacing.s) {
                    climbPanel.frame(maxWidth: 190, alignment: .leading)
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: CJSpacing.xs) {
                        GradeBadge(pct: controller.gradePct)
                        SurfaceChip(surface: controller.surfaceName)
                    }
                }
            }
            .modifier(CoverEdge(edge: .top, value: $cover.portraitTop))
            Spacer(minLength: 0)
            if showTrainerDropped { trainerDroppedBanner }
            if phase == .paused { pausedBanner }
            if showCameraName {
                Text(cameraMode.label)
                    .font(CJFont.bodyBold)
                    .padding(.horizontal, CJSpacing.m)
                    .padding(.vertical, CJSpacing.xs)
                    .hudPanel(cornerRadius: CJRadius.chip)
                    .transition(.opacity)
            }
            bottomPanel
                .modifier(CoverEdge(edge: .bottom, value: $cover.portraitBottom))
        }
        .task(id: cameraMode) {
            // Shown for a moment after each change, not on first appear.
            guard showCameraName else { return }
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if !Task.isCancelled { withAnimation { showCameraName = false } }
        }
        .padding(.horizontal, CJSpacing.s)
        .padding(.top, CJSpacing.xxs)
        .padding(.bottom, CJSpacing.xxs)
    }

    /// Landscape: metrics down the left, climb and controls down the right,
    /// the profile across the sky at the top. Nothing sits over the road
    /// while riding; the start row only shows before the ride.
    private var landscapeLayout: some View {
        HStack(alignment: .top, spacing: CJSpacing.s) {
            VStack(spacing: CJSpacing.xs) {
                metricTile(powerMetric)
                metricTile(speedMetric)
                metricTile(cadenceMetric)
                metricTile(hrMetric)
                Spacer(minLength: 0)
                if controller.usingVirtualPower {
                    VirtualPowerControl(watts: $controller.virtualPowerW, style: .stacked)
                        .padding(CJSpacing.xs)
                        .hudPanel(cornerRadius: CJRadius.card)
                }
            }
            .frame(width: 128)

            VStack(spacing: CJSpacing.s) {
                profilePanel(height: 30).frame(maxWidth: 440)
                    .modifier(CoverEdge(edge: .top, value: $cover.landscapeTop))
                if showTrainerDropped { trainerDroppedBanner.frame(maxWidth: 440) }
                Spacer(minLength: 0)
                if phase == .paused { pausedBanner }
                if isReady {
                    VStack(spacing: CJSpacing.xs) {
                        startNotice
                        startRow
                    }
                        .padding(CJSpacing.s)
                        .hudPanel()
                        .frame(maxWidth: 440)
                        .modifier(CoverEdge(edge: .bottom, value: $cover.landscapeBottom))
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .trailing, spacing: CJSpacing.xs) {
                GradeBadge(pct: controller.gradePct)
                SurfaceChip(surface: controller.surfaceName)
                climbPanel.frame(width: 176, alignment: .leading)
                Spacer(minLength: 0)
                if !isReady, phase != .finished { landscapeControls }
            }
            .frame(width: 176)
        }
        .padding(.horizontal, CJSpacing.xs)
        .padding(.vertical, CJSpacing.xs)
    }

    // MARK: Metrics

    private struct Metric {
        let label: String
        let value: String
        let unit: String
        var sub: String? = nil
        var large = false
    }

    private var powerMetric: Metric {
        Metric(
            label: "Power",
            value: "\(controller.powerW)",
            unit: "W",
            sub: String(format: "%.2f W/kg", controller.wattsPerKg),
            large: true
        )
    }

    private var speedMetric: Metric {
        Metric(label: "Speed", value: String(format: "%.1f", controller.speedKph), unit: "km/h")
    }

    private var cadenceMetric: Metric {
        Metric(label: "Cadence", value: controller.cadenceRpm > 0 ? "\(controller.cadenceRpm)" : "--", unit: "rpm")
    }

    private var hrMetric: Metric {
        Metric(label: "HR", value: controller.heartRate > 0 ? "\(controller.heartRate)" : "--", unit: "bpm")
    }

    private var metricsStrip: some View {
        HStack(spacing: 0) {
            // Power takes the slack; the others keep a steady minimum width so
            // the dividers don't shuffle as digits change.
            metricCell(powerMetric).frame(maxWidth: .infinity, alignment: .leading)
            divider
            metricCell(speedMetric).fixedSize().frame(minWidth: 74, alignment: .leading)
            divider
            metricCell(cadenceMetric).fixedSize().frame(minWidth: 56, alignment: .leading)
            divider
            metricCell(hrMetric).fixedSize().frame(minWidth: 56, alignment: .leading)
        }
        .padding(.vertical, CJSpacing.s)
        .padding(.horizontal, CJSpacing.m)
        .hudPanel()
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(width: 1, height: 36)
            .padding(.horizontal, CJSpacing.s)
    }

    private func metricTile(_ m: Metric) -> some View {
        metricCell(m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CJSpacing.s)
            .padding(.vertical, CJSpacing.xs)
            .hudPanel(cornerRadius: CJRadius.card)
    }

    private func metricCell(_ m: Metric) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(m.label.uppercased())
                .font(CJFont.labelUpper)
                .foregroundStyle(Color.white.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(m.value)
                    .font(m.large ? CJFont.metricMedium : CJFont.metricSmall)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(m.unit)
                    .font(CJFont.caption)
                    .foregroundStyle(Color.white.opacity(0.72))
                    .lineLimit(1)
                    .fixedSize()
            }
            if let sub = m.sub {
                Text(sub)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CJColors.accent)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Climb timer

    private var climbStartS: Double { controller.bundle?.climb.startS ?? summary.climbStartS }

    @ViewBuilder
    private var climbPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            if controller.climbElapsedSec == nil {
                // Before the timing line, or started past it (no time).
                let beforeClimb = controller.distanceM < climbStartS
                Text(summary.name.uppercased())
                    .font(CJFont.labelUpper)
                    .foregroundStyle(Color.white.opacity(0.72))
                    .lineLimit(1)
                Text(beforeClimb
                     ? "Climb in \(CourseFormat.distance(climbStartS - controller.distanceM))"
                     : (controller.distanceToSummitM > 0
                        ? "\(CourseFormat.distance(controller.distanceToSummitM)) to summit"
                        : "Over the top"))
                    .font(CJFont.bodyBold)
                    .monospacedDigit()
                Text(controller.personalBestSec.map { "PB \(CourseFormat.climbTime($0))" } ?? "No PB yet")
                    .font(CJFont.caption)
                    .foregroundStyle(controller.personalBestSec == nil ? Color.white.opacity(0.6) : CJColors.positionMarker)
                    .monospacedDigit()
                if !beforeClimb {
                    Text("Not timed: started on the climb")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.6))
                } else if controller.usingVirtualPower {
                    virtualPowerNoPB
                }
            } else {
                let atSummit = controller.distanceToSummitM <= 0
                HStack(spacing: 4) {
                    Image(systemName: atSummit ? "flag.checkered" : "stopwatch.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(atSummit ? "SUMMIT" : "CLIMB")
                        .font(CJFont.labelUpper)
                }
                .foregroundStyle(Color.white.opacity(0.72))
                HStack(alignment: .firstTextBaseline, spacing: CJSpacing.xs) {
                    Text(CourseFormat.climbTime(controller.climbElapsedSec ?? 0))
                        .font(CJFont.metricSmall)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let delta = controller.pbDeltaSec {
                        Text(CourseFormat.delta(delta))
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .foregroundStyle(.white)
                            .background(delta <= 0 ? CJColors.success : CJColors.danger, in: Capsule())
                    }
                }
                if atSummit {
                    let left = max(0, (controller.bundle?.route.length ?? summary.totalLengthM) - controller.distanceM)
                    Text(left > 1 ? "Finish in \(CourseFormat.distance(left))" : "Finished")
                        .font(CJFont.caption)
                        .foregroundStyle(Color.white.opacity(0.8))
                        .monospacedDigit()
                } else {
                    Text("\(CourseFormat.distance(controller.distanceToSummitM)) to summit")
                        .font(CJFont.caption)
                        .foregroundStyle(Color.white.opacity(0.8))
                        .monospacedDigit()
                    ProgressView(value: min(max(controller.climbProgress, 0), 1))
                        .tint(CJColors.positionMarker)
                        .scaleEffect(x: 1, y: 0.8, anchor: .center)
                        .padding(.top, 2)
                }
                if controller.climbUsedVirtualPower { virtualPowerNoPB }
            }
        }
        .padding(.horizontal, CJSpacing.m)
        .padding(.vertical, CJSpacing.s)
        // Landscape: fill the side column so its edges line up with the
        // controls panel below.
        .frame(minWidth: 150, maxWidth: landscape ? .infinity : nil, alignment: .leading)
        .hudPanel()
        .accessibilityElement(children: .combine)
    }

    /// A climb ridden (even partly) on the power control can't set a PB.
    private var virtualPowerNoPB: some View {
        Text("Virtual power: no PB")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.6))
    }

    // MARK: Bottom panel

    /// Portrait: profile and controls in one panel under the rider. While
    /// riding it stays short (power steps and the ride buttons on one row) so
    /// the rider isn't hidden; before the start it has room for the slider.
    private var bottomPanel: some View {
        VStack(spacing: CJSpacing.xs) {
            profileContent(height: isReady ? 48 : 34)
            if isReady {
                if controller.usingVirtualPower {
                    VirtualPowerControl(watts: $controller.virtualPowerW)
                }
                startNotice
                startRow
            } else if phase != .finished {
                if controller.usingVirtualPower && showPowerSlider {
                    VirtualPowerControl(watts: $controller.virtualPowerW) {
                        withAnimation(.easeInOut(duration: 0.2)) { showPowerSlider = false }
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                ridingRow
            }
        }
        .padding(CJSpacing.s)
        .hudPanel()
        .task(id: "\(showPowerSlider)-\(controller.virtualPowerW)") {
            // Fold the slider away a few seconds after the last change.
            guard showPowerSlider else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { withAnimation(.easeInOut(duration: 0.2)) { showPowerSlider = false } }
        }
    }

    private var ridingRow: some View {
        HStack(spacing: CJSpacing.s) {
            if controller.usingVirtualPower && !showPowerSlider {
                VirtualPowerControl(watts: $controller.virtualPowerW, style: .inline) {
                    withAnimation(.easeInOut(duration: 0.2)) { showPowerSlider = true }
                }
            } else {
                trainerChip
            }
            Spacer(minLength: 0)
            cameraButton(compact: true)
            pauseButton()
            stopButton()
        }
    }

    private func profilePanel(height: CGFloat) -> some View {
        profileContent(height: height)
            .padding(CJSpacing.s)
            .hudPanel()
    }

    /// Distance, elevation and time over the route profile with your position.
    private func profileContent(height: CGFloat) -> some View {
        VStack(spacing: CJSpacing.xs) {
            HStack(spacing: CJSpacing.s) {
                Text("\(CourseFormat.distance(controller.distanceM)) / \(CourseFormat.distance(summary.totalLengthM))")
                Spacer(minLength: CJSpacing.s)
                Text("\(Int(controller.elevationM.rounded())) m · +\(Int(controller.elevationGainM.rounded())) m")
                Text(TimeFormat.mmss(controller.elapsedSec))
                    .foregroundStyle(.white)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.75))
            .monospacedDigit()

            CourseProfileSparkline(summary: summary, positionS: controller.distanceM, highlightsClimb: true, headroom: 0.22)
                .frame(height: height)
        }
    }

    private var trainerChip: some View {
        TrainerStatusChip(
            connected: controller.trainerConnected,
            controlGranted: controller.trainerControlGranted,
            reconnecting: trainer.connectionState == .connecting || trainer.connectionState == .scanning,
            coasting: controller.awaitingTrainer,
            gradePct: controller.trainerGradePct,
            difficultyPct: difficultyPct
        )
    }

    private func stopButton(expands: Bool = false) -> some View {
        HUDIconButton(systemName: "stop.fill", label: "Stop ride", tint: CJColors.danger, expands: expands, action: onStop)
    }

    private func pauseButton(expands: Bool = false) -> some View {
        HUDIconButton(
            systemName: phase == .paused ? "play.fill" : "pause.fill",
            label: phase == .paused ? "Resume" : "Pause",
            tint: phase == .paused ? CJColors.success : .white,
            expands: expands
        ) {
            controller.pauseOrResume()
        }
    }

    /// What happens to power while the ride's trainer is gone: the rider
    /// coasts until they take up the virtual power control.
    private var trainerDroppedDetail: String {
        let onClimb = controller.climbElapsedSec != nil && controller.distanceToSummitM > 0
        if controller.awaitingTrainer {
            return onClimb
                ? "Coasting until it's back. Set a power to ride on, but the climb then can't be a PB."
                : "Coasting until it's back, or set a power to ride on."
        }
        return controller.climbUsedVirtualPower
            ? "Riding on virtual power until it's back. This climb can't be a PB."
            : "Riding on virtual power until it's back."
    }

    /// The trainer dropped mid-ride: the rider coasts, or rides on the
    /// virtual power control, until it reconnects.
    @ViewBuilder
    private var trainerDroppedBanner: some View {
        let reconnecting = trainer.connectionState == .connecting || trainer.connectionState == .scanning
        HStack(spacing: CJSpacing.s) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(CJColors.warning)
            VStack(alignment: .leading, spacing: 1) {
                Text(reconnecting ? "Reconnecting trainer…" : "Trainer disconnected")
                    .font(CJFont.bodyBold)
                Text(trainerDroppedDetail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: CJSpacing.s)
            if reconnecting {
                ProgressView().controlSize(.small).tint(CJColors.accent)
            } else {
                Button {
                    controller.reconnectTrainer()
                } label: {
                    Text("Reconnect")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, CJSpacing.m)
                        .frame(height: 36)
                        .foregroundStyle(.white)
                        .background(CJColors.accent, in: RoundedRectangle(cornerRadius: CJRadius.small))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, CJSpacing.m)
        .padding(.vertical, CJSpacing.s)
        .hudPanel()
        .overlay(
            RoundedRectangle(cornerRadius: CJRadius.overlay, style: .continuous)
                .stroke(CJColors.warning.opacity(0.55), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// Landscape keeps the ride buttons in the right-hand column so the
    /// bottom panel stays short and the road in front of the rider clear.
    private var landscapeControls: some View {
        VStack(alignment: .leading, spacing: CJSpacing.xs) {
            HStack(spacing: CJSpacing.xs) {
                pauseButton(expands: true)
                stopButton(expands: true)
            }
            cameraButton(expands: true)
            trainerChip.padding(.horizontal, CJSpacing.xxs)
        }
        .padding(CJSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudPanel()
    }

    /// Before the start: why START did nothing, or that the trainer won't
    /// feel the gradient.
    @ViewBuilder
    private var startNotice: some View {
        if controller.trainerHeldByWorkout {
            noticeText("A workout still holds your trainer. End it in Workouts, then start the climb.")
        } else if controller.trainerConnected && !controller.trainerControlGranted {
            noticeText("Your trainer sends power but hasn't given CycleJames control (another app may have it), so it won't feel the gradient.")
        }
    }

    private func noticeText(_ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(CJColors.warning)
        }
        .font(.system(size: 12, weight: .semibold))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var startRow: some View {
        HStack(spacing: CJSpacing.s) {
            HUDIconButton(systemName: "xmark", label: "Close", tint: .white, action: onStop)
            cameraButton()
            Button(action: onStart) {
                Text(phase == .countdown ? "GET READY…" : "START")
                    .font(.system(size: 17, weight: .heavy))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(.white)
                    .background(CJColors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
            }
            .buttonStyle(.plain)
            .disabled(phase != .ready)
            .opacity(phase == .ready ? 1 : 0.6)
        }
    }

    private func cameraButton(compact: Bool = false, expands: Bool = false) -> some View {
        Button {
            cameraMode = cameraMode.next
            if compact { withAnimation { showCameraName = true } }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "video.fill")
                    .font(.system(size: 13, weight: .bold))
                if !compact {
                    Text(cameraMode.label)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, compact ? 0 : CJSpacing.m)
            .frame(minWidth: 44, maxWidth: expands ? .infinity : nil, minHeight: 44)
            .foregroundStyle(.white)
            .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: CJRadius.medium))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Camera: \(cameraMode.label). Tap to change")
    }

    private var pausedBanner: some View {
        HStack(spacing: CJSpacing.m) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(CJColors.warning)
            Text("Paused")
                .font(CJFont.title)
            Button {
                controller.pauseOrResume()
            } label: {
                Text("RESUME")
                    .font(.system(size: 15, weight: .heavy))
                    .padding(.horizontal, CJSpacing.l)
                    .frame(height: 40)
                    .foregroundStyle(.white)
                    .background(CJColors.success, in: RoundedRectangle(cornerRadius: CJRadius.medium))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, CJSpacing.l)
        .padding(.vertical, CJSpacing.s)
        .hudPanel()
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
}

/// Edges of the HUD's top cards and bottom panel, in global coordinates.
private struct HUDCover: Equatable {
    var portraitTop: CGFloat?
    var portraitBottom: CGFloat?
    var landscapeTop: CGFloat?
    var landscapeBottom: CGFloat?
}

/// Tracks one edge of a HUD element in global coordinates (the bottom edge of
/// a top card, the top edge of a bottom panel), clearing it when the element
/// goes away.
private struct CoverEdge: ViewModifier {
    enum Edge { case top, bottom }
    let edge: Edge
    @Binding var value: CGFloat?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                let frame = proxy.frame(in: .global)
                return edge == .top ? frame.maxY : frame.minY
            } action: { value = $0 }
            .onDisappear { value = nil }
    }
}

/// Current gradient, coloured like the profile chart.
struct GradeBadge: View {
    let pct: Double

    private var shown: Double { abs(pct) < 0.05 ? 0 : pct }

    var body: some View {
        VStack(spacing: -2) {
            Text("GRADE")
                .font(.system(size: 9, weight: .heavy))
                .opacity(0.75)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(String(format: "%.1f", shown))
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
            }
        }
        .foregroundStyle(CourseGrade.textColor(for: shown))
        .frame(minWidth: 96)
        .padding(.vertical, CJSpacing.xs)
        .padding(.horizontal, CJSpacing.s)
        .background(CourseGrade.color(for: shown), in: RoundedRectangle(cornerRadius: CJRadius.overlay, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CJRadius.overlay, style: .continuous).stroke(Color.white.opacity(0.3), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        .animation(.easeInOut(duration: 0.3), value: CourseGrade.band(for: shown))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: "Gradient %.1f percent", shown))
    }
}

/// Road surface under the wheels ("Cobbles", "Asphalt").
struct SurfaceChip: View {
    let surface: String

    private var isCobbles: Bool { surface.lowercased().contains("cobble") }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isCobbles ? "square.grid.3x3.fill" : "road.lanes")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isCobbles ? CourseGrade.cobbles : Color.white.opacity(0.8))
            Text(surface.capitalized)
                .font(.system(size: 12, weight: .bold))
        }
        .padding(.horizontal, CJSpacing.s)
        .padding(.vertical, 5)
        .hudPanel(cornerRadius: CJRadius.chip)
        .accessibilityLabel("Surface: \(surface)")
    }
}

/// Trainer connection, plus the gradient actually sent when the difficulty
/// setting scales it. A trainer that powers the ride without having given
/// this app control (another app holds it) shows amber: it isn't getting
/// the gradient, so the climb feels flat.
struct TrainerStatusChip: View {
    let connected: Bool
    /// The trainer accepted control, so it gets the gradient.
    var controlGranted = true
    let reconnecting: Bool
    /// The ride's trainer dropped and the rider is coasting until it's back.
    var coasting = false
    let gradePct: Double
    let difficultyPct: Int

    private var dotColor: Color {
        if connected { return controlGranted ? CJColors.success : CJColors.warning }
        return reconnecting ? CJColors.warning : Color.white.opacity(0.45)
    }

    private var title: String {
        if connected { return controlGranted ? "Trainer" : "Trainer: power only" }
        return reconnecting ? "Reconnecting…" : "No trainer"
    }

    private var detail: String? {
        if connected {
            if !controlGranted { return "gradient not sent" }
            return difficultyPct != 100 ? "\(CourseFormat.grade(gradePct)) at \(difficultyPct)%" : nil
        }
        return coasting ? "coasting" : "virtual power"
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                if let detail {
                    Text(detail)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(connected && !controlGranted ? CJColors.warning : Color.white.opacity(0.7))
                        .monospacedDigit()
                }
            }
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
/// Every `TrainerStatusChip` state on one HUD panel, for screenshots
/// (`-screenshotTrainerChips`): the Simulator has no trainer to show them.
struct TrainerChipGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: CJSpacing.s) {
            TrainerStatusChip(connected: true, reconnecting: false, gradePct: 12.4, difficultyPct: 100)
            TrainerStatusChip(connected: true, reconnecting: false, gradePct: 6.2, difficultyPct: 50)
            TrainerStatusChip(connected: true, controlGranted: false, reconnecting: false, gradePct: 12.4, difficultyPct: 50)
            TrainerStatusChip(connected: false, reconnecting: true, coasting: true, gradePct: 0, difficultyPct: 100)
            TrainerStatusChip(connected: false, reconnecting: false, gradePct: 0, difficultyPct: 100)
        }
        .padding(CJSpacing.m)
        .hudPanel()
        .foregroundStyle(.white)
    }
}
#endif

/// Power used without a trainer. `.full` steps and slides; `.inline` (portrait
/// ride row) steps only and opens the slider from its readout; `.stacked`
/// (landscape side column) puts the steppers under the readout.
struct VirtualPowerControl: View {
    enum Style { case full, inline, stacked }

    @Binding var watts: Int
    var style: Style = .full
    /// Makes the readout a button, e.g. to open or close the slider.
    var onReadoutTap: (() -> Void)? = nil
    static let range = 50...600

    private var slider: Binding<Double> {
        Binding(
            get: { Double(watts) },
            set: { watts = (Int(($0 / 5).rounded()) * 5).clamped(to: Self.range) }
        )
    }

    var body: some View {
        Group {
            switch style {
            case .stacked:
                VStack(spacing: CJSpacing.xs) {
                    readout.frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: CJSpacing.xs) {
                        minusButton.frame(maxWidth: .infinity)
                        plusButton.frame(maxWidth: .infinity)
                    }
                }
            case .inline:
                HStack(spacing: CJSpacing.xs) {
                    minusButton
                    readout.frame(minWidth: 60)
                    plusButton
                }
            case .full:
                HStack(spacing: CJSpacing.s) {
                    minusButton
                    readout.frame(width: 64, alignment: .leading)
                    Slider(value: slider, in: Double(Self.range.lowerBound)...Double(Self.range.upperBound))
                        .tint(CJColors.accent)
                        .accessibilityLabel("Virtual power")
                        .accessibilityValue("\(watts) watts")
                    plusButton
                }
            }
        }
        .sensoryFeedback(.selection, trigger: watts / 10)
    }

    @ViewBuilder
    private var readout: some View {
        let content = VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Text("VIRTUAL")
                    .font(.system(size: 9, weight: .heavy))
                if onReadoutTap != nil {
                    Image(systemName: style == .inline ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .heavy))
                }
            }
            .foregroundStyle(Color.white.opacity(0.7))
            Text("\(watts) W")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        if let onReadoutTap {
            Button(action: onReadoutTap) { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel("Virtual power \(watts) watts")
                .accessibilityHint(style == .inline ? "Shows the power slider" : "Hides the power slider")
        } else {
            content
        }
    }

    private var minusButton: some View {
        HUDIconButton(systemName: "minus", label: "Less power", tint: .white) {
            watts = (watts - 10).clamped(to: Self.range)
        }
    }

    private var plusButton: some View {
        HUDIconButton(systemName: "plus", label: "More power", tint: .white) {
            watts = (watts + 10).clamped(to: Self.range)
        }
    }
}

struct HUDIconButton: View {
    let systemName: String
    let label: String
    var tint: Color = .white
    /// Fills the available width instead of a 44 pt square.
    var expands: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .bold))
                .frame(width: expands ? nil : 44, height: 44)
                .frame(maxWidth: expands ? .infinity : nil)
                .foregroundStyle(tint)
                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: CJRadius.medium))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
