import SwiftUI

/// Full-width "what to do right now" card. Surfaces the active interval
/// name, target wattage, and a big countdown — visible without scrolling
/// even on smaller phones. Hosts the Skip button so it's right next to
/// the interval it acts on (and out of the cramped edit bar above).
struct HeroIntervalCard: View {
    @EnvironmentObject private var ride: RideController
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var compact: Bool { verticalSizeClass == .compact }

    var body: some View {
        let ctx = ride.currentIntervalContext
        let zone = ride.currentZone
        let canSkip = ctx != nil
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
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
                    .font(compact
                          ? .system(size: 28, weight: .heavy, design: .rounded).monospacedDigit()
                          : CJFont.metricLarge)
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
                Button {
                    ride.skipForward()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "forward.end.fill")
                        Text("Skip")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: compact ? 26 : 30)
                    .foregroundStyle(.white)
                    .background(zone.color.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(!canSkip)
                .opacity(canSkip ? 1.0 : 0.4)
                .accessibilityLabel("Skip current interval")
            }
        }
        .padding(.horizontal, compact ? CJSpacing.s : CJSpacing.m)
        .padding(.vertical, compact ? CJSpacing.xs : CJSpacing.m)
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
}
