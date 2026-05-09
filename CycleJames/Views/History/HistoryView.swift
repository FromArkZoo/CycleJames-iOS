import SwiftUI
import SwiftData

struct HistoryView: View {
    @Query(sort: \RideSessionModel.date, order: .reverse) private var sessions: [RideSessionModel]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    VStack(spacing: CJSpacing.l) {
                        Image(systemName: "bolt.heart")
                            .font(.system(size: 56))
                            .foregroundStyle(CJColors.textMuted)
                        Text("No rides recorded yet.")
                            .font(CJFont.body)
                            .foregroundStyle(CJColors.textSecondary)
                        Text("Complete a workout to see it here.")
                            .font(CJFont.caption)
                            .foregroundStyle(CJColors.textMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: CJSpacing.m) {
                            ForEach(sessions) { session in
                                NavigationLink(value: session.id) {
                                    HistoryRow(session: session)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(CJSpacing.l)
                    }
                }
            }
            .background(CJColors.bgPrimary.ignoresSafeArea())
            .navigationTitle("History")
            .navigationDestination(for: UUID.self) { id in
                if let s = sessions.first(where: { $0.id == id }) {
                    HistoryDetailView(session: s)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { BrandMark() }
            }
            .toolbarBackground(CJColors.bgSecondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}

struct HistoryRow: View {
    let session: RideSessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: CJSpacing.s) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.workoutName)
                        .font(CJFont.title)
                        .foregroundStyle(CJColors.textPrimary)
                    Text(formattedDate)
                        .font(CJFont.caption)
                        .foregroundStyle(CJColors.textMuted)
                }
                Spacer()
                if session.partial {
                    Text("Partial")
                        .font(CJFont.small)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(CJColors.warning)
                        .background(CJColors.warning.opacity(0.15))
                        .clipShape(Capsule())
                }
            }

            HStack(spacing: CJSpacing.l) {
                stat(label: "Duration", value: TimeFormat.duration(session.durationSec))
                stat(label: "Avg", value: "\(session.avgPower)W")
                stat(label: "Peak", value: session.peakPower > 0 ? "\(session.peakPower)W" : "--")
                stat(label: "NP", value: "\(session.np)W")
            }
            HStack(spacing: CJSpacing.l) {
                stat(label: "TSS", value: "\(session.tss)")
                stat(label: "IF", value: String(format: "%.2f", session.intensityFactor))
                stat(label: "HR", value: session.avgHR > 0 ? "\(session.avgHR)bpm" : "--")
                stat(label: "Cadence", value: session.avgCadence > 0 ? "\(session.avgCadence)rpm" : "--")
            }
        }
        .padding(CJSpacing.l)
        .background(CJColors.card)
        .overlay(RoundedRectangle(cornerRadius: CJRadius.card).stroke(CJColors.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.card))
    }

    private var formattedDate: String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM yyyy · HH:mm"
        return f.string(from: session.date)
    }

    private func stat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label.uppercased())
                .font(CJFont.small)
                .foregroundStyle(CJColors.textMuted)
            Text(value)
                .font(CJFont.bodyBold)
                .foregroundStyle(CJColors.textPrimary)
                .monospacedDigit()
        }
    }
}
