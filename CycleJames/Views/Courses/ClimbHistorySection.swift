import SwiftUI
import SwiftData

/// Extra block on a History ride detail for 3D course rides ("Climb"):
/// the course profile, the climb time worked out from the recorded
/// distance samples, and distance, climbing and speed. A berg series lists
/// each climb's time instead of one profile.
struct ClimbHistorySection: View {
    let session: RideSessionModel

    private var courseID: String? { Self.courseID(of: session) }
    private var isSeries: Bool { session.workoutId == BergSeries.workoutID }

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
        /// A berg series' climbs, in order.
        var legs: [Leg] = []
    }

    private struct Leg {
        var courseID: String
        var name: String
        var climbTimeSec: Double?
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
        var legs: [Leg] = []
        if isSeries {
            for leg in CourseRideRecorder.courseLegs(workoutID: session.workoutId, samples: s) {
                let course = CourseCatalog.summary(id: leg.courseID)
                let time = course.flatMap {
                    CourseRideRecorder.climbTiming(samples: leg.samples, interval: session.sampleInterval,
                                                   startS: $0.climbStartS, endS: $0.climbEndS)?.seconds
                }
                legs.append(Leg(courseID: leg.courseID, name: course?.name ?? leg.courseID, climbTimeSec: time,
                                virtualPower: leg.samples.climbOnVirtualPower == true))
            }
        }
        return Stats(distanceM: ridden, climbingM: climbing, avgSpeedKph: avgSpeed, climbTimeSec: climbTime,
                     virtualPower: s.climbOnVirtualPower == true, legs: legs)
    }

    var body: some View {
        // Decodes the samples JSON, so work it out once per render.
        let stats = self.stats
        if summary != nil || stats != nil {
            VStack(alignment: .leading, spacing: CJSpacing.s) {
                Text(isSeries ? "BERG SERIES" : "3D CLIMB")
                    .font(CJFont.labelUpper)
                    .foregroundStyle(CJColors.textSecondary)
                if let summary {
                    CourseProfileSparkline(summary: summary, highlightsClimb: true)
                        .frame(height: 64)
                        .padding(CJSpacing.s)
                        .background(CJColors.card)
                        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
                }
                if let stats, isSeries {
                    seriesStats(stats)
                } else if let stats {
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

    @ViewBuilder
    private func seriesStats(_ stats: Stats) -> some View {
        let timed = stats.legs.filter { $0.climbTimeSec != nil }.count
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: CJSpacing.s) {
            tile("Climbs", "\(timed) of \(stats.legs.count)")
            tile("Distance", CourseFormat.distance(stats.distanceM))
            tile("Climbing", "+\(Int(stats.climbingM.rounded())) m")
            tile("Avg speed", stats.avgSpeedKph.map { String(format: "%.1f km/h", $0) } ?? "--")
        }
        VStack(spacing: 0) {
            ForEach(Array(stats.legs.enumerated()), id: \.offset) { i, leg in
                if i > 0 { Divider().overlay(CJColors.border) }
                HStack(spacing: CJSpacing.s) {
                    Text("\(i + 1)")
                        .font(CJFont.caption)
                        .foregroundStyle(CJColors.textMuted)
                        .frame(width: 16)
                    Text(leg.name)
                        .font(CJFont.bodyBold)
                        .foregroundStyle(CJColors.textPrimary)
                    Spacer(minLength: CJSpacing.s)
                    // This ride set the PB that stands.
                    if leg.climbTimeSec != nil, AppSettings.personalBestSessionID(courseID: leg.courseID) == session.id {
                        Image(systemName: "trophy.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(CJColors.positionMarker)
                            .accessibilityLabel("Personal best")
                    }
                    // A climb ridden on past without a time was started on it.
                    Text(leg.climbTimeSec.map(CourseFormat.climbTime) ?? (i < stats.legs.count - 1 ? "Not timed" : "Not finished"))
                        .font(leg.climbTimeSec == nil ? CJFont.caption : CJFont.bodyBold)
                        .foregroundStyle(leg.climbTimeSec == nil ? CJColors.textMuted : CJColors.textPrimary)
                        .monospacedDigit()
                }
                .padding(.vertical, CJSpacing.s)
                .padding(.horizontal, CJSpacing.m)
            }
        }
        .background(CJColors.card)
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
        if stats.legs.contains(where: { $0.climbTimeSec != nil && $0.virtualPower }) {
            Text("Climbs ridden on virtual power don't count as personal bests.")
                .font(CJFont.caption)
                .foregroundStyle(CJColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
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

/// Deletes a ride from History. A course ride (or a berg series) may have
/// set a course's personal best, so each PB it could hold is then worked
/// out again from the rides of that course that remain (or cleared if none
/// of them can hold it).
enum RideHistory {
    @MainActor
    static func delete(_ session: RideSessionModel, in context: ModelContext) {
        var courseIDs: [String] = []
        if let samples = session.samples {
            for leg in CourseRideRecorder.courseLegs(workoutID: session.workoutId, samples: samples)
            where !courseIDs.contains(leg.courseID) {
                courseIDs.append(leg.courseID)
            }
        }
        if courseIDs.isEmpty, let id = ClimbHistorySection.courseID(of: session) { courseIDs = [id] }
        context.delete(session)
        try? context.save()
        for courseID in courseIDs {
            CourseRideRecorder.recomputePersonalBest(courseID: courseID, from: rides(climbing: courseID, in: context))
        }
    }

    /// The rides in History that may hold a course's climb: its own and
    /// every berg series.
    @MainActor
    static func rides(climbing courseID: String, in context: ModelContext) -> [RideSessionModel] {
        let workoutID = CourseRideController.workoutID(courseID: courseID)
        let seriesID = BergSeries.workoutID
        return (try? context.fetch(FetchDescriptor<RideSessionModel>(
            predicate: #Predicate { $0.workoutId == workoutID || $0.workoutId == seriesID }
        ))) ?? []
    }
}
