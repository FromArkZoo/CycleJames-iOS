import SwiftUI

struct WorkoutDetailView: View {
    let workout: Workout
    @EnvironmentObject private var ride: RideController
    @EnvironmentObject private var trainer: FTMSManager
    @State private var goToRide = false
    @State private var edited: Workout

    init(workout: Workout) {
        self.workout = workout
        self._edited = State(initialValue: workout)
    }

    private var ftp: Int { AppSettings.ftp }
    private var hasEdits: Bool { edited.intervals != workout.intervals }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CJSpacing.l) {
                VStack(alignment: .leading, spacing: CJSpacing.xs) {
                    Text(workout.category.rawValue.uppercased())
                        .font(CJFont.labelUpper)
                        .foregroundStyle(CJColors.accent)
                    Text(workout.name)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(CJColors.textPrimary)
                    Text(workout.description)
                        .font(CJFont.body)
                        .foregroundStyle(CJColors.textSecondary)
                    Text("Duration · \(TimeFormat.duration(workout.totalDuration))")
                        .font(CJFont.caption)
                        .foregroundStyle(CJColors.textMuted)
                        .padding(.top, 2)
                }

                WorkoutGraphView(
                    workout: edited,
                    ftp: ftp,
                    elapsed: 0,
                    showWatts: true,
                    onIntervalEdit: { idx, deltaW in
                        edited = edited.adjustingInterval(at: idx, byWatts: deltaW, ftp: ftp)
                    }
                )
                .frame(height: 220)
                .background(Color.black.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))

                Text("Hold a bar and drag to fine-tune that interval.")
                    .font(CJFont.caption)
                    .foregroundStyle(CJColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)

                adjustBar

                IntervalListView(workout: edited, ftp: ftp)
            }
            .padding(.horizontal, CJSpacing.l)
            .padding(.bottom, 120)
        }
        .background(CJColors.bgPrimary.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            startButton
                .padding(CJSpacing.l)
                .background(CJColors.bgPrimary.opacity(0.95))
        }
        .navigationDestination(isPresented: $goToRide) {
            RideView()
                .navigationBarBackButtonHidden(true)
        }
    }

    @ViewBuilder
    private var adjustBar: some View {
        HStack(spacing: CJSpacing.s) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Overall power")
                    .font(CJFont.small)
                    .foregroundStyle(CJColors.textSecondary)
                Text(hasEdits ? "Edited" : "5W steps")
                    .font(.system(size: 10))
                    .foregroundStyle(hasEdits ? CJColors.accent : CJColors.textMuted)
            }
            Spacer()
            if hasEdits {
                Button {
                    edited = workout
                } label: {
                    Text("Reset")
                        .font(CJFont.small)
                        .padding(.horizontal, CJSpacing.s)
                        .padding(.vertical, 6)
                        .foregroundStyle(CJColors.accent)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(CJColors.accent.opacity(0.5), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            adjustButton(systemName: "minus") {
                edited = edited.adjustingAllIntervals(byWatts: -5, ftp: ftp)
            }
            adjustButton(systemName: "plus") {
                edited = edited.adjustingAllIntervals(byWatts: 5, ftp: ftp)
            }
        }
        .padding(.horizontal, CJSpacing.s)
        .padding(.vertical, 8)
        .background(CJColors.bgSecondary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
    }

    @ViewBuilder
    private func adjustButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 36, height: 36)
                .foregroundStyle(.white)
                .background(CJColors.card)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: edited.intervals)
    }

    @ViewBuilder
    private var startButton: some View {
        Button {
            ride.select(edited)
            goToRide = true
        } label: {
            Text("START WORKOUT")
                .font(.system(size: 17, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, CJSpacing.l)
                .foregroundStyle(.white)
                .background(trainer.connectionState == .connected ? CJColors.accent : CJColors.accentDim)
                .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
        }
        .buttonStyle(.plain)
    }
}

struct IntervalListView: View {
    let workout: Workout
    let ftp: Int

    var body: some View {
        VStack(alignment: .leading, spacing: CJSpacing.xs) {
            Text("Intervals")
                .font(CJFont.title)
                .foregroundStyle(CJColors.textPrimary)
            ForEach(Array(workout.intervals.enumerated()), id: \.offset) { _, iv in
                row(iv)
            }
        }
    }

    @ViewBuilder
    private func row(_ iv: Interval) -> some View {
        let mid = iv.midPercent
        let zone = Zones.zone(forPercent: mid)
        let durationStr: String = {
            let m = iv.duration / 60
            let s = iv.duration % 60
            return s > 0 ? "\(m)m \(s)s" : "\(m)min"
        }()
        let watts: String = {
            switch iv {
            case .steady(_, _, let p):
                let w = Int((p / 100.0 * Double(ftp)).rounded())
                return "\(w)W (\(Int(p))%)"
            case .ramp(_, _, let s, let e):
                let sw = Int((s / 100.0 * Double(ftp)).rounded())
                let ew = Int((e / 100.0 * Double(ftp)).rounded())
                return "\(sw)→\(ew)W (\(Int(s))–\(Int(e))%)"
            }
        }()

        HStack(spacing: CJSpacing.s) {
            Text(zone.name)
                .font(CJFont.small)
                .padding(.horizontal, CJSpacing.s)
                .padding(.vertical, 3)
                .foregroundStyle(zone.color)
                .background(zone.color.opacity(0.15))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(zone.color, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(iv.name)
                .font(CJFont.body)
                .foregroundStyle(CJColors.textPrimary)
            Spacer()
            Text(watts)
                .font(CJFont.caption)
                .foregroundStyle(CJColors.textSecondary)
                .monospacedDigit()
            Text(durationStr)
                .font(CJFont.caption)
                .foregroundStyle(CJColors.textMuted)
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, CJSpacing.s)
        .background(CJColors.bgSecondary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
