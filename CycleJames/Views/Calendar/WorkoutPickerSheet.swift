import SwiftUI
import SwiftData

/// Modal sheet that lets the user pick a workout to schedule.
/// Favourites are pinned at the top, then Custom workouts, then Built-in.
struct WorkoutPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var favourites: FavouritesStore
    @Query private var customWorkouts: [CustomWorkoutModel]

    let scheduledFor: Date
    var onPick: (Workout) -> Void

    @State private var selectedCategory: WorkoutCategory?

    private var allWorkouts: [Workout] {
        customWorkouts.map { $0.toWorkout() } + BuiltInWorkouts.all
    }

    private var filtered: [Workout] {
        guard let cat = selectedCategory else { return allWorkouts }
        return allWorkouts.filter { $0.category == cat }
    }

    private var favouriteList: [Workout] {
        filtered.filter { favourites.isFavourite($0.id) }
    }

    private var customList: [Workout] {
        filtered.filter { $0.isCustom && !favourites.isFavourite($0.id) }
    }

    private var builtInList: [Workout] {
        filtered.filter { !$0.isCustom && !favourites.isFavourite($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CJSpacing.m) {
                    Text(headerLabel)
                        .font(CJFont.body)
                        .foregroundStyle(CJColors.textSecondary)
                        .padding(.horizontal, CJSpacing.l)

                    categoryChips

                    if !favouriteList.isEmpty {
                        section(title: "Favourites", systemImage: "heart.fill", iconColor: CJColors.danger, workouts: favouriteList)
                    }
                    if !customList.isEmpty {
                        section(title: "Custom", systemImage: "slider.horizontal.3", iconColor: CJColors.warning, workouts: customList)
                    }
                    if !builtInList.isEmpty {
                        section(title: "All workouts", systemImage: "bolt.heart", iconColor: CJColors.accent, workouts: builtInList)
                    }
                    if filtered.isEmpty {
                        Text("No workouts match this filter.")
                            .font(CJFont.body)
                            .foregroundStyle(CJColors.textMuted)
                            .frame(maxWidth: .infinity)
                            .padding(CJSpacing.xxl)
                    }
                }
                .padding(.bottom, CJSpacing.xl)
            }
            .background(CJColors.bgPrimary.ignoresSafeArea())
            .navigationTitle("Schedule a ride")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(CJColors.accent)
                }
            }
            .toolbarBackground(CJColors.bgSecondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    private var headerLabel: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMM yyyy"
        return "For \(f.string(from: scheduledFor))"
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CJSpacing.xs) {
                chip(label: "All", selected: selectedCategory == nil) { selectedCategory = nil }
                ForEach(WorkoutCategory.allCases) { cat in
                    chip(label: cat.rawValue, selected: selectedCategory == cat) { selectedCategory = cat }
                }
            }
            .padding(.horizontal, CJSpacing.l)
        }
    }

    private func chip(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(CJFont.button)
                .padding(.horizontal, CJSpacing.m)
                .padding(.vertical, CJSpacing.xs)
                .foregroundStyle(selected ? CJColors.bgPrimary : CJColors.textPrimary)
                .background(selected ? CJColors.accent : CJColors.bgSecondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func section(title: String, systemImage: String, iconColor: Color, workouts: [Workout]) -> some View {
        VStack(alignment: .leading, spacing: CJSpacing.s) {
            HStack(spacing: CJSpacing.xs) {
                Image(systemName: systemImage)
                    .foregroundStyle(iconColor)
                Text(title.uppercased())
                    .font(CJFont.labelUpper)
                    .foregroundStyle(CJColors.textSecondary)
            }
            .padding(.horizontal, CJSpacing.l)

            VStack(spacing: CJSpacing.s) {
                ForEach(workouts) { w in
                    Button {
                        onPick(w)
                        dismiss()
                    } label: {
                        WorkoutPickerRow(workout: w)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, CJSpacing.l)
        }
    }
}

private struct WorkoutPickerRow: View {
    let workout: Workout

    var body: some View {
        HStack(spacing: CJSpacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.name)
                    .font(CJFont.body)
                    .foregroundStyle(CJColors.textPrimary)
                    .lineLimit(1)
                Text("\(workout.category.rawValue) · \(TimeFormat.duration(workout.totalDuration))")
                    .font(CJFont.caption)
                    .foregroundStyle(CJColors.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CJColors.textMuted)
        }
        .padding(CJSpacing.m)
        .background(CJColors.card)
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
    }
}
