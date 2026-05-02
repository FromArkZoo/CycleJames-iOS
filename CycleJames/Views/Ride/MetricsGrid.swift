import SwiftUI

struct MetricsGrid: View {
    @EnvironmentObject private var ride: RideController

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: CJSpacing.s),
        GridItem(.flexible(), spacing: CJSpacing.s)
    ]

    var body: some View {
        VStack(spacing: CJSpacing.s) {
            heroIntervalCard
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
                    label: "Elapsed",
                    value: ride.elapsed > 0 ? TimeFormat.mmss(ride.elapsed) : "--:--"
                )
                MetricCard(
                    label: "Remaining",
                    value: ride.remaining > 0 ? TimeFormat.mmss(ride.remaining) : "--:--"
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
        }
        .padding(.horizontal, CJSpacing.l)
    }

    /// Full-width "what to do right now" card. Surfaces the active interval
    /// name, target wattage, and a big countdown — visible without scrolling
    /// even on smaller phones.
    @ViewBuilder
    private var heroIntervalCard: some View {
        let ctx = ride.currentIntervalContext
        let zone = ride.currentZone
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text((ctx?.interval.name ?? "Ready").uppercased())
                    .font(CJFont.labelUpper)
                    .foregroundStyle(zone.color)
                Spacer()
                Text(targetText)
                    .font(CJFont.bodyBold)
                    .foregroundStyle(CJColors.textPrimary)
                    .monospacedDigit()
            }
            HStack(alignment: .lastTextBaseline) {
                Text(intervalCountdown)
                    .font(CJFont.metricLarge)
                    .foregroundStyle(CJColors.textPrimary)
                    .monospacedDigit()
                Spacer()
                Text(zone.name)
                    .font(CJFont.caption)
                    .foregroundStyle(zone.color)
                    .padding(.horizontal, CJSpacing.s)
                    .padding(.vertical, 3)
                    .background(zone.color.opacity(0.18))
                    .clipShape(Capsule())
            }
        }
        .padding(CJSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(zone.color.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: CJRadius.medium)
                .stroke(zone.color.opacity(0.5), lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
    }

    private var intervalCountdown: String {
        guard let ctx = ride.currentIntervalContext else { return "--:--" }
        return TimeFormat.mmss(ctx.remaining)
    }

    private var targetText: String {
        ride.currentTarget > 0 ? "\(ride.currentTarget) W target" : "--"
    }

    private func valueOrDash(_ v: Int) -> String { v > 0 ? "\(v)" : "--" }
}
