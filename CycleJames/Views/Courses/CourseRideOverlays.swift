import SwiftUI

/// Shown while the course data loads and the 3D world is built.
struct CourseLoadingView: View {
    let summary: CourseSummary?
    let progress: Double
    let label: String
    let error: String?
    var onClose: () -> Void

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var compact: Bool { verticalSizeClass == .compact }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [CJColors.bgSecondary, CJColors.bgPrimary], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: compact ? CJSpacing.s : CJSpacing.l) {
                Spacer(minLength: 0)
                VStack(spacing: CJSpacing.xs) {
                    Text("3D CLIMB")
                        .font(CJFont.labelUpper)
                        .foregroundStyle(CJColors.accent)
                    Text(summary?.name ?? "Loading course")
                        .font(.system(size: compact ? 26 : 32, weight: .bold))
                        .foregroundStyle(CJColors.textPrimary)
                    if let region = summary?.region {
                        Text(region)
                            .font(CJFont.caption)
                            .foregroundStyle(CJColors.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                }

                if let summary {
                    VStack(spacing: CJSpacing.xs) {
                        CourseProfileSparkline(summary: summary, highlightsClimb: true, lineWidth: 2)
                            .frame(height: compact ? 64 : 110)
                        HStack {
                            Text("\(CourseFormat.distance(summary.climbLengthM)) · \(CourseFormat.grade(summary.climbAvgGradePct)) avg")
                            Spacer()
                            Text("max \(CourseFormat.grade(summary.climbMaxGradePct)) · +\(Int(summary.climbGainM.rounded())) m")
                        }
                        .font(CJFont.caption)
                        .foregroundStyle(CJColors.textSecondary)
                        .monospacedDigit()
                    }
                    .frame(maxWidth: 460)
                }

                if let error {
                    VStack(spacing: CJSpacing.m) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(CJFont.body)
                            .foregroundStyle(CJColors.warning)
                            .multilineTextAlignment(.center)
                        Button(action: onClose) {
                            Text("Close")
                                .font(CJFont.buttonText)
                                .frame(maxWidth: 220, minHeight: 44)
                                .foregroundStyle(.white)
                                .background(CJColors.card)
                                .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    VStack(spacing: CJSpacing.s) {
                        ProgressView(value: min(max(progress, 0), 1))
                            .tint(CJColors.accent)
                            .frame(maxWidth: 260)
                            .animation(.easeOut(duration: 0.25), value: progress)
                        Text(label.isEmpty ? "Building the world" : label)
                            .font(CJFont.bodyBold)
                            .foregroundStyle(CJColors.textPrimary)
                            .contentTransition(.opacity)
                    }
                }
                Spacer(minLength: 0)
                if error == nil {
                    Text("Tip: the camera button cycles chase, close, rider and broadcast views.")
                        .font(CJFont.caption)
                        .foregroundStyle(CJColors.textMuted)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, CJSpacing.xl)
            .padding(.vertical, CJSpacing.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 40, height: 40)
                    .foregroundStyle(CJColors.textPrimary)
                    .background(CJColors.card.opacity(0.8), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(CJSpacing.l)
            .accessibilityLabel("Close")
        }
    }
}

/// 3-2-1 over the live scene. Lighter than the workout `CountdownOverlay` so
/// the rider can see the road they are about to ride.
struct CourseCountdownOverlay: View {
    let number: Int

    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            Text(number == 0 ? "GO!" : "\(number)")
                .font(.system(size: 160, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: CJColors.accent.opacity(0.9), radius: 18)
                .shadow(color: .black.opacity(0.5), radius: 3)
                .scaleEffect(number == 0 ? 1.2 : 1.0)
                .animation(.easeOut(duration: 0.4), value: number)
        }
        .allowsHitTesting(false)
    }
}

/// What the finish screen shows, from a completed ride or one stopped early.
struct CourseRideOutcome: Equatable {
    var completed: Bool
    var climbTimeSec: Double?
    var previousBestSec: Double?
    var isPersonalBest: Bool
    var avgPowerW: Int?
    var climbAvgPowerW: Int?
    var totalTimeSec: Int
    var distanceM: Double
    var elevationGainM: Double?
    var climbAvgSpeedKph: Double?
    /// Part of the timed climb was ridden on virtual power, so it can't be
    /// a personal best.
    var climbOnVirtualPower = false

    init(result: CourseRideResult, climbOnVirtualPower: Bool = false) {
        completed = result.completed
        climbTimeSec = result.climbTimeSec
        previousBestSec = result.previousBestSec
        isPersonalBest = result.isPersonalBest
        avgPowerW = result.avgPowerW
        climbAvgPowerW = result.climbAvgPowerW
        totalTimeSec = result.totalTimeSec
        distanceM = result.distanceM
        elevationGainM = result.elevationGainM
        climbAvgSpeedKph = result.climbAvgSpeedKph
        self.climbOnVirtualPower = climbOnVirtualPower
    }

    /// A ride ended with Save & Stop. The climb counts only if the summit
    /// was already behind the rider.
    @MainActor
    init(stopped controller: CourseRideController, session: RideSessionModel?) {
        completed = false
        let pastSummit = controller.climbElapsedSec != nil && controller.distanceToSummitM <= 0
        climbTimeSec = pastSummit ? controller.climbElapsedSec : nil
        previousBestSec = controller.personalBestSec
        climbOnVirtualPower = controller.climbUsedVirtualPower
        isPersonalBest = false
        if !climbOnVirtualPower, let t = climbTimeSec {
            isPersonalBest = controller.personalBestSec.map { t < $0 } ?? true
        }
        avgPowerW = session.map(\.avgPower)
        climbAvgPowerW = nil
        totalTimeSec = session?.durationSec ?? controller.elapsedSec
        distanceM = controller.distanceM
        elevationGainM = controller.elevationGainM
        climbAvgSpeedKph = nil
    }
}

/// Finish card: climb time, personal best, power, then Done. The ride is
/// normally in History by now (saved when it ended); Discard deletes it.
struct CourseFinishOverlay: View {
    let courseName: String
    let outcome: CourseRideOutcome
    let riderWeightKg: Double
    /// True once the ride is in History.
    let saved: Bool
    /// Set when saving was attempted and nothing was stored.
    let saveFailed: Bool
    /// Set when saving found less than a second ridden: nothing to keep.
    var tooShortToSave = false
    var onSave: () -> Void
    var onDone: () -> Void
    var onDiscard: () -> Void

    @State private var confirmLeave = false
    @State private var confirmDiscard = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// Landscape phone: results on the left, stats and buttons on the right,
    /// so the whole card fits without scrolling.
    private var compact: Bool { verticalSizeClass == .compact }

    private var power: Int? { outcome.climbAvgPowerW ?? outcome.avgPowerW }

    private var headline: String {
        if outcome.climbTimeSec != nil { return "SUMMIT REACHED" }
        if outcome.completed { return "ROUTE COMPLETE" }
        return saved ? "RIDE SAVED" : "RIDE STOPPED"
    }

    private var wattsPerKg: String {
        guard let power, power > 0, riderWeightKg > 0 else { return "--" }
        return String(format: "%.2f", Double(power) / riderWeightKg)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            GeometryReader { geo in
                ScrollView {
                    card
                        .padding(compact ? CJSpacing.l : CJSpacing.xl)
                        .frame(maxWidth: compact ? 680 : 420)
                        .background(CJColors.bgSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: CJRadius.overlay))
                        .padding(compact ? CJSpacing.s : CJSpacing.l)
                        // Centred when it fits, scrolls when it doesn't.
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .confirmationDialog("Leave without saving?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Save and close") { onSave(); onDone() }
            Button("Discard ride", role: .destructive) { onDiscard() }
            Button("Keep looking", role: .cancel) {}
        } message: {
            Text("This ride hasn't been added to History yet.")
        }
        .confirmationDialog("Discard this ride?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard ride", role: .destructive) { onDiscard() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text(outcome.isPersonalBest
                 ? "It's deleted from History, and the personal best it set goes with it."
                 : "It's deleted from History.")
        }
    }

    @ViewBuilder
    private var card: some View {
        if compact {
            HStack(alignment: .center, spacing: CJSpacing.xl) {
                VStack(spacing: CJSpacing.m) {
                    titleBlock
                    climbTime
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: CJSpacing.m) {
                    statsGrid
                    buttons
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: CJSpacing.l) {
                titleBlock
                climbTime
                statsGrid
                buttons
            }
        }
    }

    private var titleBlock: some View {
        VStack(spacing: CJSpacing.xxs) {
            Text(headline)
                .font(CJFont.labelUpper)
                .foregroundStyle(CJColors.accent)
            Text(courseName)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(CJColors.textPrimary)
        }
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: CJSpacing.s) {
            tile(outcome.climbAvgPowerW != nil ? "Climb power" : "Avg power", power.map { "\($0)W" } ?? "--")
            tile("W/kg", wattsPerKg)
            if let kph = outcome.climbAvgSpeedKph {
                tile("Climb speed", String(format: "%.1f km/h", kph))
            }
            tile("Ride time", TimeFormat.mmss(outcome.totalTimeSec))
            tile("Distance", CourseFormat.distance(outcome.distanceM))
            if let gain = outcome.elevationGainM, gain >= 1 {
                tile("Climbing", "+\(Int(gain.rounded())) m")
            }
        }
    }

    @ViewBuilder
    private var climbTime: some View {
        if let t = outcome.climbTimeSec {
            VStack(spacing: CJSpacing.xs) {
                Text("CLIMB TIME")
                    .font(CJFont.labelUpper)
                    .foregroundStyle(CJColors.textSecondary)
                Text(CourseFormat.climbTime(t))
                    .font(.system(size: compact ? 46 : 54, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(CJColors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                pbLine(time: t)
            }
        } else {
            VStack(spacing: CJSpacing.xs) {
                Image(systemName: "stopwatch")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(CJColors.textMuted)
                Text(outcome.completed ? "Climb not timed" : "Climb not finished")
                    .font(CJFont.title)
                    .foregroundStyle(CJColors.textPrimary)
                Text(outcome.completed
                     ? "The clock runs from the climb start to the summit. Start below the climb to set a time."
                     : "The clock stops at the summit. Ride all the way up to set a time.")
                    .font(CJFont.caption)
                    .foregroundStyle(CJColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func pbLine(time: Double) -> some View {
        if outcome.climbOnVirtualPower {
            VStack(spacing: CJSpacing.xxs) {
                Label("No PB: ridden on virtual power", systemImage: "slider.horizontal.3")
                    .font(CJFont.bodyBold)
                    .foregroundStyle(CJColors.textSecondary)
                Text(virtualPowerNote(time: time))
                    .font(CJFont.caption)
                    .foregroundStyle(CJColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if outcome.isPersonalBest {
            HStack(spacing: CJSpacing.xs) {
                Image(systemName: "trophy.fill")
                Text(outcome.previousBestSec == nil ? "First ascent: your benchmark" : "New personal best")
                if let prev = outcome.previousBestSec {
                    Text(CourseFormat.delta(time - prev)).monospacedDigit()
                }
            }
            .font(CJFont.bodyBold)
            .foregroundStyle(CJColors.bgPrimary)
            .padding(.horizontal, CJSpacing.m)
            .padding(.vertical, CJSpacing.xs)
            .background(CJColors.positionMarker, in: Capsule())
        } else if let prev = outcome.previousBestSec {
            HStack(spacing: CJSpacing.xs) {
                Text("PB \(CourseFormat.climbTime(prev))")
                    .foregroundStyle(CJColors.textSecondary)
                Text(CourseFormat.delta(time - prev))
                    .foregroundStyle(time <= prev ? CJColors.success : CJColors.danger)
            }
            .font(CJFont.bodyBold)
            .monospacedDigit()
        }
    }

    private func virtualPowerNote(time: Double) -> String {
        var text = "Only a climb your trainer powers all the way up sets your best time."
        if let prev = outcome.previousBestSec {
            text += " PB \(CourseFormat.climbTime(prev)) (\(CourseFormat.delta(time - prev)))."
        }
        return text
    }

    @ViewBuilder
    private var buttons: some View {
        let layout = compact
            ? AnyLayout(HStackLayout(spacing: CJSpacing.s))
            : AnyLayout(VStackLayout(spacing: CJSpacing.s))
        layout {
            if saved {
                HStack(spacing: CJSpacing.s) {
                    Label("Saved to History", systemImage: "checkmark.circle.fill")
                        .font(CJFont.bodyBold)
                        .foregroundStyle(CJColors.success)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 0)
                    Button("Discard") { confirmDiscard = true }
                        .font(CJFont.bodyBold)
                        .foregroundStyle(CJColors.danger)
                        .frame(minHeight: 44)
                        .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            } else if tooShortToSave {
                Text("Too short to save.")
                    .font(CJFont.caption)
                    .foregroundStyle(CJColors.textSecondary)
            } else if saveFailed {
                Text("This ride couldn't be saved.")
                    .font(CJFont.caption)
                    .foregroundStyle(CJColors.warning)
            } else {
                button("SAVE", color: CJColors.accent, action: onSave)
            }
            let settled = saved || saveFailed || tooShortToSave
            button("DONE", color: settled ? CJColors.accent : CJColors.card) {
                if settled { onDone() } else { confirmLeave = true }
            }
        }
    }

    private func button(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: compact ? 44 : 50)
                .foregroundStyle(.white)
                .background(color)
                .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
        }
        .buttonStyle(.plain)
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label.uppercased())
                .font(CJFont.labelUpper)
                .foregroundStyle(CJColors.textSecondary)
            Text(value)
                .font(CJFont.metricSmall)
                .foregroundStyle(CJColors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(compact ? CJSpacing.xs : CJSpacing.s)
        .background(CJColors.card)
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.small))
    }
}

/// Save-or-discard confirmation for a course ride. Looks like the workout
/// ride's `StopConfirmOverlay`, but says what stopping costs on this climb
/// and keeps a sensible width in landscape.
struct CourseStopConfirmOverlay: View {
    /// Metres left to the summit; zero or less once over the top.
    let distanceToSummitM: Double
    /// True while the climb clock is running or has stopped at the summit.
    let climbTimed: Bool
    var onSave: () -> Void
    var onDiscard: () -> Void
    var onCancel: () -> Void

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var compact: Bool { verticalSizeClass == .compact }

    private var message: String {
        if distanceToSummitM > 0 {
            let left = CourseFormat.distance(distanceToSummitM)
            return climbTimed
                ? "\(left) to the summit. Stopping now saves a partial ride without a climb time."
                : "\(left) to the summit. Save the ride to History or discard it."
        }
        return climbTimed
            ? "Your climb time is in. Save the ride to History or discard it."
            : "Save the ride to History or discard it."
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: compact ? CJSpacing.m : CJSpacing.l) {
                Text("Stop Ride?")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(CJColors.textPrimary)
                Text(message)
                    .font(CJFont.body)
                    .foregroundStyle(CJColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: CJSpacing.s) {
                    button(title: "Save & Stop", color: CJColors.accent, action: onSave)
                    button(title: "Discard & Stop", color: CJColors.danger, action: onDiscard)
                    button(title: "Cancel", color: CJColors.card, action: onCancel)
                }
            }
            .padding(compact ? CJSpacing.xl : CJSpacing.xxl)
            .frame(maxWidth: 440)
            .background(CJColors.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CJRadius.overlay))
            .padding(CJSpacing.l)
        }
    }

    private func button(title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: compact ? 44 : 50)
                .foregroundStyle(.white)
                .background(color)
                .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
        }
        .buttonStyle(.plain)
    }
}
