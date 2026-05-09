import SwiftUI

struct IntervalEditBar: View {
    @EnvironmentObject private var ride: RideController
    var onShowUpcoming: () -> Void
    var onShowAddInterval: () -> Void

    var body: some View {
        let ctx = ride.currentIntervalContext
        HStack(spacing: CJSpacing.s) {
            HStack(spacing: 6) {
                adjustButton(systemName: "minus", label: "Decrease current interval power by 5 watts", enabled: ctx != nil) {
                    ride.adjustCurrentInterval(byWatts: -5)
                }
                Text("5W")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CJColors.textSecondary)
                adjustButton(systemName: "plus", label: "Increase current interval power by 5 watts", enabled: ctx != nil) {
                    ride.adjustCurrentInterval(byWatts: 5)
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
        }
        .padding(.horizontal, CJSpacing.s)
        .padding(.vertical, 6)
        .background(CJColors.bgSecondary.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
    }

    private func adjustButton(systemName: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 32, height: 32)
                .foregroundStyle(.white)
                .background(CJColors.card)
                .clipShape(Circle())
                .opacity(enabled ? 1.0 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}
