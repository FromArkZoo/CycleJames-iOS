import SwiftUI

struct CompleteSummaryOverlay: View {
    let session: RideSessionModel
    var onDone: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: CJSpacing.l) {
                Text(session.partial ? "Ride Saved (Partial)" : "Workout Complete")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(CJColors.textPrimary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: CJSpacing.s) {
                    summary("Duration", TimeFormat.duration(session.durationSec))
                    summary("Avg Power", "\(session.avgPower)W")
                    summary("NP", "\(session.np)W")
                    summary("Avg Cadence", "\(session.avgCadence)rpm")
                    summary("Avg HR", "\(session.avgHR)bpm")
                    summary("IF", String(format: "%.2f", session.intensityFactor))
                    summary("TSS", "\(session.tss)")
                    summary("FTP", "\(session.ftp)W")
                }

                Button(action: onDone) {
                    Text("DONE")
                        .font(.system(size: 17, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .foregroundStyle(.white)
                        .background(CJColors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
                }
                .buttonStyle(.plain)
            }
            .padding(CJSpacing.xxl)
            .background(CJColors.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CJRadius.overlay))
            .padding(CJSpacing.l)
        }
    }

    private func summary(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label.uppercased())
                .font(CJFont.labelUpper)
                .foregroundStyle(CJColors.textSecondary)
            Text(value)
                .font(CJFont.metricSmall)
                .foregroundStyle(CJColors.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(CJSpacing.s)
        .background(CJColors.card)
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.small))
    }
}
