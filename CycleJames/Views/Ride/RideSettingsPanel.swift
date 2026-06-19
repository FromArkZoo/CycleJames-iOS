import SwiftUI

/// Compact in-ride settings overlay: ride mode + whole-ride intensity.
/// Presented over the ride; never pauses it.
struct RideSettingsPanel: View {
    @EnvironmentObject private var ride: RideController
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CJSpacing.m) {
            HStack {
                Text("Ride Settings").font(.system(size: 16, weight: .bold))
                    .foregroundStyle(CJColors.textPrimary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(CJColors.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close settings")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("MODE").font(CJFont.labelUpper).foregroundStyle(CJColors.textSecondary)
                Picker("Mode", selection: Binding(
                    get: { ride.mode },
                    set: { ride.setMode($0) }
                )) {
                    Text("ERG").tag(RideMode.erg)
                    Text("Free Ride").tag(RideMode.freeRide)
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("WHOLE-RIDE INTENSITY").font(CJFont.labelUpper)
                    .foregroundStyle(CJColors.textSecondary)
                HStack(spacing: CJSpacing.m) {
                    stepButton(systemName: "minus", label: "Decrease whole-ride power by 5 watts") {
                        ride.adjustWholeRide(byWatts: -5)
                    }
                    Text(offsetLabel)
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(CJColors.textPrimary)
                        .frame(minWidth: 120)
                    stepButton(systemName: "plus", label: "Increase whole-ride power by 5 watts") {
                        ride.adjustWholeRide(byWatts: 5)
                    }
                }
            }
        }
        .padding(CJSpacing.l)
        .background(CJColors.card)
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
        .overlay(RoundedRectangle(cornerRadius: CJRadius.medium).stroke(CJColors.border, lineWidth: 1))
        .frame(maxWidth: 360)
        .shadow(radius: 12)
    }

    private var offsetLabel: String {
        let w = ride.wholeRideOffsetWatts
        return w == 0 ? "Whole ride: 0 W" : String(format: "Whole ride: %+d W", w)
    }

    private func stepButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 40, height: 40)
                .foregroundStyle(.white)
                .background(CJColors.bgSecondary)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

#Preview {
    RideSettingsPanel(onClose: {})
        .environmentObject(RideController())
        .padding()
        .background(CJColors.bgPrimary)
}
