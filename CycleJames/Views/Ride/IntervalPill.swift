import SwiftUI

/// Pill-sized interval status used in the landscape Ride layout. Matches
/// MetricCard dimensions so it can sit alongside Power / HR / Elapsed in a
/// single row, while still conveying the active interval, target wattage,
/// and time-remaining countdown.
struct IntervalPill: View {
    @EnvironmentObject private var ride: RideController

    var body: some View {
        let ctx = ride.currentIntervalContext
        let zone = ride.currentZone
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text((ctx?.interval.name ?? "Ready").uppercased())
                    .font(CJFont.labelUpper)
                    .foregroundStyle(zone.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if ride.currentTarget > 0 {
                    Text("· \(ride.currentTarget)W")
                        .font(CJFont.labelUpper)
                        .foregroundStyle(CJColors.textSecondary)
                        .monospacedDigit()
                }
            }
            Text(intervalCountdown)
                .font(.system(size: 28, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(CJColors.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CJSpacing.s)
        .padding(.vertical, 4)
        .background(zone.color.opacity(0.18))
        .overlay(
            RoundedRectangle(cornerRadius: CJRadius.medium)
                .stroke(zone.color.opacity(0.6), lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
    }

    private var intervalCountdown: String {
        guard let ctx = ride.currentIntervalContext else { return "--:--" }
        return TimeFormat.mmss(ctx.remaining)
    }
}
