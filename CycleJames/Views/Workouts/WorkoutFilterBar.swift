import SwiftUI

struct WorkoutFilterBar: View {
    @Binding var state: WorkoutFilterState

    var body: some View {
        VStack(alignment: .leading, spacing: CJSpacing.s) {
            // Search
            HStack(spacing: CJSpacing.s) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(CJColors.textSecondary)
                TextField("Search workouts...", text: $state.search)
                    .textFieldStyle(.plain)
                    .foregroundStyle(CJColors.textPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .padding(.horizontal, CJSpacing.m)
            .padding(.vertical, CJSpacing.s)
            .background(CJColors.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CJSpacing.xs) {
                    chip(label: "All", selected: state.category == nil) { state.category = nil }
                    ForEach(WorkoutCategory.allCases) { cat in
                        chip(label: cat.rawValue, selected: state.category == cat) { state.category = cat }
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CJSpacing.xs) {
                    ForEach(WorkoutFiltering.durations) { d in
                        chip(label: d.label, selected: state.duration.label == d.label) {
                            state.duration = d
                        }
                    }
                }
            }

            HStack {
                Text("Sort").font(CJFont.caption).foregroundStyle(CJColors.textSecondary)
                Picker("Sort", selection: $state.sort) {
                    ForEach(WorkoutFiltering.SortBy.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(CJColors.accent)
                Spacer()
            }
        }
        .padding(.horizontal, CJSpacing.l)
        .padding(.vertical, CJSpacing.s)
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
}
