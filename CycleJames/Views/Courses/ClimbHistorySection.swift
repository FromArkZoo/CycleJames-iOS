import SwiftUI
import SwiftData

/// Extra block on a History ride detail for 3D course rides ("Climb"):
/// the course profile, the climb time worked out from the recorded
/// distance samples, and distance, climbing and speed.
struct ClimbHistorySection: View {
    let session: RideSessionModel

    private var courseID: String? { Self.courseID(of: session) }

    /// The course a 3D course ride was ridden on; nil for workouts.
    static func courseID(of session: RideSessionModel) -> String? {
        let prefix = CourseRideController.workoutIDPrefix
        guard session.workoutId.hasPrefix(prefix) else { return nil }
        return String(session.workoutId.dropFirst(prefix.count))
    }

    private var summary: CourseSummary? { courseID.flatMap(CourseCatalog.summary(id:)) }

    private struct Stats {
        var distanceM: Double
        var climbingM: Double
        var avgSpeedKph: Double?
        var climbTimeSec: Double?
        /// Part of the timed climb was ridden on virtual power.
        var virtualPower: Bool
    }

    private var stats: Stats? {
        guard let s = session.samples, let dist = s.distanceM, !dist.isEmpty else { return nil }
        let interval = Double(max(session.sampleInterval, 1))
        var climbing = 0.0
        if let alt = s.altitudeM, alt.count >= 2 {
            for i in 1..<alt.count where alt[i] > alt[i - 1] { climbing += alt[i] - alt[i - 1] }
        }
        let speeds = s.speedMps ?? []
        let avgSpeed = speeds.isEmpty ? nil : speeds.reduce(0, +) / Double(speeds.count) * 3.6
        // Each sample holds the position at the end of its chunk.
        let start = max(0, (dist.first ?? 0) - (speeds.first ?? 0) * interval)
        let ridden = max(0, (dist.last ?? 0) - start)

        // The same timing the personal best is worked out from after a delete.
        let climbTime = summary.flatMap {
            CourseRideRecorder.climbTiming(samples: s, interval: session.sampleInterval,
                                           startS: $0.climbStartS, endS: $0.climbEndS)?.seconds
        }
        return Stats(distanceM: ridden, climbingM: climbing, avgSpeedKph: avgSpeed, climbTimeSec: climbTime,
                     virtualPower: s.climbOnVirtualPower == true)
    }

    var body: some View {
        // Decodes the samples JSON, so work it out once per render.
        let stats = self.stats
        if summary != nil || stats != nil {
            VStack(alignment: .leading, spacing: CJSpacing.s) {
                Text("3D CLIMB")
                    .font(CJFont.labelUpper)
                    .foregroundStyle(CJColors.textSecondary)
                if let summary {
                    CourseProfileSparkline(summary: summary, highlightsClimb: true)
                        .frame(height: 64)
                        .padding(CJSpacing.s)
                        .background(CJColors.card)
                        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
                }
                if let stats {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: CJSpacing.s) {
                        tile("Climb time", stats.climbTimeSec.map(CourseFormat.climbTime) ?? "Not timed")
                        tile("Distance", CourseFormat.distance(stats.distanceM))
                        tile("Climbing", "+\(Int(stats.climbingM.rounded())) m")
                        tile("Avg speed", stats.avgSpeedKph.map { String(format: "%.1f km/h", $0) } ?? "--")
                    }
                    if stats.climbTimeSec != nil, stats.virtualPower {
                        Text("Ridden on virtual power, so this climb doesn't count as a personal best.")
                            .font(CJFont.caption)
                            .foregroundStyle(CJColors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if stats.climbTimeSec != nil, let id = courseID, let pb = AppSettings.personalBestSeconds(courseID: id) {
                        Text("Personal best on this climb: \(CourseFormat.climbTime(pb))")
                            .font(CJFont.caption)
                            .foregroundStyle(CJColors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(CJFont.labelUpper)
                .foregroundStyle(CJColors.textSecondary)
            Text(value)
                .font(CJFont.metricSmall)
                .foregroundStyle(CJColors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CJSpacing.m)
        .background(CJColors.card)
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
    }
}

/// Deletes a ride from History. A course ride may have set the course's
/// personal best, so the PB is then worked out again from the course rides
/// that remain (or cleared if none of them can hold it).
enum RideHistory {
    @MainActor
    static func delete(_ session: RideSessionModel, in context: ModelContext) {
        let courseID = ClimbHistorySection.courseID(of: session)
        context.delete(session)
        try? context.save()
        guard let courseID else { return }
        let workoutID = CourseRideController.workoutID(courseID: courseID)
        let remaining = (try? context.fetch(FetchDescriptor<RideSessionModel>(
            predicate: #Predicate { $0.workoutId == workoutID }
        ))) ?? []
        CourseRideRecorder.recomputePersonalBest(courseID: courseID, from: remaining)
    }
}
