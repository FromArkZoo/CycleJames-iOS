import SwiftUI

struct IntervalEditBar: View {
    @EnvironmentObject private var ride: RideController
    var onShowUpcoming: () -> Void
    var onShowAddInterval: () -> Void
    var onShowSettings: () -> Void

    var body: some View {
        HStack(spacing: CJSpacing.s) {
            HStack(spacing: 6) {
                adjustButton(systemName: "minus", label: "Decrease whole-ride power by 5 watts") {
                    ride.adjustWholeRide(byWatts: -5)
                }
                VStack(spacing: 0) {
                    Text("Whole ride")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(CJColors.textSecondary)
                    Text(IntensityReadout.wholeRide(offsetWatts: ride.wholeRideOffsetWatts))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(CJColors.textPrimary)
                }
                adjustButton(systemName: "plus", label: "Increase whole-ride power by 5 watts") {
                    ride.adjustWholeRide(byWatts: 5)
                }
            }
            Spacer(minLength: CJSpacing.s)
            Button(action: onShowUpcoming) {
                HStack(spacing: 4) {
                    Image(systemName: "list.bullet.rectangle")
                    Text("Queue")
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, CJSpacing.m)
                .frame(height: 32)
                .foregroundStyle(.white)
                .background(CJColors.card)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(CJColors.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            Button(action: onShowAddInterval) {
                HStack(spacing: 4) {
                    Image(systemName: "plus.rectangle.on.rectangle")
                    Text("Add")
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, CJSpacing.m)
                .frame(height: 32)
                .foregroundStyle(.white)
                .background(CJColors.card)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(CJColors.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            Button(action: onShowSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.white)
                    .background(CJColors.card)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(CJColors.border, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ride settings")
        }
        .padding(.horizontal, CJSpacing.s)
        .padding(.vertical, 6)
        .background(CJColors.bgSecondary.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
    }

    private func adjustButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 32, height: 32)
                .foregroundStyle(.white)
                .background(CJColors.card)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

#Preview {
    IntervalEditBar(onShowUpcoming: {}, onShowAddInterval: {}, onShowSettings: {})
        .environmentObject(RideController())
        .padding()
        .background(CJColors.bgPrimary)
}
