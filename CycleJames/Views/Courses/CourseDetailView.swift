import SwiftUI

/// One course: stats, the elevation profile, your best time, ride setup and
/// the data licences, with a Ride button that opens the 3D ride.
struct CourseDetailView: View {
    let courseID: String
    @EnvironmentObject private var trainer: FTMSManager
    @EnvironmentObject private var hr: HRManager
    @State private var showRide = false
    /// Re-read after a ride so a new PB shows straight away.
    @State private var personalBest: Double?
    @State private var confirmResetPB = false

    private var summary: CourseSummary? { CourseCatalog.summary(id: courseID) }

    var body: some View {
        Group {
            if let summary {
                content(summary)
            } else {
                Text("This course isn't available.")
                    .font(CJFont.body)
                    .foregroundStyle(CJColors.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(CJColors.bgPrimary.ignoresSafeArea())
        .navigationTitle(summary?.name ?? "Course")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(CJColors.bgSecondary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            CourseLaunchArgs.applyPersonalBestSeed(courseID: courseID)
            personalBest = AppSettings.personalBestSeconds(courseID: courseID)
            if personalBest != nil, CourseLaunchArgs.consumeResetPBPrompt() {
                Task {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    confirmResetPB = true
                }
            }
            if CourseLaunchArgs.consumeRideDemo(for: courseID) {
                Task {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    showRide = true
                }
            }
        }
        .fullScreenCover(isPresented: $showRide, onDismiss: {
            personalBest = AppSettings.personalBestSeconds(courseID: courseID)
        }) {
            CourseRideView(courseID: courseID)
                .environmentObject(trainer)
                .environmentObject(hr)
        }
    }

    @ViewBuilder
    private func content(_ summary: CourseSummary) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: CJSpacing.l) {
                    header(summary)
                    statsGrid(summary)
                    profileCard(summary).id("profile")
                    landmarks(summary)
                    personalBestCard.id("pb")
                    setupCard.id("setup")
                    trainerCard.id("trainer")
                    attribution(summary).id("licences")
                }
                .padding(.horizontal, CJSpacing.l)
                .padding(.top, CJSpacing.s)
                .padding(.bottom, CJSpacing.xl)
            }
            .onAppear {
                // Screenshot capture only: `-screenshotCourseScroll <section>`.
                guard let anchor = CourseLaunchArgs.screenshotCourseScroll else { return }
                Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    proxy.scrollTo(anchor, anchor: .top)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            rideButton(summary)
                .padding(CJSpacing.l)
                .background(CJColors.bgPrimary.opacity(0.95))
        }
    }

    // MARK: Sections

    private func header(_ s: CourseSummary) -> some View {
        VStack(alignment: .leading, spacing: CJSpacing.xs) {
            Text("3D CLIMB · \(s.region.uppercased())")
                .font(CJFont.labelUpper)
                .foregroundStyle(CJColors.accent)
                .fixedSize(horizontal: false, vertical: true)
            Text(s.name)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(CJColors.textPrimary)
            Text(tagline(s))
                .font(CJFont.body)
                .foregroundStyle(CJColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tagline(_ s: CourseSummary) -> String {
        var text = "A timed climb of \(CourseFormat.distance(s.climbLengthM)) at \(CourseFormat.grade(s.climbAvgGradePct)) average"
        if let max10 = s.climbMaxGradePct10m, max10 > s.climbMaxGradePct + 0.05 {
            text += ", touching \(CourseFormat.grade(max10, decimals: 0))."
        } else {
            text += ", up to \(CourseFormat.grade(s.climbMaxGradePct))."
        }
        let cobbles = s.lengthM(on: "cobbles")
        if cobbles > 0 { text += " \(CourseFormat.distance(cobbles)) of cobbles." }
        let lead = s.climbStartS
        if lead >= 50 { text += " The ride starts \(CourseFormat.distance(lead)) before the timing line." }
        return text
    }

    private func statsGrid(_ s: CourseSummary) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: CJSpacing.s), count: 3), spacing: CJSpacing.s) {
            stat("Climb", CourseFormat.distance(s.climbLengthM))
            stat("Gain", "+\(Int(s.climbGainM.rounded())) m")
            stat("Avg grade", CourseFormat.grade(s.climbAvgGradePct), color: CourseGrade.labelColor(for: s.climbAvgGradePct))
            stat("Max (25 m)", CourseFormat.grade(s.climbMaxGradePct), color: CourseGrade.labelColor(for: s.climbMaxGradePct))
            stat("Summit", "\(Int(s.summitElevationM.rounded())) m")
            stat("Route", CourseFormat.distance(s.totalLengthM))
        }
    }

    private func stat(_ label: String, _ value: String, color: Color = CJColors.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(CJFont.labelUpper)
                .foregroundStyle(CJColors.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(CJFont.metricSmall)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CJSpacing.m)
        .background(CJColors.card)
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
    }

    private func profileCard(_ s: CourseSummary) -> some View {
        VStack(alignment: .leading, spacing: CJSpacing.s) {
            Text("ELEVATION PROFILE")
                .font(CJFont.labelUpper)
                .foregroundStyle(CJColors.textSecondary)
            CourseProfileChart(summary: s)
                .frame(height: 220)
            GradeLegend(showsCobbles: s.lengthM(on: "cobbles") > 0)
            Text("Shaded: the timed climb, \(CourseFormat.distance(s.climbStartS)) to \(CourseFormat.distance(s.climbEndS)) along the route.")
                .font(CJFont.caption)
                .foregroundStyle(CJColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(CJSpacing.m)
        .background(CJColors.card)
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
    }

    private func landmarks(_ s: CourseSummary) -> some View {
        VStack(alignment: .leading, spacing: CJSpacing.xs) {
            Text("ON THE WAY UP")
                .font(CJFont.labelUpper)
                .foregroundStyle(CJColors.textSecondary)
            ForEach(Array(s.landmarks.enumerated()), id: \.offset) { _, mark in
                HStack(spacing: CJSpacing.s) {
                    Image(systemName: icon(for: mark.kind))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(iconColor(for: mark.kind))
                        .frame(width: 20)
                    Text(mark.name)
                        .font(CJFont.body)
                        .foregroundStyle(CJColors.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: CJSpacing.s)
                    Text(CourseFormat.distance(mark.s))
                        .font(CJFont.caption)
                        .foregroundStyle(CJColors.textMuted)
                        .monospacedDigit()
                }
                .padding(.vertical, 6)
                .padding(.horizontal, CJSpacing.s)
                .background(CJColors.bgSecondary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: CJRadius.small))
            }
        }
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "climbStart": "flag.fill"
        case "summit": "flag.checkered"
        case "steepest": "arrow.up.right"
        case "junction": "arrow.triangle.turn.up.right.diamond"
        case "village": "house.fill"
        default: "mappin"
        }
    }

    private func iconColor(for kind: String) -> Color {
        switch kind {
        case "climbStart", "summit": CJColors.accent
        case "steepest": CourseGrade.labelColor(for: 25)
        default: CJColors.textSecondary
        }
    }

    private var personalBestCard: some View {
        HStack(spacing: CJSpacing.m) {
            Image(systemName: "stopwatch.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(personalBest == nil ? CJColors.textMuted : CJColors.positionMarker)
            VStack(alignment: .leading, spacing: 2) {
                Text("PERSONAL BEST")
                    .font(CJFont.labelUpper)
                    .foregroundStyle(CJColors.textSecondary)
                if let personalBest {
                    Text(CourseFormat.climbTime(personalBest))
                        .font(CJFont.metricMedium)
                        .foregroundStyle(CJColors.textPrimary)
                } else {
                    Text("Climb it on your trainer to set your time. The clock runs from the climb start to the summit; climbs on the power slider don't count.")
                        .font(CJFont.body)
                        .foregroundStyle(CJColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if personalBest != nil {
                Button {
                    confirmResetPB = true
                } label: {
                    Text("Reset")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, CJSpacing.m)
                        .frame(minHeight: 36)
                        .foregroundStyle(CJColors.textPrimary)
                        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: CJRadius.small))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reset personal best")
            }
        }
        .padding(CJSpacing.m)
        .background(CJColors.card)
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
        .confirmationDialog("Reset your personal best?", isPresented: $confirmResetPB, titleVisibility: .visible) {
            Button("Reset personal best", role: .destructive) {
                AppSettings.clearPersonalBest(courseID: courseID)
                personalBest = AppSettings.personalBestSeconds(courseID: courseID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(resetPBMessage)
        }
    }

    private var resetPBMessage: String {
        let time = personalBest.map { " (\(CourseFormat.climbTime($0)))" } ?? ""
        return "Your best time\(time) and its splits are removed. Rides in History are kept."
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: CJSpacing.s) {
            Text("YOUR RIDE SETUP")
                .font(CJFont.labelUpper)
                .foregroundStyle(CJColors.textSecondary)
            CourseRideSettingsControls(showsBikeWeight: false)
                .padding(CJSpacing.m)
                .background(CJColors.card)
                .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
            Text("Bike weight and the rest are in Settings › 3D Climbs.")
                .font(CJFont.caption)
                .foregroundStyle(CJColors.textMuted)
        }
    }

    private var trainerCard: some View {
        VStack(alignment: .leading, spacing: CJSpacing.s) {
            Text("TRAINER")
                .font(CJFont.labelUpper)
                .foregroundStyle(CJColors.textSecondary)
            ConnectionRow()
                .padding(.horizontal, -CJSpacing.l)
                .padding(.top, -CJSpacing.s)
            HStack(alignment: .top, spacing: CJSpacing.s) {
                Image(systemName: trainer.connectionState == .connected ? "checkmark.circle.fill" : "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(trainer.connectionState == .connected ? CJColors.success : CJColors.accent)
                Text(trainer.connectionState == .connected
                     ? "Your trainer will set the resistance from the gradient under your wheel, cobbles included."
                     : "No trainer? You can still ride: set your power with the on-screen slider and the bike climbs at that wattage.")
                    .font(CJFont.caption)
                    .foregroundStyle(CJColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func attribution(_ s: CourseSummary) -> some View {
        VStack(alignment: .leading, spacing: CJSpacing.xs) {
            Text("DATA & LICENCES")
                .font(CJFont.labelUpper)
                .foregroundStyle(CJColors.textSecondary)
            ForEach(s.attribution, id: \.self) { line in
                if let url = CourseLicence.url(for: line) {
                    // The whole line is the link, so it is easy to hit.
                    Link(destination: url) {
                        HStack(alignment: .firstTextBaseline, spacing: CJSpacing.s) {
                            Text(line)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right.square")
                                .accessibilityHidden(true)
                        }
                        .font(CJFont.caption)
                        .foregroundStyle(CJColors.accent)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .accessibilityHint("Opens the licence in Safari")
                } else {
                    Text(line)
                        .font(CJFont.caption)
                        .foregroundStyle(CJColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(CJSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CJColors.bgSecondary.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
    }

    private func rideButton(_ s: CourseSummary) -> some View {
        Button {
            showRide = true
        } label: {
            HStack(spacing: CJSpacing.s) {
                Image(systemName: "mountain.2.fill")
                Text("RIDE \(s.name.uppercased())")
            }
            .font(.system(size: 17, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, CJSpacing.l)
            .foregroundStyle(.white)
            .background(CJColors.accent)
            .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
        }
        .buttonStyle(.plain)
    }
}

/// Where the licences named in a course's attribution lines are published,
/// so each credit can link to its terms (OSM asks for a link to its
/// copyright page wherever the medium allows one).
enum CourseLicence {
    static let openStreetMap = URL(string: "https://www.openstreetmap.org/copyright")!
    static let modellicentieGratisHergebruik = URL(string:
        "https://www.vlaanderen.be/digitaal-vlaanderen/onze-diensten-en-platformen/open-data/voorwaarden-voor-het-hergebruik-van-overheidsinformatie/modellicentie-gratis-hergebruik")!

    static func url(for line: String) -> URL? {
        if line.contains("OpenStreetMap") { return openStreetMap }
        if line.contains("Modellicentie Gratis Hergebruik") { return modellicentieGratisHergebruik }
        return nil
    }
}
