import SwiftUI

struct CompleteSummaryOverlay: View {
    let session: RideSessionModel
    var onDone: () -> Void
    @State private var shareURL: URL?

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
                    summary("Peak Power", session.peakPower > 0 ? "\(session.peakPower)W" : "--")
                    summary("NP", "\(session.np)W")
                    summary("Avg Cadence", session.avgCadence > 0 ? "\(session.avgCadence)rpm" : "--")
                    summary("Peak Cadence", session.peakCadence > 0 ? "\(session.peakCadence)rpm" : "--")
                    summary("Avg HR", session.avgHR > 0 ? "\(session.avgHR)bpm" : "--")
                    summary("Peak HR", session.peakHR > 0 ? "\(session.peakHR)bpm" : "--")
                    summary("IF", String(format: "%.2f", session.intensityFactor))
                    summary("TSS", "\(session.tss)")
                }

                Button {
                    shareTCX()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Export to Strava / Garmin")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(CJColors.accent)
                    .overlay(
                        RoundedRectangle(cornerRadius: CJRadius.medium)
                            .stroke(CJColors.accent.opacity(0.5), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

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
        .sheet(item: Binding(
            get: { shareURL.map { URLWrapper(url: $0) } },
            set: { shareURL = $0?.url }
        )) { wrapper in
            ShareSheet(activityItems: [wrapper.url])
        }
    }

    private func shareTCX() {
        if let url = try? TCXExporter.writeFile(for: session) {
            shareURL = url
        }
    }

    private struct URLWrapper: Identifiable {
        let url: URL
        var id: URL { url }
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
