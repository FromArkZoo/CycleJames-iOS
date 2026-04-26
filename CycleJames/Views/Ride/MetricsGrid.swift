import SwiftUI

struct MetricsGrid: View {
    @EnvironmentObject private var ride: RideController

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: CJSpacing.s),
        GridItem(.flexible(), spacing: CJSpacing.s)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: CJSpacing.s) {
            MetricCard(
                label: "Power",
                value: valueOrDash(ride.rolling3sPower),
                unit: "W",
                emphasis: true,
                tint: ride.rolling3sPower > 0 ? ride.currentZone.color : nil
            )
            MetricCard(
                label: "Target",
                value: valueOrDash(ride.currentTarget),
                unit: "W",
                emphasis: true
            )
            MetricCard(
                label: "Cadence",
                value: valueOrDash(ride.currentCadence),
                unit: "rpm"
            )
            MetricCard(
                label: "Heart Rate",
                value: valueOrDash(ride.currentHR),
                unit: "bpm"
            )
            MetricCard(
                label: "Elapsed",
                value: ride.elapsed > 0 ? TimeFormat.mmss(ride.elapsed) : "--:--"
            )
            MetricCard(
                label: "Remaining",
                value: ride.remaining > 0 ? TimeFormat.mmss(ride.remaining) : "--:--"
            )
            MetricCard(
                label: "Interval",
                value: intervalLabel
            )
            MetricCard(
                label: "Zone",
                value: ride.currentZone.name,
                tint: ride.rolling3sPower > 0 ? ride.currentZone.color : nil
            )
            MetricCard(
                label: "NP",
                value: valueOrDash(ride.np),
                unit: "W"
            )
            MetricCard(
                label: "TSS",
                value: ride.tss > 0 ? "\(ride.tss)" : "--"
            )
        }
        .padding(.horizontal, CJSpacing.l)
    }

    private var intervalLabel: String {
        guard let ctx = ride.currentIntervalContext else { return "--" }
        return "\(ctx.interval.name) · \(TimeFormat.mmss(ctx.remaining))"
    }

    private func valueOrDash(_ v: Int) -> String { v > 0 ? "\(v)" : "--" }
}
