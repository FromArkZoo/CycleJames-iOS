import SwiftUI
import SwiftData

struct WorkoutsView: View {
    @EnvironmentObject private var ride: RideController
    @EnvironmentObject private var trainer: FTMSManager
    @EnvironmentObject private var hr: HRManager
    @Query private var customWorkouts: [CustomWorkoutModel]
    @State private var filterState = WorkoutFilterState()
    @State private var selectedWorkout: Workout?

    private var allWorkouts: [Workout] {
        let custom = customWorkouts.map { $0.toWorkout() }
        // Custom first; built-in not deduped by id since custom uses prefix `custom_`.
        return custom + BuiltInWorkouts.all
    }

    private var filtered: [Workout] {
        filterState.apply(to: allWorkouts)
    }

    var body: some View {
        NavigationStack {
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
            .navigationDestination(for: Workout.self) { w in
                WorkoutDetailView(workout: w)
            }
            .toolbarBackground(CJColors.bgSecondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
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
