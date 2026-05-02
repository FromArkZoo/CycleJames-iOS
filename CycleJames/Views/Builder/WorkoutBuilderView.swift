import SwiftUI
import SwiftData

struct WorkoutBuilderView: View {
    @Query(sort: \CustomWorkoutModel.createdAt, order: .reverse) private var customs: [CustomWorkoutModel]
    @Environment(\.modelContext) private var modelContext

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var category: WorkoutCategory = .endurance
    @State private var intervals: [Interval] = []
    @State private var editingId: String? = nil
    @State private var showAlert = false
    @State private var alertMessage = ""

    private var previewWorkout: Workout? {
        guard !intervals.isEmpty else { return nil }
        return Workout(
            id: "preview",
            name: name.isEmpty ? "Preview" : name,
            description: description,
            category: category,
            intervals: intervals
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CJSpacing.l) {
                    metaSection
                    intervalsSection
                    if let preview = previewWorkout {
                        previewSection(preview)
                    }
                    saveButton
                    savedSection
                }
                .padding(CJSpacing.l)
            }
            .background(CJColors.bgPrimary.ignoresSafeArea())
            .navigationTitle("Builder")
            .toolbarBackground(CJColors.bgSecondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .alert(alertMessage, isPresented: $showAlert) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    private var metaSection: some View {
        VStack(alignment: .leading, spacing: CJSpacing.s) {
            Text(editingId != nil ? "Edit Workout" : "Create New Workout")
                .font(CJFont.title)
                .foregroundStyle(CJColors.textPrimary)

            field(label: "Name") {
                TextField("My Custom Workout", text: $name)
                    .textFieldStyle(.plain)
                    .padding(CJSpacing.s)
                    .background(CJColors.bgSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(CJColors.textPrimary)
            }
            field(label: "Description") {
                TextField("Description...", text: $description)
                    .textFieldStyle(.plain)
                    .padding(CJSpacing.s)
                    .background(CJColors.bgSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(CJColors.textPrimary)
            }
            field(label: "Category") {
                Picker("Category", selection: $category) {
                    ForEach(WorkoutCategory.allCases) { c in
                        Text(c.rawValue).tag(c)
                    }
                }
                .pickerStyle(.menu)
                .tint(CJColors.accent)
            }
        }
        .padding(CJSpacing.l)
        .background(CJColors.card)
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
    }

    @ViewBuilder
    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(CJFont.labelUpper)
                .foregroundStyle(CJColors.textSecondary)
            content()
        }
    }

    @ViewBuilder
    private var intervalsSection: some View {
        VStack(alignment: .leading, spacing: CJSpacing.s) {
            HStack {
                Text("Intervals")
                    .font(CJFont.title)
                    .foregroundStyle(CJColors.textPrimary)
                Spacer()
                Button {
                    intervals.append(.steady(
                        name: "Interval \(intervals.count + 1)",
                        duration: 300,
                        powerPercent: 75
                    ))
                } label: {
                    Label("Steady", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .tint(CJColors.accent)

                Button {
                    intervals.append(.ramp(
                        name: "Ramp \(intervals.count + 1)",
                        duration: 300,
                        startPercent: 50,
                        endPercent: 75
                    ))
                } label: {
                    Label("Ramp", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .tint(CJColors.accent)
            }

            if intervals.isEmpty {
                Text("No intervals yet. Add a steady or ramp block to begin.")
                    .font(CJFont.body)
                    .foregroundStyle(CJColors.textMuted)
                    .padding(CJSpacing.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CJColors.card.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
            } else {
                ForEach(Array(intervals.enumerated()), id: \.offset) { idx, _ in
                    IntervalEditorRow(
                        interval: $intervals[idx],
                        canMoveUp: idx > 0,
                        canMoveDown: idx < intervals.count - 1,
                        onMoveUp: {
                            intervals.swapAt(idx, idx - 1)
                        },
                        onMoveDown: {
                            intervals.swapAt(idx, idx + 1)
                        },
                        onDelete: {
                            intervals.remove(at: idx)
                        }
                    )
                }
            }
        }
    }

    private func previewSection(_ workout: Workout) -> some View {
        VStack(alignment: .leading, spacing: CJSpacing.s) {
            Text("Preview")
                .font(CJFont.title)
                .foregroundStyle(CJColors.textPrimary)

            MiniWorkoutGraphView(workout: workout)
                .frame(height: 80)

            Text("Total · \(TimeFormat.duration(workout.totalDuration))")
                .font(CJFont.caption)
                .foregroundStyle(CJColors.textMuted)
        }
        .padding(CJSpacing.l)
        .background(CJColors.card)
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
    }

    private var saveButton: some View {
        HStack {
            if editingId != nil {
                Button("Cancel Edit") { resetForm() }
                    .buttonStyle(.bordered)
                    .tint(CJColors.textSecondary)
            }
            Button {
                save()
            } label: {
                Text(editingId != nil ? "Update Workout" : "Save Workout")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(CJColors.accent)
        }
    }

    @ViewBuilder
    private var savedSection: some View {
        VStack(alignment: .leading, spacing: CJSpacing.s) {
            Text("Saved Custom Workouts")
                .font(CJFont.title)
                .foregroundStyle(CJColors.textPrimary)
            if customs.isEmpty {
                Text("No custom workouts yet.")
                    .font(CJFont.caption)
                    .foregroundStyle(CJColors.textMuted)
            } else {
                ForEach(customs, id: \.id) { c in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name)
                                .font(CJFont.bodyBold)
                                .foregroundStyle(CJColors.textPrimary)
                            Text("\(c.category) · \(c.intervals.count) intervals · \(TimeFormat.duration(c.intervals.reduce(0) { $0 + $1.duration }))")
                                .font(CJFont.caption)
                                .foregroundStyle(CJColors.textMuted)
                        }
                        Spacer()
                        Button("Edit") {
                            startEditing(c)
                        }
                        .buttonStyle(.bordered)
                        .tint(CJColors.accent)
                        Button(role: .destructive) {
                            modelContext.delete(c)
                            try? modelContext.save()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .tint(CJColors.danger)
                    }
                    .padding(CJSpacing.m)
                    .background(CJColors.card)
                    .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
                }
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            alertMessage = "Please enter a workout name."
            showAlert = true
            return
        }
        guard !intervals.isEmpty else {
            alertMessage = "Please add at least one interval."
            showAlert = true
            return
        }

        if let id = editingId, let existing = customs.first(where: { $0.id == id }) {
            existing.name = trimmed
            existing.workoutDescription = description
            existing.category = category.rawValue
            existing.intervalsJSON = try? JSONEncoder().encode(intervals)
        } else {
            let id = "custom_" + UUID().uuidString
            let model = CustomWorkoutModel(
                id: id,
                name: trimmed,
                description: description,
                category: category,
                intervals: intervals
            )
            modelContext.insert(model)
        }
        try? modelContext.save()
        resetForm()
    }

    private func startEditing(_ c: CustomWorkoutModel) {
        editingId = c.id
        name = c.name
        description = c.workoutDescription
        category = WorkoutCategory(rawValue: c.category) ?? .endurance
        intervals = c.intervals
    }

    private func resetForm() {
        editingId = nil
        name = ""
        description = ""
        category = .endurance
        intervals = []
    }
}

struct IntervalEditorRow: View {
    @Binding var interval: Interval
    let canMoveUp: Bool
    let canMoveDown: Bool
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onDelete: () -> Void

    @State private var draftName: String = ""
    @State private var draftMinutes: Double = 0
    @State private var draftPercent: Double = 0
    @State private var draftStart: Double = 0
    @State private var draftEnd: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: CJSpacing.s) {
            HStack {
                Text(typeBadge)
                    .font(CJFont.small)
                    .foregroundStyle(CJColors.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(CJColors.accent.opacity(0.15))
                    .clipShape(Capsule())
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .foregroundStyle(CJColors.textPrimary)
                Spacer()
                Button(action: onMoveUp) { Image(systemName: "arrow.up") }
                    .disabled(!canMoveUp)
                Button(action: onMoveDown) { Image(systemName: "arrow.down") }
                    .disabled(!canMoveDown)
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
            }

            HStack {
                VStack(alignment: .leading) {
                    Text("Duration (min)").font(CJFont.small).foregroundStyle(CJColors.textMuted)
                    TextField("min", value: $draftMinutes, format: .number)
                        .keyboardType(.decimalPad)
                        .padding(6)
                        .background(CJColors.bgSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(CJColors.textPrimary)
                }
                if case .steady = interval {
                    VStack(alignment: .leading) {
                        Text("Power (%FTP)").font(CJFont.small).foregroundStyle(CJColors.textMuted)
                        TextField("%", value: $draftPercent, format: .number)
                            .keyboardType(.numberPad)
                            .padding(6)
                            .background(CJColors.bgSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(CJColors.textPrimary)
                    }
                } else {
                    VStack(alignment: .leading) {
                        Text("Start %").font(CJFont.small).foregroundStyle(CJColors.textMuted)
                        TextField("%", value: $draftStart, format: .number)
                            .keyboardType(.numberPad)
                            .padding(6)
                            .background(CJColors.bgSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(CJColors.textPrimary)
                    }
                    VStack(alignment: .leading) {
                        Text("End %").font(CJFont.small).foregroundStyle(CJColors.textMuted)
                        TextField("%", value: $draftEnd, format: .number)
                            .keyboardType(.numberPad)
                            .padding(6)
                            .background(CJColors.bgSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(CJColors.textPrimary)
                    }
                }
            }
        }
        .padding(CJSpacing.m)
        .background(CJColors.card)
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
        .onAppear { syncDraftsFromInterval() }
        .onChange(of: draftName) { _, _ in commit() }
        .onChange(of: draftMinutes) { _, _ in commit() }
        .onChange(of: draftPercent) { _, _ in commit() }
        .onChange(of: draftStart) { _, _ in commit() }
        .onChange(of: draftEnd) { _, _ in commit() }
    }

    private var typeBadge: String {
        switch interval {
        case .steady: "STEADY"
        case .ramp: "RAMP"
        }
    }

    private func syncDraftsFromInterval() {
        switch interval {
        case .steady(let name, let dur, let pct):
            draftName = name
            draftMinutes = Double(dur) / 60
            draftPercent = pct
        case .ramp(let name, let dur, let s, let e):
            draftName = name
            draftMinutes = Double(dur) / 60
            draftStart = s
            draftEnd = e
        }
    }

    private func commit() {
        let dur = max(15, Int(draftMinutes * 60))
        switch interval {
        case .steady:
            interval = .steady(name: draftName, duration: dur, powerPercent: max(20, min(600, draftPercent)))
        case .ramp:
            interval = .ramp(
                name: draftName,
                duration: dur,
                startPercent: max(20, min(600, draftStart)),
                endPercent: max(20, min(600, draftEnd))
            )
        }
    }
}
