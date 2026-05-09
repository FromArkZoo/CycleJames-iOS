import SwiftUI

struct ControlsBar: View {
    @EnvironmentObject private var ride: RideController
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    var onStart: () -> Void
    var onStop: () -> Void

    private var compact: Bool { verticalSizeClass == .compact }
    private var sideButtonSize: CGFloat { compact ? 44 : 56 }
    private var primaryHeight: CGFloat { compact ? 44 : 56 }

    var body: some View {
        HStack(spacing: compact ? CJSpacing.s : CJSpacing.m) {
            controlButton(systemName: "backward.fill", label: "Skip to previous interval", isEnabled: isRideActive) {
                ride.skipBackward()
            }

            primaryButton

            if ride.state == .riding || ride.state == .paused {
                controlButton(systemName: "stop.fill", label: "Stop ride", color: CJColors.danger) {
                    onStop()
                }
            }

            controlButton(systemName: "forward.fill", label: "Skip to next interval", isEnabled: isRideActive) {
                ride.skipForward()
            }
        }
        .padding(.horizontal, compact ? CJSpacing.m : CJSpacing.l)
        .padding(.vertical, compact ? CJSpacing.s : CJSpacing.m)
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
                .font(.system(size: compact ? 16 : 18, weight: .heavy))
                .frame(maxWidth: .infinity, minHeight: primaryHeight)
                .foregroundStyle(.white)
                .background(primaryColor)
                .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
                .opacity(isCountdown ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isCountdown)
    }

    private func controlButton(systemName: String, label: String, isEnabled: Bool = true, color: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: compact ? 16 : 18, weight: .bold))
                .frame(width: sideButtonSize, height: sideButtonSize)
                .foregroundStyle(color ?? CJColors.textPrimary)
                .background(CJColors.card)
                .overlay(RoundedRectangle(cornerRadius: CJRadius.medium).stroke(CJColors.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
                .opacity(isEnabled ? 1.0 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }
}
