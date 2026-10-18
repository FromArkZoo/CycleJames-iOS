import SwiftUI

/// "3D Climbs" entry card near the top of the Workouts tab.
struct ClimbsEntryCard: View {
    private let courses = CourseCatalog.all

    private var title: String {
        if courses.count == 1, let only = courses.first { return "Ride the \(only.name)" }
        return "\(courses.count) cobbled climbs"
    }

    private var subtitle: String {
        guard let first = courses.first else { return "Real climbs, rebuilt in 3D." }
        if courses.count == 1 {
            return "The real climb rebuilt in 3D from LiDAR: \(CourseFormat.distance(first.climbLengthM)) at "
                + "\(CourseFormat.grade(first.climbAvgGradePct)), up to \(CourseFormat.grade(first.climbMaxGradePct))."
        }
        return courses.map(\.name).joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CJSpacing.s) {
            HStack(spacing: CJSpacing.xs) {
                Image(systemName: "mountain.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("3D CLIMBS")
                    .font(CJFont.labelUpper)
                Text("NEW")
                    .font(.system(size: 9, weight: .heavy))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .foregroundStyle(CJColors.bgPrimary)
                    .background(CJColors.brandWarm1, in: Capsule())
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CJColors.textSecondary)
            }
            .foregroundStyle(CJColors.accent)

            HStack(alignment: .bottom, spacing: CJSpacing.m) {
                VStack(alignment: .leading, spacing: CJSpacing.xxs) {
                    Text(title)
                        .font(CJFont.title)
                        .foregroundStyle(CJColors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(subtitle)
                        .font(CJFont.body)
                        .foregroundStyle(CJColors.textSecondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let first = courses.first {
                    CourseProfileSparkline(summary: first, lineWidth: 1.2, headroom: 0.05)
                        .frame(width: 96, height: 46)
                }
            }
        }
        .padding(CJSpacing.l)
        .background(
            LinearGradient(
                colors: [CJColors.card, CJColors.bgSecondary],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: CJRadius.card)
                .stroke(CJColors.accent.opacity(0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.card))
        .contentShape(RoundedRectangle(cornerRadius: CJRadius.card))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the 3D climbs")
    }
}

/// Every course in `CourseCatalog`, one card each.
struct CourseListView: View {
    private let courses = CourseCatalog.all

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CJSpacing.m) {
                Text("Real climbs, rebuilt from 1 m LiDAR elevation, aerial imagery and building data. Your smart trainer feels every metre of gradient; no trainer? Ride with an on-screen power slider.")
                    .font(CJFont.body)
                    .foregroundStyle(CJColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, CJSpacing.s)

                if courses.isEmpty {
                    Text("No courses are installed.")
                        .font(CJFont.body)
                        .foregroundStyle(CJColors.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(CJSpacing.xxl)
                } else {
                    ForEach(courses) { course in
                        NavigationLink(value: CourseNav.detail(course.id)) {
                            CourseCard(summary: course)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, CJSpacing.l)
            .padding(.bottom, CJSpacing.xl)
        }
        .background(CJColors.bgPrimary.ignoresSafeArea())
        .navigationTitle("3D Climbs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(CJColors.bgSecondary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

struct CourseCard: View {
    let summary: CourseSummary

    private var personalBest: Double? { AppSettings.personalBestSeconds(courseID: summary.id) }
    private var cobblesM: Double { summary.lengthM(on: "cobbles") }

    var body: some View {
        VStack(alignment: .leading, spacing: CJSpacing.s) {
            HStack {
                Text(summary.region.uppercased())
                    .font(CJFont.labelUpper)
                    .foregroundStyle(CJColors.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                if cobblesM > 0 {
                    Text("COBBLES")
                        .font(CJFont.small)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(CourseGrade.cobbles)
                        .overlay(Capsule().stroke(CourseGrade.cobbles.opacity(0.7), lineWidth: 1))
                }
            }

            Text(summary.name)
                .font(CJFont.title)
                .foregroundStyle(CJColors.textPrimary)

            HStack(spacing: CJSpacing.l) {
                stat("Climb", CourseFormat.distance(summary.climbLengthM))
                stat("Avg", CourseFormat.grade(summary.climbAvgGradePct))
                stat("Max", CourseFormat.grade(summary.climbMaxGradePct), color: CourseGrade.labelColor(for: summary.climbMaxGradePct))
                stat("Gain", "+\(Int(summary.climbGainM.rounded())) m")
                stat("Route", CourseFormat.distance(summary.totalLengthM))
            }

            CourseProfileSparkline(summary: summary, highlightsClimb: true)
                .frame(height: 56)
                .padding(.top, CJSpacing.xxs)

            HStack(spacing: CJSpacing.xs) {
                Image(systemName: "stopwatch")
                    .font(.system(size: 12, weight: .semibold))
                if let personalBest {
                    Text("PB \(CourseFormat.climbTime(personalBest))")
                        .font(CJFont.bodyBold)
                        .monospacedDigit()
                        .foregroundStyle(CJColors.positionMarker)
                } else {
                    Text("No time set yet")
                        .font(CJFont.caption)
                        .foregroundStyle(CJColors.textMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CJColors.textMuted)
            }
            .foregroundStyle(CJColors.textSecondary)
        }
        .padding(CJSpacing.l)
        .background(CJColors.card)
        .overlay(RoundedRectangle(cornerRadius: CJRadius.card).stroke(CJColors.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.card))
        .contentShape(RoundedRectangle(cornerRadius: CJRadius.card))
    }

    private func stat(_ label: String, _ value: String, color: Color = CJColors.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label.uppercased())
                .font(CJFont.small)
                .foregroundStyle(CJColors.textMuted)
            Text(value)
                .font(CJFont.bodyBold)
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}
