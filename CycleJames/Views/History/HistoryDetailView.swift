import SwiftUI
import SwiftData
import Charts

struct HistoryDetailView: View {
    let session: RideSessionModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private struct ChartPoint: Identifiable {
        let id = UUID()
        let timeSec: Int
        let power: Int
        let target: Int
    }

    private var points: [ChartPoint] {
        guard let s = session.samples else { return [] }
        let interval = max(session.sampleInterval, 1)
        var out: [ChartPoint] = []
        out.reserveCapacity(s.power.count)
        for i in 0..<s.power.count {
            out.append(ChartPoint(
                timeSec: i * interval,
                power: s.power[i],
                target: i < s.targets.count ? s.targets[i] : 0
            ))
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CJSpacing.l) {
                header
                if !points.isEmpty {
                    chart
                }
                statsGrid
                deleteButton
            }
            .padding(CJSpacing.l)
        }
        .background(CJColors.bgPrimary.ignoresSafeArea())
        .navigationTitle(session.workoutName)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.workoutName)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(CJColors.textPrimary)
            Text("\(formattedDate) · \(session.category)")
                .font(CJFont.caption)
                .foregroundStyle(CJColors.textMuted)
            if session.partial {
                Text("Partial ride")
                    .font(CJFont.caption)
                    .foregroundStyle(CJColors.warning)
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        Chart {
            ForEach(points) { p in
                LineMark(
                    x: .value("Time", p.timeSec),
                    y: .value("Power", p.power),
                    series: .value("Series", "Power")
                )
                .foregroundStyle(CJColors.accent)
                .interpolationMethod(.linear)

                AreaMark(
                    x: .value("Time", p.timeSec),
                    y: .value("Power", p.power)
                )
                .foregroundStyle(CJColors.accent.opacity(0.15))
                .interpolationMethod(.linear)

                if p.target > 0 {
                    LineMark(
                        x: .value("Time", p.timeSec),
                        y: .value("Target", p.target),
                        series: .value("Series", "Target")
                    )
                    .foregroundStyle(CJColors.positionMarker.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .interpolationMethod(.linear)
                }
            }
        }
        .frame(height: 180)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                AxisValueLabel().foregroundStyle(CJColors.textMuted)
            }
        }
        .chartXAxis {
            AxisMarks(values: xAxisStops) { v in
                if let sec = v.as(Int.self) {
                    AxisValueLabel { Text("\(sec / 60)m") }
                        .foregroundStyle(CJColors.textMuted)
                }
                AxisGridLine().foregroundStyle(Color.white.opacity(0.05))
            }
        }
        .padding(CJSpacing.s)
        .background(CJColors.card)
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
    }

    private var chartXStride: Int {
        session.durationSec > 3600 ? 600 : 300
    }

    private var xAxisStops: [Int] {
        Array(stride(from: 0, through: session.durationSec, by: chartXStride))
    }

    @ViewBuilder
    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: CJSpacing.s) {
            stat("Duration", TimeFormat.duration(session.durationSec))
            stat("Avg Power", "\(session.avgPower)W")
            stat("Peak Power", session.peakPower > 0 ? "\(session.peakPower)W" : "--")
            stat("NP", "\(session.np)W")
            stat("IF", String(format: "%.2f", session.intensityFactor))
            stat("TSS", "\(session.tss)")
            stat("Avg Cadence", session.avgCadence > 0 ? "\(session.avgCadence)rpm" : "--")
            stat("Peak Cadence", session.peakCadence > 0 ? "\(session.peakCadence)rpm" : "--")
            stat("Avg HR", session.avgHR > 0 ? "\(session.avgHR)bpm" : "--")
            stat("Peak HR", session.peakHR > 0 ? "\(session.peakHR)bpm" : "--")
            stat("FTP", "\(session.ftp)W")
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(CJFont.labelUpper)
                .foregroundStyle(CJColors.textSecondary)
            Text(value)
                .font(CJFont.metricSmall)
                .foregroundStyle(CJColors.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CJSpacing.m)
        .background(CJColors.card)
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            modelContext.delete(session)
            try? modelContext.save()
            dismiss()
        } label: {
            Label("Delete Ride", systemImage: "trash")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(CJColors.danger)
    }

    private var formattedDate: String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM yyyy · HH:mm"
        return f.string(from: session.date)
    }
}
