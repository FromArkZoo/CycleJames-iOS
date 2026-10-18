import SwiftUI
import Charts

/// Consecutive profile points sharing one gradient band, drawn as one filled
/// run so neighbouring fills don't show hairline seams.
private struct GradeRun: Identifiable {
    let id: Int
    let band: Int
    let points: [CourseSummary.ProfilePoint]
}

private func gradeRuns(_ profile: [CourseSummary.ProfilePoint]) -> [GradeRun] {
    guard profile.count >= 2 else { return [] }
    var runs: [GradeRun] = []
    var current: [CourseSummary.ProfilePoint] = [profile[0]]
    // A segment's colour comes from the mean gradient of its two ends.
    var band = CourseGrade.band(for: (profile[0].gradePct + profile[1].gradePct) / 2)
    for i in 1..<profile.count {
        current.append(profile[i])
        let nextBand = i + 1 < profile.count
            ? CourseGrade.band(for: (profile[i].gradePct + profile[i + 1].gradePct) / 2)
            : band
        if nextBand != band || i == profile.count - 1 {
            runs.append(GradeRun(id: runs.count, band: band, points: current))
            current = [profile[i]]
            band = nextBand
        }
    }
    return runs
}

/// Small filled elevation profile coloured by gradient, for cards, the
/// loading screen and the ride HUD. Optional position marker.
struct CourseProfileSparkline: View {
    let summary: CourseSummary
    /// Distance along the route to mark, metres.
    var positionS: Double? = nil
    /// Tints the timed climb's span behind the profile.
    var highlightsClimb: Bool = false
    var lineWidth: CGFloat = 1.5
    /// Empty space above the highest point, as a fraction of the height.
    var headroom: CGFloat = 0.12

    var body: some View {
        Canvas { context, size in
            let profile = summary.profile
            guard profile.count >= 2, let last = profile.last else { return }
            let minE = profile.map(\.elev).min() ?? 0
            let maxE = profile.map(\.elev).max() ?? 1
            let span = max(maxE - minE, 1)
            let total = max(last.s, 1)
            let top = size.height * headroom
            func x(_ s: Double) -> CGFloat { CGFloat(s / total) * size.width }
            func y(_ e: Double) -> CGFloat {
                top + (1 - CGFloat((e - minE) / span)) * (size.height - top)
            }

            if highlightsClimb {
                let rect = CGRect(x: x(summary.climbStartS), y: 0,
                                  width: x(summary.climbEndS) - x(summary.climbStartS), height: size.height)
                context.fill(Path(rect), with: .color(.white.opacity(0.07)))
            }

            for run in gradeRuns(profile) {
                var path = Path()
                path.move(to: CGPoint(x: x(run.points[0].s), y: size.height))
                for p in run.points { path.addLine(to: CGPoint(x: x(p.s), y: y(p.elev))) }
                path.addLine(to: CGPoint(x: x(run.points[run.points.count - 1].s), y: size.height))
                path.closeSubpath()
                context.fill(path, with: .color(CourseGrade.color(band: run.band).opacity(0.85)))
            }

            var line = Path()
            line.move(to: CGPoint(x: x(profile[0].s), y: y(profile[0].elev)))
            for p in profile.dropFirst() { line.addLine(to: CGPoint(x: x(p.s), y: y(p.elev))) }
            context.stroke(line, with: .color(.white.opacity(0.9)),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

            if let positionS {
                let px = x(min(max(positionS, 0), total))
                let py = y(summary.elevation(at: positionS))
                var rule = Path()
                rule.move(to: CGPoint(x: px, y: 0))
                rule.addLine(to: CGPoint(x: px, y: size.height))
                context.stroke(rule, with: .color(CJColors.positionMarker.opacity(0.7)), lineWidth: 1)
                let r: CGFloat = 5
                let dot = Path(ellipseIn: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2))
                context.fill(dot, with: .color(CJColors.positionMarker))
                context.stroke(dot, with: .color(.black.opacity(0.6)), lineWidth: 1.5)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Elevation profile of \(summary.name)")
    }
}

/// Swatches explaining the gradient colours.
struct GradeLegend: View {
    var showsCobbles: Bool = false

    var body: some View {
        HStack(spacing: CJSpacing.s) {
            ForEach(CourseGrade.legend, id: \.label) { item in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(item.color).frame(width: 10, height: 10)
                    Text(item.label)
                        .font(CJFont.small)
                        .foregroundStyle(CJColors.textSecondary)
                        .lineLimit(1)
                }
            }
            if showsCobbles {
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(CourseGrade.cobbles).frame(width: 10, height: 10)
                    Text("Cobbles")
                        .font(CJFont.small)
                        .foregroundStyle(CJColors.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .minimumScaleFactor(0.8)
    }
}

/// Full elevation profile for the course detail page: filled by gradient,
/// the timed climb highlighted, cobbled sections as a strip along the
/// bottom, and the climb start, steepest point and summit labelled.
struct CourseProfileChart: View {
    let summary: CourseSummary

    private var minElev: Double { summary.profile.map(\.elev).min() ?? 0 }
    private var maxElev: Double { summary.profile.map(\.elev).max() ?? 1 }
    private var relief: Double { max(maxElev - minElev, 10) }
    /// Bottom of the filled area; the cobbles strip sits below it.
    private var areaBase: Double { minElev - relief * 0.08 }
    private var stripHeight: Double { relief * 0.07 }
    private var yMin: Double { areaBase - stripHeight - relief * 0.03 }
    private var yMax: Double { maxElev + relief * 0.32 }
    /// Top of the climb-start and summit rules; their labels sit above it,
    /// inside the plot.
    private var ruleTop: Double { maxElev + relief * 0.14 }
    private var length: Double { summary.profile.last?.s ?? summary.totalLengthM }

    private var cobbleSections: [CourseSummary.SurfaceSection] {
        summary.surfaceSections.filter { $0.surface == "cobbles" }
    }

    private var steepest: CourseFile.Landmark? { summary.landmarks(kind: "steepest").first }

    /// Distance ticks, dropping one too close to the end for its label.
    private var xTicks: [Double] {
        Array(stride(from: 0, through: length, by: xStride)).filter { $0 == 0 || length - $0 >= xStride * 0.45 }
    }

    private var xStride: Double {
        switch length {
        case ..<1600: 200
        case ..<4000: 500
        case ..<10_000: 1000
        default: 2000
        }
    }

    var body: some View {
        Chart {
            RectangleMark(
                xStart: .value("Climb start", summary.climbStartS),
                xEnd: .value("Summit", summary.climbEndS),
                yStart: .value("Bottom", areaBase),
                yEnd: .value("Top", yMax)
            )
            .foregroundStyle(Color.white.opacity(0.06))

            ForEach(gradeRuns(summary.profile)) { run in
                ForEach(run.points, id: \.s) { p in
                    AreaMark(
                        x: .value("Distance", p.s),
                        yStart: .value("Base", areaBase),
                        yEnd: .value("Elevation", p.elev),
                        series: .value("Run", run.id)
                    )
                    .foregroundStyle(CourseGrade.color(band: run.band).opacity(0.9))
                    .interpolationMethod(.linear)
                }
            }

            ForEach(summary.profile, id: \.s) { p in
                LineMark(
                    x: .value("Distance", p.s),
                    y: .value("Elevation", p.elev),
                    series: .value("Series", "outline")
                )
                .foregroundStyle(Color.white.opacity(0.9))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.linear)
            }

            ForEach(cobbleSections, id: \.fromS) { section in
                RectangleMark(
                    xStart: .value("From", section.fromS),
                    xEnd: .value("To", section.toS),
                    yStart: .value("Strip bottom", areaBase - stripHeight),
                    yEnd: .value("Strip top", areaBase)
                )
                .foregroundStyle(CourseGrade.cobbles)
                .annotation(position: .overlay, alignment: .center) {
                    Text(section.surface.capitalized)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
            }

            RuleMark(
                x: .value("Climb start", summary.climbStartS),
                yStart: .value("Bottom", areaBase),
                yEnd: .value("Top", ruleTop)
            )
            .foregroundStyle(Color.white.opacity(0.55))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .annotation(position: .top, alignment: .trailing, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                marker("Climb start", systemImage: "flag.fill")
            }

            RuleMark(
                x: .value("Summit", summary.climbEndS),
                yStart: .value("Bottom", areaBase),
                yEnd: .value("Top", ruleTop)
            )
            .foregroundStyle(Color.white.opacity(0.55))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .annotation(position: .top, alignment: .trailing, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                marker("Summit \(Int(summary.summitElevationM.rounded())) m", systemImage: "flag.checkered")
            }

            if let steepest {
                PointMark(
                    x: .value("Steepest", steepest.s),
                    y: .value("Elevation", summary.elevation(at: steepest.s))
                )
                .symbolSize(40)
                .foregroundStyle(Color.white)
                .annotation(position: .leading, alignment: .center, spacing: 4) {
                    Text(CourseFormat.grade(summary.climbMaxGradePct))
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(CourseGrade.darkRed, in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .chartXScale(domain: 0...length)
        .chartYScale(domain: yMin...yMax)
        .chartXAxis {
            AxisMarks(values: xTicks) { v in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                // Centred under its grid line (the default sits to its right);
                // the first starts at the plot's edge so it isn't dropped.
                AxisValueLabel(anchor: (v.as(Double.self) ?? 0) <= 0 ? .topLeading : .top) {
                    if let m = v.as(Double.self) {
                        // "0.5 km", "1 km", "1.5 km": ticks can be 500 m apart.
                        Text(length >= 2000 ? String(format: "%g km", (m / 100).rounded() / 10) : "\(Int(m))")
                    }
                }
                .foregroundStyle(CJColors.textMuted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel {
                    if let m = v.as(Double.self), m >= areaBase { Text("\(Int(m)) m") }
                }
                .foregroundStyle(CJColors.textMuted)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private func marker(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(CJColors.textPrimary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
    }

    private var accessibilityText: String {
        "Elevation profile. Timed climb \(CourseFormat.distance(summary.climbLengthM)) at "
            + "\(CourseFormat.grade(summary.climbAvgGradePct)) average, steepest "
            + "\(CourseFormat.grade(summary.climbMaxGradePct)), summit at "
            + "\(Int(summary.summitElevationM.rounded())) metres."
    }
}
