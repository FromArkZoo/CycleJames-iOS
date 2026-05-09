import SwiftUI

struct ReschedulePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let scheduled: ScheduledRideModel
    var onPick: (Date) -> Void

    @State private var newDate: Date

    init(scheduled: ScheduledRideModel, onPick: @escaping (Date) -> Void) {
        self.scheduled = scheduled
        self.onPick = onPick
        self._newDate = State(initialValue: scheduled.date)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: CJSpacing.l) {
                Text(scheduled.workoutName)
                    .font(CJFont.title)
                    .foregroundStyle(CJColors.textPrimary)
                    .padding(.horizontal, CJSpacing.l)

                DatePicker(
                    "Reschedule to",
                    selection: $newDate,
                    in: Calendar(identifier: .gregorian).startOfDay(for: Date())...,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .tint(CJColors.accent)
                .padding(.horizontal, CJSpacing.l)

                Spacer()

                Button {
                    onPick(newDate)
                    dismiss()
                } label: {
                    Text("Reschedule")
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
            .navigationTitle("Reschedule")
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
