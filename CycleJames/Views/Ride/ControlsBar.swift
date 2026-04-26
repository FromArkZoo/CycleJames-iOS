import SwiftUI

struct ControlsBar: View {
    @EnvironmentObject private var ride: RideController
    var onStart: () -> Void
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: CJSpacing.m) {
            controlButton(systemName: "backward.fill", isEnabled: isRideActive) {
                ride.skipBackward()
            }

            primaryButton

            if ride.state == .riding || ride.state == .paused {
                controlButton(systemName: "stop.fill", color: CJColors.danger) {
                    onStop()
                }
            }

            controlButton(systemName: "forward.fill", isEnabled: isRideActive) {
                ride.skipForward()
            }
        }
        .padding(.horizontal, CJSpacing.l)
        .padding(.vertical, CJSpacing.m)
        .background(CJColors.bgSecondary)
    }

    private var isRideActive: Bool {
        ride.state == .riding || ride.state == .paused
    }

    private var primaryLabel: String {
        switch ride.state {
        case .ready, .setup: "START"
        case .countdown: "…"
        case .riding: "PAUSE"
        case .paused: "RESUME"
        case .completed: "DONE"
        }
    }

    private var primaryColor: Color {
        switch ride.state {
        case .riding: CJColors.warning
        case .paused: CJColors.success
        default: CJColors.accent
        }
    }

    private var primaryButton: some View {
        let isCountdown = ride.state == .countdown
        return Button {
            switch ride.state {
            case .ready: onStart()
            case .riding, .paused: ride.pauseOrResume()
            default: break
            }
        } label: {
            Text(primaryLabel)
                .font(.system(size: 18, weight: .heavy))
                .frame(maxWidth: .infinity, minHeight: 56)
                .foregroundStyle(.white)
                .background(primaryColor)
                .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
                .opacity(isCountdown ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isCountdown)
    }

    private func controlButton(systemName: String, isEnabled: Bool = true, color: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .bold))
                .frame(width: 56, height: 56)
                .foregroundStyle(color ?? CJColors.textPrimary)
                .background(CJColors.card)
                .overlay(RoundedRectangle(cornerRadius: CJRadius.medium).stroke(CJColors.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
                .opacity(isEnabled ? 1.0 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}
