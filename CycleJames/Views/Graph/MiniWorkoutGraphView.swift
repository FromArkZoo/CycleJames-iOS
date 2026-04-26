import SwiftUI
import Charts

/// Compact graph for use in workout cards and history rows.
struct MiniWorkoutGraphView: View {
    let workout: Workout

    private struct Slice: Identifiable {
        let id = UUID()
        let startSec: Int
        let endSec: Int
        let percent: Double
        let color: Color
    }

    private var slices: [Slice] {
        var out: [Slice] = []
        var t = 0
        for iv in workout.intervals {
            switch iv {
            case .steady(_, let dur, let pct):
                out.append(Slice(startSec: t, endSec: t + dur, percent: pct, color: Zones.zone(forPercent: pct).color))
                t += dur
            case .ramp(_, let dur, let s, let e):
                let steps = 12
                let stepDur = max(1, dur / steps)
                for i in 0..<steps {
                    let progress = Double(i) / Double(steps)
                    let pct = s + (e - s) * progress
                    let from = t + i * stepDur
                    let to = (i == steps - 1) ? (t + dur) : (from + stepDur)
                    out.append(Slice(startSec: from, endSec: to, percent: pct, color: Zones.zone(forPercent: pct).color))
                }
                t += dur
            }
        }
        return out
    }

    private var maxPercent: Double {
        max((workout.intervals.map(\.maxPercent).max() ?? 100) + 10, 100)
    }

    var body: some View {
        Chart {
            ForEach(slices) { s in
                RectangleMark(
                    xStart: .value("from", s.startSec),
                    xEnd: .value("to", s.endSec),
                    yStart: .value("base", 0),
                    yEnd: .value("top", s.percent)
                )
                .foregroundStyle(s.color.opacity(0.7))
            }
        }
        .chartXScale(domain: 0...max(workout.totalDuration, 1))
        .chartYScale(domain: 0...maxPercent)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }
}
