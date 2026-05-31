import SwiftUI
import SwiftData

struct WorkoutsView: View {
    @EnvironmentObject private var ride: RideController
    @EnvironmentObject private var trainer: FTMSManager
    @EnvironmentObject private var hr: HRManager
    @Query private var customWorkouts: [CustomWorkoutModel]
    @State private var filterState = WorkoutFilterState()
    @State private var selectedWorkout: Workout?
    @State private var navigationPath: [Workout] = []
    @State private var showSettings = false

    private var allWorkouts: [Workout] {
        let custom = customWorkouts.map { $0.toWorkout() }
        // Custom first; built-in not deduped by id since custom uses prefix `custom_`.
        return custom + BuiltInWorkouts.all
    }

    private var filtered: [Workout] {
        filterState.apply(to: allWorkouts)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(spacing: CJSpacing.m) {
                    ConnectionRow()
                    WorkoutFilterBar(state: $filterState)
                    if filtered.isEmpty {
                        Text("No workouts match the current filters.")
                            .font(CJFont.body)
                            .foregroundStyle(CJColors.textMuted)
                            .padding(CJSpacing.xxl)
                    } else {
                        LazyVStack(spacing: CJSpacing.m) {
                            ForEach(filtered) { workout in
                                NavigationLink(value: workout) {
                                    WorkoutCard(workout: workout, isSelected: selectedWorkout?.id == workout.id)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, CJSpacing.l)
                    }
                }
                .padding(.bottom, CJSpacing.xl)
            }
            .background(CJColors.bgPrimary.ignoresSafeArea())
            .navigationTitle("CycleJames")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Workout.self) { w in
                WorkoutDetailView(workout: w)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 4) {
                        Text("CycleJames")
                            .font(.system(size: 22, weight: .thin, design: .default))
                            .italic()
                            .foregroundStyle(CJColors.brandGradient)
                        TrainingZoneBars(barWidth: 22, barHeight: 3, gap: 1.7)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(CJColors.textPrimary)
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .toolbarBackground(CJColors.bgSecondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear { applyScreenshotPush() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    /// Honour `-screenshotWorkout <prefix>` launch arg by pushing to the
    /// matching workout's detail screen on first appear. Used only by the
    /// screenshot capture script. No-op in production.
    private func applyScreenshotPush() {
        guard navigationPath.isEmpty else { return }
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-screenshotWorkout"), idx + 1 < args.count else { return }
        let prefix = args[idx + 1]
        if let match = allWorkouts.first(where: { $0.id.contains(prefix) || $0.name.lowercased().contains(prefix.lowercased()) }) {
            navigationPath = [match]
        }
    }
}

struct ConnectionRow: View {
    @EnvironmentObject private var trainer: FTMSManager
    @EnvironmentObject private var hr: HRManager
    @State private var showTrainerSheet = false
    @State private var showHRSheet = false

    var body: some View {
        HStack(spacing: CJSpacing.s) {
            connectButton(
                title: trainer.connectionState == .connected ? "Trainer ✓" : "Connect Trainer",
                connected: trainer.connectionState == .connected
            ) {
                if trainer.connectionState == .connected {
                    trainer.disconnect()
                } else {
                    showTrainerSheet = true
                }
            }
            connectButton(
                title: hr.connectionState == .connected ? "HR ✓" : "Connect HR",
                connected: hr.connectionState == .connected
            ) {
                if hr.connectionState == .connected {
                    hr.disconnect()
                } else {
                    showHRSheet = true
                }
            }
        }
        .padding(.horizontal, CJSpacing.l)
        .padding(.top, CJSpacing.s)
        .sheet(isPresented: $showTrainerSheet) {
            TrainerScanSheet(manager: trainer)
        }
        .sheet(isPresented: $showHRSheet) {
            HRScanSheet(manager: hr)
        }
    }

    private func connectButton(title: String, connected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: CJSpacing.xs) {
                Circle()
                    .fill(connected ? CJColors.success : CJColors.textMuted)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(CJFont.button)
            }
            .padding(.horizontal, CJSpacing.m)
            .padding(.vertical, CJSpacing.s)
            .frame(maxWidth: .infinity)
            .foregroundStyle(CJColors.textPrimary)
            .background(CJColors.card)
            .overlay(RoundedRectangle(cornerRadius: CJRadius.medium).stroke(CJColors.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
        }
        .buttonStyle(.plain)
    }
}
