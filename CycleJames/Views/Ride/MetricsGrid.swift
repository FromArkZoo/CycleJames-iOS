import SwiftUI

struct MetricsGrid: View {
    @EnvironmentObject private var ride: RideController

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: CJSpacing.s),
        GridItem(.flexible(), spacing: CJSpacing.s)
    ]

    var body: some View {
        VStack(spacing: CJSpacing.s) {
            HeroIntervalCard()
            LazyVGrid(columns: columns, spacing: CJSpacing.s) {
                MetricCard(
                    label: "Power",
                    value: valueOrDash(ride.rolling3sPower),
                    unit: "W",
                    emphasis: true,
                    tint: ride.rolling3sPower > 0 ? ride.currentZone.color : nil
                )
                MetricCard(
                    label: "Cadence",
                    value: valueOrDash(ride.currentCadence),
                    unit: "rpm"
                )
                MetricCard(
                    label: "Avg",
                    value: valueOrDash(ride.avgPower),
                    unit: "W"
                )
                MetricCard(
                    label: "Heart Rate",
                    value: valueOrDash(ride.currentHR),
                    unit: "bpm"
                )
                MetricCard(
                    label: "Peak",
                    value: valueOrDash(ride.peakPower),
                    unit: "W"
                )
                MetricCard(
                    label: "NP",
                    value: valueOrDash(ride.np),
                    unit: "W"
                )
                MetricCard(
                    label: "Elapsed",
                    value: ride.elapsed > 0 ? TimeFormat.mmss(ride.elapsed) : "--:--"
                )
                MetricCard(
                    label: "Remaining",
                    value: ride.remaining > 0 ? TimeFormat.mmss(ride.remaining) : "--:--"
                )
            }
        }
        .padding(.horizontal, CJSpacing.l)
    }

    private func valueOrDash(_ v: Int) -> String { v > 0 ? "\(v)" : "--" }
}
