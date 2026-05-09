import SwiftUI

struct WorkoutCard: View {
    @EnvironmentObject private var favourites: FavouritesStore
    let workout: Workout
    var isSelected: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: CJSpacing.s) {
            HStack {
                Text(workout.category.rawValue.uppercased())
                    .font(CJFont.labelUpper)
                    .foregroundStyle(CJColors.accent)
                Spacer()
                Text(TimeFormat.duration(workout.totalDuration))
                    .font(CJFont.caption)
                    .foregroundStyle(CJColors.textSecondary)
                    .monospacedDigit()
                    .padding(.trailing, 28)
            }

            Text(workout.name)
                .font(CJFont.title)
                .foregroundStyle(CJColors.textPrimary)
                .lineLimit(1)

            Text(workout.description)
                .font(CJFont.body)
                .foregroundStyle(CJColors.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            MiniWorkoutGraphView(workout: workout)
                .frame(height: 56)
                .padding(.top, CJSpacing.xs)

            if workout.isCustom {
                Text("CUSTOM")
                    .font(CJFont.small)
                    .foregroundStyle(CJColors.warning)
                    .padding(.top, 2)
            }
        }
        .padding(CJSpacing.l)
        .background(CJColors.card)
        .overlay(alignment: .topTrailing) {
            FavouriteButton(workoutID: workout.id)
                .padding(CJSpacing.m)
        }
        .overlay(
            RoundedRectangle(cornerRadius: CJRadius.card)
                .stroke(isSelected ? CJColors.accent : CJColors.border, lineWidth: isSelected ? 2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.card))
    }
}

struct FavouriteButton: View {
    @EnvironmentObject private var favourites: FavouritesStore
    let workoutID: String

    var body: some View {
        Button {
            favourites.toggle(workoutID)
        } label: {
            Image(systemName: favourites.isFavourite(workoutID) ? "heart.fill" : "heart")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(favourites.isFavourite(workoutID) ? CJColors.danger : CJColors.textMuted)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(favourites.isFavourite(workoutID) ? "Remove from favourites" : "Add to favourites")
    }
}
