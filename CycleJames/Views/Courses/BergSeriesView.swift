import SwiftUI

/// "Ride them all" card at the top of the course list.
struct BergSeriesCard: View {
    private var plan: CourseRidePlan? { BergSeries.plan() }

    var body: some View {
        let ids = plan?.courseIDs ?? BergSeries.availableIDs
        let courses = ids.compactMap(CourseCatalog.summary(id:))
        VStack(alignment: .leading, spacing: CJSpacing.s) {
            HStack(spacing: CJSpacing.xs) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("BERG SERIES")
                    .font(CJFont.labelUpper)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CJColors.textMuted)
            }
            .foregroundStyle(CJColors.accent)

            Text(courses.count == BergSeries.availableIDs.count ? "Ride them all in one go" : "Ride \(courses.count) bergs in one go")
                .font(CJFont.title)
                .foregroundStyle(CJColors.textPrimary)
            Text(courses.map(\.name).joined(separator: " → "))
                .font(CJFont.caption)
                .foregroundStyle(CJColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(CourseFormat.distance(courses.reduce(0) { $0 + $1.climbLengthM })) of climbing, "
                 + "+\(Int(courses.reduce(0) { $0 + $1.climbGainM }.rounded())) m, "
                 + "\(AppSettings.seriesRecoveryMin) min easy between each")
                .font(CJFont.bodyBold)
                .foregroundStyle(CJColors.textPrimary)
                .monospacedDigit()
        }
        .padding(CJSpacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [CJColors.card, CJColors.bgSecondary], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .overlay(RoundedRectangle(cornerRadius: CJRadius.card).stroke(CJColors.accent.opacity(0.45), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.card))
        .contentShape(RoundedRectangle(cornerRadius: CJRadius.card))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Sets up the bergs back to back")
    }
}

/// Sets up the berg series: which bergs (in race order) and how long to
/// spin between them, then rides them as one ride.
struct BergSeriesView: View {
    @EnvironmentObject private var trainer: FTMSManager
    @EnvironmentObject private var hr: HRManager
    @State private var excluded = AppSettings.seriesExcludedCourseIDs
    @State private var recoveryMin = AppSettings.seriesRecoveryMin
    @State private var ridePlan: CourseRidePlan?

    private var courses: [CourseSummary] { BergSeries.availableIDs.compactMap(CourseCatalog.summary(id:)) }
    private var chosen: [CourseSummary] { courses.filter { !excluded.contains($0.id) } }
    private var plan: CourseRidePlan? { BergSeries.plan(excluding: excluded, recoveryMin: recoveryMin) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CJSpacing.l) {
                header
                totals
                climbList
                recoveryCard
                Text("Between climbs your trainer eases to a flat road for an easy spin while the next berg loads, "
                     + "with a countdown to its start. Each climb is timed against its personal best, and the whole "
                     + "series is saved to History as one ride.")
                    .font(CJFont.caption)
                    .foregroundStyle(CJColors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, CJSpacing.l)
            .padding(.top, CJSpacing.s)
            .padding(.bottom, CJSpacing.xl)
        }
        .background(CJColors.bgPrimary.ignoresSafeArea())
        .navigationTitle("Berg Series")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(CJColors.bgSecondary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            rideButton
                .padding(CJSpacing.l)
                .background(CJColors.bgPrimary.opacity(0.95))
        }
        .onChange(of: excluded) { _, new in AppSettings.seriesExcludedCourseIDs = new }
        .onChange(of: recoveryMin) { _, new in AppSettings.seriesRecoveryMin = new }
        .onAppear {
            guard let demo = CourseLaunchArgs.consumeSeriesDemo() else { return }
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                ridePlan = demo
            }
        }
        .fullScreenCover(item: $ridePlan) { plan in
            CourseRideView(plan: plan)
                .environmentObject(trainer)
                .environmentObject(hr)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: CJSpacing.xs) {
            Text("3D CLIMBS · FLEMISH ARDENNES")
                .font(CJFont.labelUpper)
                .foregroundStyle(CJColors.accent)
            Text("The bergs back to back")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(CJColors.textPrimary)
            Text("In the Ronde's order, finishing on the Muur as the old Ronde did. Leave out any you don't want today.")
                .font(CJFont.body)
                .foregroundStyle(CJColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var totals: some View {
        let climbs = chosen
        let spins = max(0, climbs.count - 1) * recoveryMin
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: CJSpacing.s), count: 3), spacing: CJSpacing.s) {
            stat("Climbs", "\(climbs.count)")
            stat("Climbing", CourseFormat.distance(climbs.reduce(0) { $0 + $1.climbLengthM }))
            stat("Gain", "+\(Int(climbs.reduce(0) { $0 + $1.climbGainM }.rounded())) m")
            stat("Route", CourseFormat.distance(climbs.reduce(0) { $0 + $1.totalLengthM }))
            stat("Easy spins", "\(spins) min")
            stat("Max", CourseFormat.grade(climbs.map(\.climbMaxGradePct).max() ?? 0),
                 color: CourseGrade.labelColor(for: climbs.map(\.climbMaxGradePct).max() ?? 0))
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

    private var climbList: some View {
        VStack(alignment: .leading, spacing: CJSpacing.xs) {
            Text("THE CLIMBS")
                .font(CJFont.labelUpper)
                .foregroundStyle(CJColors.textSecondary)
            VStack(spacing: 0) {
                ForEach(Array(courses.enumerated()), id: \.element.id) { i, course in
                    if i > 0 { Divider().overlay(CJColors.border) }
                    climbRow(course)
                }
            }
            .background(CJColors.card)
            .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
            if chosen.count < 2 {
                Text("Pick at least two climbs.")
                    .font(CJFont.caption)
                    .foregroundStyle(CJColors.warning)
            }
        }
    }

    private func climbRow(_ course: CourseSummary) -> some View {
        let included = !excluded.contains(course.id)
        let number = chosen.firstIndex(where: { $0.id == course.id }).map { $0 + 1 }
        return Toggle(isOn: Binding(
            get: { included },
            set: { on in
                if on { excluded.remove(course.id) } else { excluded.insert(course.id) }
            }
        )) {
            HStack(spacing: CJSpacing.m) {
                Text(number.map(String.init) ?? "–")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(included ? CJColors.accent : CJColors.textMuted)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(course.name)
                        .font(CJFont.bodyBold)
                        .foregroundStyle(included ? CJColors.textPrimary : CJColors.textMuted)
                    Text("\(CourseFormat.distance(course.climbLengthM)) at \(CourseFormat.grade(course.climbAvgGradePct)), "
                         + "max \(CourseFormat.grade(course.climbMaxGradePct))")
                        .font(CJFont.caption)
                        .foregroundStyle(CJColors.textSecondary)
                        .monospacedDigit()
                }
                Spacer(minLength: CJSpacing.s)
                CourseProfileSparkline(summary: course, highlightsClimb: true, lineWidth: 1.2, headroom: 0.05)
                    .frame(width: 64, height: 28)
                    .opacity(included ? 1 : 0.35)
            }
        }
        .tint(CJColors.accent)
        .padding(.vertical, CJSpacing.s)
        .padding(.horizontal, CJSpacing.m)
    }

    private var recoveryCard: some View {
        VStack(alignment: .leading, spacing: CJSpacing.s) {
            Text("EASY SPIN BETWEEN CLIMBS")
                .font(CJFont.labelUpper)
                .foregroundStyle(CJColors.textSecondary)
            Picker("Easy spin", selection: $recoveryMin) {
                ForEach(BergSeries.recoveryMinuteOptions, id: \.self) { min in
                    Text("\(min) min").tag(min)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(CJSpacing.m)
        .background(CJColors.card)
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
    }

    private var rideButton: some View {
        Button {
            ridePlan = plan
        } label: {
            HStack(spacing: CJSpacing.s) {
                Image(systemName: "mountain.2.fill")
                Text(plan.map { "RIDE \($0.legCount) BERGS" } ?? "PICK TWO OR MORE")
            }
            .font(.system(size: 17, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, CJSpacing.l)
            .foregroundStyle(.white)
            .background(plan == nil ? CJColors.card : CJColors.accent)
            .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
        }
        .buttonStyle(.plain)
        .disabled(plan == nil)
    }
}

extension CourseRidePlan: Identifiable {
    var id: String { courseIDs.joined(separator: ",") + "@\(Int(recoverySec))" }
}
