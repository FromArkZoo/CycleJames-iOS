import SwiftUI

struct WorkoutCard: View {
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
        .overlay(
            RoundedRectangle(cornerRadius: CJRadius.card)
                .stroke(isSelected ? CJColors.accent : CJColors.border, lineWidth: isSelected ? 2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.card))
    }
}
