import SwiftUI

struct CompleteSummaryOverlay: View {
    @EnvironmentObject private var favourites: FavouritesStore
    let session: RideSessionModel
    var onDone: () -> Void
    @State private var shareURL: URL?

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            ScrollView {
                VStack(spacing: CJSpacing.l) {
                    Text(session.partial ? "Ride Saved (Partial)" : "Workout Complete")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(CJColors.textPrimary)

                    if !session.workoutId.isEmpty {
                        Button {
                            favourites.toggle(session.workoutId)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: favourites.isFavourite(session.workoutId) ? "heart.fill" : "heart")
                                Text(favourites.isFavourite(session.workoutId) ? "Favourited" : "Add to Favourites")
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, CJSpacing.m)
                            .padding(.vertical, CJSpacing.s)
                            .foregroundStyle(favourites.isFavourite(session.workoutId) ? CJColors.danger : CJColors.textSecondary)
                            .overlay(
                                RoundedRectangle(cornerRadius: CJRadius.medium)
                                    .stroke((favourites.isFavourite(session.workoutId) ? CJColors.danger : CJColors.textMuted).opacity(0.5), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }

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

                    if let intervals = session.intervalSummaries, !intervals.isEmpty {
                        IntervalSummaryList(intervals: intervals)
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

/// Shared per-interval breakdown shown in the post-ride summary overlay and
/// in the history detail view. Each row pairs the prescribed target with the
/// average power actually held, tinted green/red against a ±5W tolerance.
struct IntervalSummaryList: View {
    let intervals: [IntervalSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: CJSpacing.xs) {
            Text("PER INTERVAL")
                .font(CJFont.labelUpper)
                .foregroundStyle(CJColors.textSecondary)
            VStack(spacing: CJSpacing.xxs) {
                ForEach(Array(intervals.enumerated()), id: \.offset) { idx, iv in
                    row(index: idx + 1, interval: iv)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(index: Int, interval: IntervalSummary) -> some View {
        HStack(spacing: CJSpacing.s) {
            Text("\(index).")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CJColors.textMuted)
                .frame(width: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(interval.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CJColors.textPrimary)
                    .lineLimit(1)
                Text(TimeFormat.mmss(interval.durationSec))
                    .font(.system(size: 11))
                    .foregroundStyle(CJColors.textMuted)
                    .monospacedDigit()
            }
            Spacer(minLength: CJSpacing.s)
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(interval.avgPower)W")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(avgColor(for: interval))
                    .monospacedDigit()
                Text("target \(interval.targetWatts)W")
                    .font(.system(size: 10))
                    .foregroundStyle(CJColors.textMuted)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, CJSpacing.s)
        .padding(.vertical, CJSpacing.xs)
        .background(CJColors.card)
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.small))
    }

    private func avgColor(for iv: IntervalSummary) -> Color {
        guard iv.targetWatts > 0, iv.avgPower > 0 else { return CJColors.textPrimary }
        let band = max(5, Int(Double(iv.targetWatts) * 0.02))
        if iv.avgPower < iv.targetWatts - band { return CJColors.danger }
        if iv.avgPower > iv.targetWatts + band { return CJColors.success }
        return CJColors.textPrimary
    }
}
