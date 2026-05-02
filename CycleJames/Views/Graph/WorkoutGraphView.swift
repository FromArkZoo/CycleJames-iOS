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
    }

    private struct PlacedLabel: Identifiable {
        let id = UUID()
        let name: String
        let watts: String?
        let x: CGFloat
        let y: CGFloat
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
        var t = 0
        var out: [IntervalLabel] = []
        for iv in workout.intervals {
            let mid = Double(t) + Double(iv.duration) / 2
            let pct = iv.midPercent
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
            out.append(IntervalLabel(midSec: mid, percent: pct, name: iv.name, watts: watts))
            t += iv.duration
        }
        return out
    }

    private func placedLabels(proxy: ChartProxy, frame: CGRect) -> [PlacedLabel] {
        let gap: CGFloat = 4
        var lastRight: CGFloat = -.infinity
        var placed: [PlacedLabel] = []
        for label in labels {
            guard let xPos = proxy.position(forX: label.midSec),
                  let yPos = proxy.position(forY: label.percent) else { continue }
            let halfWidth = estimatedHalfWidth(name: label.name, watts: label.watts)
            let minCenter = frame.minX + halfWidth
            let maxCenter = frame.maxX - halfWidth
            // Frame too narrow for this label — skip rather than squash.
            if minCenter > maxCenter { continue }
            let rawCenter = xPos + frame.minX
            let center = min(max(rawCenter, minCenter), maxCenter)
            let left = center - halfWidth
            let right = center + halfWidth
            if left < lastRight + gap { continue }
            let y = max(yPos + frame.minY - 14, frame.minY + 12)
            placed.append(PlacedLabel(name: label.name, watts: label.watts, x: center, y: y))
            lastRight = right
        }
        return placed
    }

    /// Approximate half-width of the rendered label pill, in points. Width is
    /// the wider of the name (10pt medium) and watts (10pt bold) lines, plus
    /// 5pt of horizontal padding on each side from the dark backing pill.
    /// Used to detect overlap with neighbours and clamp to the plot frame.
    private func estimatedHalfWidth(name: String, watts: String?) -> CGFloat {
        let nameWidth = CGFloat(name.count) * 6.2
        let wattsWidth = watts.map { CGFloat($0.count) * 6.4 } ?? 0
        return max(nameWidth, wattsWidth) / 2 + 7
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
                    ForEach(placedLabels(proxy: proxy, frame: frame)) { p in
                        VStack(spacing: 1) {
                            Text(p.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .fixedSize()
                            if let w = p.watts {
                                Text(w)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .fixedSize()
                            }
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                        .position(x: p.x, y: p.y)
                        .allowsHitTesting(false)
                    }

                    // Live drag-edit readout — big, prominent watts number so
                    // the user can see what they're dialing in without
                    // squinting at the small per-bar label.
                    if let idx = dragIntervalIndex,
                       workout.intervals.indices.contains(idx) {
                        dragReadout(for: workout.intervals[idx])
                            .position(x: frame.midX, y: frame.minY + 28)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: hapticTick)
    }

    @ViewBuilder
    private func dragReadout(for interval: Interval) -> some View {
        let zone = Zones.zone(forPercent: interval.midPercent)
        VStack(spacing: 2) {
            Text(interval.name.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.75))
                .lineLimit(1)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(dragWattsString(interval))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text("W")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
            Text("\(Int(interval.midPercent.rounded()))% FTP · \(zone.name)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(zone.color)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(zone.color.opacity(0.7), lineWidth: 1.5)
        )
    }

    private func dragWattsString(_ iv: Interval) -> String {
        switch iv {
        case .steady(_, _, let p):
            return "\(Int((p / 100.0 * Double(ftp)).rounded()))"
        case .ramp(_, _, let s, let e):
            let sw = Int((s / 100.0 * Double(ftp)).rounded())
            let ew = Int((e / 100.0 * Double(ftp)).rounded())
            return "\(sw)→\(ew)"
        }
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
