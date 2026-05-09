import SwiftUI

/// Small "CJ" gradient wordmark with training-zone bars below — anchors
/// brand identity on tabs whose principal title describes the screen
/// ("Favourites", "Calendar", etc.) rather than the app.
struct BrandMark: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("CJ")
                .font(.system(size: 28, weight: .thin, design: .default))
                .italic()
                .foregroundStyle(CJColors.brandGradient)
            TrainingZoneBars(barWidth: 5, barHeight: 1, gap: 1)
        }
        .accessibilityLabel("CycleJames")
    }
}

/// The four training-zone color bars sampled from the app icon.
/// Sized via parameters so the same row can sit under a small CJ mark
/// or a larger "CycleJames" wordmark while preserving icon proportions.
struct TrainingZoneBars: View {
    let barWidth: CGFloat
    let barHeight: CGFloat
    let gap: CGFloat

    var body: some View {
        HStack(spacing: gap) {
            bar(CJColors.zoneBar1)
            bar(CJColors.zoneBar2)
            bar(CJColors.zoneBar3)
            bar(CJColors.zoneBar4)
        }
    }

    private func bar(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: barHeight / 2)
            .fill(color)
            .frame(width: barWidth, height: barHeight)
    }
}
