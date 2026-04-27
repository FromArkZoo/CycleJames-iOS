import SwiftUI
import Charts

/// Stepped/sloped power profile chart, with zone-coloured fills and an
/// elapsed marker. Used for previews and live ride view.
struct WorkoutGraphView: View {
    let workout: Workout
    let ftp: Int
    let elapsed: Int
    var showWatts: Bool = false
    var showFTPLine: Bool = true
    var showElapsedMarker: Bool = true
    var showAxisLabels: Bool = true
    var compact: Bool = false
    /// Optional callback for drag-to-edit. Receives (intervalIndex, wattsDelta) where the
    /// delta is incremental (5W step) since the last emit.
    var onIntervalEdit: ((Int, Int) -> Void)? = nil

    @State private var dragIntervalIndex: Int? = nil
    @State private var lastEmittedWatts: Int = 0
    @State private var hapticTick: Int = 0

    private struct Slice: Identifiable {
        let id = UUID()
        let startSec: Int
        let endSec: Int
        let percent: Double
        let zoneColor: Color
        let isComplete: Bool
        var midSec: Double { (Double(startSec) + Double(endSec)) / 2 }
    }

    private struct IntervalLabel: Identifiable {
        let id = UUID()
        let midSec: Double
        let percent: Double
        let name: String
        let watts: String?
        let isWide: Bool
    }

    private var slices: [Slice] {
        var out: [Slice] = []
        var t = 0
        for iv in workout.intervals {
            switch iv {
            case .steady(_, let dur, let pct):
                let zone = Zones.zone(forPercent: pct)
                let isComplete = (t + dur) <= elapsed
                let isPartial = !isComplete && t < elapsed
                if isPartial {
                    // split at elapsed
                    out.append(Slice(startSec: t, endSec: elapsed, percent: pct, zoneColor: zone.color, isComplete: true))
                    out.append(Slice(startSec: elapsed, endSec: t + dur, percent: pct, zoneColor: zone.color, isComplete: false))
                } else {
                    out.append(Slice(startSec: t, endSec: t + dur, percent: pct, zoneColor: zone.color, isComplete: isComplete))
                }
                t += dur
            case .ramp(_, let dur, let startPct, let endPct):
                // Slice into ~24 sub-rects so colour follows zone changes mid-ramp.
                let steps = 24
                let stepDur = max(1, dur / steps)
                for s in 0..<steps {
                    let progress = Double(s) / Double(steps)
                    let pct = startPct + (endPct - startPct) * progress
                    let sliceStart = t + s * stepDur
                    let sliceEnd = (s == steps - 1) ? (t + dur) : (sliceStart + stepDur)
                    let zone = Zones.zone(forPercent: pct)
                    let isComplete = sliceEnd <= elapsed
                    out.append(Slice(startSec: sliceStart, endSec: sliceEnd, percent: pct, zoneColor: zone.color, isComplete: isComplete))
                }
                t += dur
            }
        }
        return out
    }

    private var labels: [IntervalLabel] {
        guard !compact else { return [] }
        let total = workout.totalDuration
        var t = 0
        var out: [IntervalLabel] = []
        for iv in workout.intervals {
            let mid = Double(t) + Double(iv.duration) / 2
            let pct = iv.midPercent
            let durationFraction = Double(iv.duration) / Double(max(total, 1))
            let isWide = durationFraction > 0.04
            var watts: String?
            if showWatts {
                switch iv {
                case .steady(_, _, let pp):
                    watts = "\(Int((pp / 100.0 * Double(ftp)).rounded()))W"
                case .ramp(_, _, let s, let e):
                    let sw = Int((s / 100.0 * Double(ftp)).rounded())
                    let ew = Int((e / 100.0 * Double(ftp)).rounded())
                    watts = "\(sw)→\(ew)W"
                }
            }
            out.append(IntervalLabel(midSec: mid, percent: pct, name: iv.name, watts: watts, isWide: isWide))
            t += iv.duration
        }
        return out
    }

    private var maxPercent: Double {
        let m = workout.intervals.map(\.maxPercent).max() ?? 100
        return max(m + 15, 100)
    }

    private var totalDuration: Int { workout.totalDuration }

    var body: some View {
        Chart {
            // Power profile (zone-coloured rectangles).
            ForEach(slices) { slice in
                RectangleMark(
                    xStart: .value("Start", slice.startSec),
                    xEnd: .value("End", slice.endSec),
                    yStart: .value("Base", 0),
                    yEnd: .value("Top", slice.percent)
                )
                .foregroundStyle(slice.zoneColor.opacity(slice.isComplete ? 0.4 : 0.85))
            }

            if showFTPLine {
                RuleMark(y: .value("FTP", 100))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color.white.opacity(0.2))
                    .annotation(position: .topLeading, alignment: .leading) {
                        Text("FTP")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
            }

            if showElapsedMarker, elapsed > 0, elapsed < totalDuration {
                RuleMark(x: .value("Elapsed", elapsed))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(CJColors.positionMarker)
            }
        }
        .chartXScale(domain: 0...max(totalDuration, 1))
        .chartYScale(domain: 0...maxPercent)
        .chartXAxis {
            if showAxisLabels {
                AxisMarks(values: .stride(by: totalDuration > 3600 ? 600 : 300)) { value in
                    if let sec = value.as(Int.self) {
                        AxisValueLabel {
                            Text(TimeFormat.mmss(sec))
                                .font(.system(size: 9))
                                .foregroundStyle(Color.white.opacity(0.4))
                        }
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let plotFrame = proxy.plotFrame {
                    let frame = geo[plotFrame]
                    if onIntervalEdit != nil {
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                            .gesture(makeEditGesture(proxy: proxy, plotSize: frame.size))
                    }
                    ForEach(labels) { label in
                        if let xPos = proxy.position(forX: label.midSec),
                           let yPos = proxy.position(forY: label.percent) {
                            VStack(spacing: 2) {
                                if label.isWide {
                                    Text(label.name)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Color.white.opacity(0.85))
                                        .lineLimit(1)
                                }
                                if let w = label.watts, label.isWide {
                                    Text(w)
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Color.white.opacity(0.95))
                                }
                            }
                            .position(
                                x: xPos + frame.minX,
                                y: max(yPos + frame.minY - 14, frame.minY + 12)
                            )
                            .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: hapticTick)
    }

    private func intervalIndex(forSecond t: Int) -> Int? {
        var cum = 0
        for (i, iv) in workout.intervals.enumerated() {
            if t < cum + iv.duration { return i }
            cum += iv.duration
        }
        return workout.intervals.indices.last
    }

    private func makeEditGesture(proxy: ChartProxy, plotSize: CGSize) -> some Gesture {
        let press = LongPressGesture(minimumDuration: 0.18)
        let drag = DragGesture(minimumDistance: 0, coordinateSpace: .local)
        return press.sequenced(before: drag)
            .onChanged { value in
                switch value {
                case .first:
                    break
                case .second(true, let dragValue?):
                    guard plotSize.height > 0 else { return }
                    if dragIntervalIndex == nil {
                        if let t = proxy.value(atX: dragValue.startLocation.x, as: Int.self) {
                            dragIntervalIndex = intervalIndex(forSecond: t)
                            lastEmittedWatts = 0
                        }
                    }
                    guard let idx = dragIntervalIndex else { return }
                    let pixelsPerPercent = plotSize.height / maxPercent
                    let percentDelta = -Double(dragValue.translation.height) / pixelsPerPercent
                    let rawWatts = percentDelta / 100.0 * Double(ftp)
                    let totalDeltaW = Int((rawWatts / 5).rounded()) * 5
                    let stepDelta = totalDeltaW - lastEmittedWatts
                    if stepDelta != 0 {
                        lastEmittedWatts = totalDeltaW
                        hapticTick &+= 1
                        onIntervalEdit?(idx, stepDelta)
                    }
                default:
                    break
                }
            }
            .onEnded { _ in
                dragIntervalIndex = nil
                lastEmittedWatts = 0
            }
    }
}
