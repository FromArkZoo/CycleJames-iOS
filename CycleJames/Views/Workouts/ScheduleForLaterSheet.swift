import SwiftUI

struct ScheduleForLaterSheet: View {
    @Environment(\.dismiss) private var dismiss
    let workout: Workout
    var onPick: (Date) -> Void

    @State private var date: Date

    init(workout: Workout, onPick: @escaping (Date) -> Void) {
        self.workout = workout
        self.onPick = onPick
        let g = Calendar(identifier: .gregorian)
        let tomorrow = g.date(byAdding: .day, value: 1, to: g.startOfDay(for: Date())) ?? Date()
        self._date = State(initialValue: tomorrow)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: CJSpacing.l) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(workout.category.rawValue.uppercased())
                        .font(CJFont.labelUpper)
                        .foregroundStyle(CJColors.accent)
                    Text(workout.name)
                        .font(CJFont.title)
                        .foregroundStyle(CJColors.textPrimary)
                }
                .padding(.horizontal, CJSpacing.l)

                DatePicker(
                    "Schedule for",
                    selection: $date,
                    in: Calendar(identifier: .gregorian).startOfDay(for: Date())...,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .tint(CJColors.accent)
                .padding(.horizontal, CJSpacing.l)

                Spacer()

                Button {
                    onPick(date)
                    dismiss()
                } label: {
                    Text("Schedule")
                        .font(.system(size: 17, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, CJSpacing.l)
                        .foregroundStyle(.white)
                        .background(CJColors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, CJSpacing.l)
                .padding(.bottom, CJSpacing.l)
            }
            .padding(.top, CJSpacing.l)
            .background(CJColors.bgPrimary.ignoresSafeArea())
            .navigationTitle("Schedule for later")
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
}
