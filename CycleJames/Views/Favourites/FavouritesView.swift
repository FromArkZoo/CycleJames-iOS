import SwiftUI
import SwiftData

struct FavouritesView: View {
    @EnvironmentObject private var favourites: FavouritesStore
    @Query private var customWorkouts: [CustomWorkoutModel]
    @State private var navigationPath: [Workout] = []

    private var allWorkouts: [Workout] {
        let custom = customWorkouts.map { $0.toWorkout() }
        return custom + BuiltInWorkouts.all
    }

    private var favouriteWorkouts: [Workout] {
        allWorkouts.filter { favourites.isFavourite($0.id) }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(spacing: CJSpacing.m) {
                    ConnectionRow()
                    if favouriteWorkouts.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(spacing: CJSpacing.m) {
                            ForEach(favouriteWorkouts) { workout in
                                NavigationLink(value: workout) {
                                    WorkoutCard(workout: workout)
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
            .navigationTitle("Favourites")
            .navigationDestination(for: Workout.self) { w in
                WorkoutDetailView(workout: w)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { BrandMark() }
            }
            .toolbarBackground(CJColors.bgSecondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    private var emptyState: some View {
        VStack(spacing: CJSpacing.m) {
            Image(systemName: "heart")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(CJColors.textMuted)
            Text("No favourites yet")
                .font(CJFont.title)
                .foregroundStyle(CJColors.textPrimary)
            Text("Tap the heart on any workout to save it here.")
                .font(CJFont.body)
                .foregroundStyle(CJColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(CJSpacing.xxl)
        .frame(maxWidth: .infinity)
    }
}
