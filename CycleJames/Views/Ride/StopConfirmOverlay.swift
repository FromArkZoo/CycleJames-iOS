import SwiftUI

struct StopConfirmOverlay: View {
    var onSave: () -> Void
    var onDiscard: () -> Void
    var onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: CJSpacing.l) {
                Text("Stop Ride?")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(CJColors.textPrimary)
                Text("You have an active ride in progress.")
                    .font(CJFont.body)
                    .foregroundStyle(CJColors.textSecondary)

                VStack(spacing: CJSpacing.s) {
                    button(title: "Save & Stop", color: CJColors.accent, action: onSave)
                    button(title: "Discard & Stop", color: CJColors.danger, action: onDiscard)
                    button(title: "Cancel", color: CJColors.card, action: onCancel)
                }
            }
            .padding(CJSpacing.xxl)
            .background(CJColors.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CJRadius.overlay))
            .padding(CJSpacing.l)
        }
    }

    private func button(title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(.white)
                .background(color)
                .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
        }
        .buttonStyle(.plain)
    }
}
