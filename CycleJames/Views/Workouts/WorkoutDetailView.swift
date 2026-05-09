import SwiftUI
import SwiftData

struct WorkoutDetailView: View {
    let workout: Workout
    @EnvironmentObject private var ride: RideController
    @EnvironmentObject private var trainer: FTMSManager
    @Environment(\.modelContext) private var modelContext
    @State private var goToRide = false
    @State private var edited: Workout
    @State private var showSaveAsCustomSheet = false
    @State private var showScheduleSheet = false

    init(workout: Workout) {
        self.workout = workout
        self._edited = State(initialValue: workout)
    }

    private var ftp: Int { AppSettings.ftp }
    private var hasEdits: Bool { edited.intervals != workout.intervals }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CJSpacing.l) {
                VStack(alignment: .leading, spacing: CJSpacing.xs) {
                    Text(workout.category.rawValue.uppercased())
                        .font(CJFont.labelUpper)
                        .foregroundStyle(CJColors.accent)
                    Text(workout.name)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(CJColors.textPrimary)
                    Text(workout.description)
                        .font(CJFont.body)
                        .foregroundStyle(CJColors.textSecondary)
                    Text("Duration · \(TimeFormat.duration(workout.totalDuration))")
                        .font(CJFont.caption)
                        .foregroundStyle(CJColors.textMuted)
                        .padding(.top, 2)
                }

                WorkoutGraphView(
                    workout: edited,
                    ftp: ftp,
                    elapsed: 0,
                    showWatts: true,
                    onIntervalEdit: { idx, deltaW in
                        edited = edited.adjustingInterval(at: idx, byWatts: deltaW, ftp: ftp)
                    }
                )
                .frame(height: 220)
                .background(Color.black.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))

                Text("Hold a bar and drag to fine-tune that interval.")
                    .font(CJFont.caption)
                    .foregroundStyle(CJColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)

                adjustBar

                if hasEdits {
                    Button {
                        showSaveAsCustomSheet = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down")
                            Text("Save as custom workout")
                        }
                        .font(CJFont.body)
                        .foregroundStyle(CJColors.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, CJSpacing.s)
                        .overlay(
                            RoundedRectangle(cornerRadius: CJRadius.medium)
                                .stroke(CJColors.accent.opacity(0.5), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }

                IntervalListView(workout: edited, ftp: ftp)
            }
            .padding(.horizontal, CJSpacing.l)
            .padding(.bottom, 120)
        }
        .background(CJColors.bgPrimary.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showScheduleSheet = true
                } label: {
                    Image(systemName: "calendar.badge.plus")
                        .foregroundStyle(CJColors.accent)
                }
                .accessibilityLabel("Schedule for later")
            }
        }
        .safeAreaInset(edge: .bottom) {
            startButton
                .padding(CJSpacing.l)
                .background(CJColors.bgPrimary.opacity(0.95))
        }
        .navigationDestination(isPresented: $goToRide) {
            RideView()
                .navigationBarBackButtonHidden(true)
        }
        .sheet(isPresented: $showSaveAsCustomSheet) {
            SaveAsCustomSheet(source: workout, edited: edited) { name, description in
                saveAsCustom(name: name, description: description)
            }
        }
        .sheet(isPresented: $showScheduleSheet) {
            ScheduleForLaterSheet(workout: workout) { pickedDate in
                schedule(on: pickedDate)
            }
        }
    }

    private func schedule(on date: Date) {
        let dayStart = Calendar(identifier: .gregorian).startOfDay(for: date)
        let model = ScheduledRideModel(
            workoutId: workout.id,
            workoutName: workout.name,
            category: workout.category.rawValue,
            date: dayStart
        )
        modelContext.insert(model)
        try? modelContext.save()
    }

    private func saveAsCustom(name: String, description: String) {
        let model = CustomWorkoutModel(
            id: "custom_\(UUID().uuidString)",
            name: name,
            description: description,
            category: edited.category,
            intervals: edited.intervals
        )
        modelContext.insert(model)
        try? modelContext.save()
    }

    @ViewBuilder
    private var adjustBar: some View {
        HStack(spacing: CJSpacing.s) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Overall power")
                    .font(CJFont.small)
                    .foregroundStyle(CJColors.textSecondary)
                Text(hasEdits ? "Edited" : "5W steps")
                    .font(.system(size: 10))
                    .foregroundStyle(hasEdits ? CJColors.accent : CJColors.textMuted)
            }
            Spacer()
            if hasEdits {
                Button {
                    edited = workout
                } label: {
                    Text("Reset")
                        .font(CJFont.small)
                        .padding(.horizontal, CJSpacing.s)
                        .padding(.vertical, 6)
                        .foregroundStyle(CJColors.accent)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(CJColors.accent.opacity(0.5), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            adjustButton(systemName: "minus") {
                edited = edited.adjustingAllIntervals(byWatts: -5, ftp: ftp)
            }
            adjustButton(systemName: "plus") {
                edited = edited.adjustingAllIntervals(byWatts: 5, ftp: ftp)
            }
        }
        .padding(.horizontal, CJSpacing.s)
        .padding(.vertical, 8)
        .background(CJColors.bgSecondary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
    }

    @ViewBuilder
    private func adjustButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 36, height: 36)
                .foregroundStyle(.white)
                .background(CJColors.card)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: edited.intervals)
    }

    @ViewBuilder
    private var startButton: some View {
        Button {
            ride.select(edited)
            goToRide = true
        } label: {
            Text("START WORKOUT")
                .font(.system(size: 17, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, CJSpacing.l)
                .foregroundStyle(.white)
                .background(trainer.connectionState == .connected ? CJColors.accent : CJColors.accentDim)
                .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
        }
        .buttonStyle(.plain)
    }
}

struct IntervalListView: View {
    let workout: Workout
    let ftp: Int

    var body: some View {
        VStack(alignment: .leading, spacing: CJSpacing.xs) {
            Text("Intervals")
                .font(CJFont.title)
                .foregroundStyle(CJColors.textPrimary)
            ForEach(Array(workout.intervals.enumerated()), id: \.offset) { _, iv in
                row(iv)
            }
        }
    }

    @ViewBuilder
    private func row(_ iv: Interval) -> some View {
        let mid = iv.midPercent
        let zone = Zones.zone(forPercent: mid)
        let durationStr: String = {
            let m = iv.duration / 60
            let s = iv.duration % 60
            return s > 0 ? "\(m)m \(s)s" : "\(m)min"
        }()
        let watts: String = {
            switch iv {
            case .steady(_, _, let p):
                let w = Int((p / 100.0 * Double(ftp)).rounded())
                return "\(w)W (\(Int(p))%)"
            case .ramp(_, _, let s, let e):
                let sw = Int((s / 100.0 * Double(ftp)).rounded())
                let ew = Int((e / 100.0 * Double(ftp)).rounded())
                return "\(sw)→\(ew)W (\(Int(s))–\(Int(e))%)"
            }
        }()

        HStack(spacing: CJSpacing.s) {
            Text(zone.name)
                .font(CJFont.small)
                .padding(.horizontal, CJSpacing.s)
                .padding(.vertical, 3)
                .foregroundStyle(zone.color)
                .background(zone.color.opacity(0.15))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(zone.color, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(iv.name)
                .font(CJFont.body)
                .foregroundStyle(CJColors.textPrimary)
            Spacer()
            Text(watts)
                .font(CJFont.caption)
                .foregroundStyle(CJColors.textSecondary)
                .monospacedDigit()
            Text(durationStr)
                .font(CJFont.caption)
                .foregroundStyle(CJColors.textMuted)
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, CJSpacing.s)
        .background(CJColors.bgSecondary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Sheet shown after the user has tweaked a built-in workout and wants to
/// keep their adjustments. Saves a CustomWorkoutModel record so the
/// modified profile shows up in the Workouts tab from then on.
struct SaveAsCustomSheet: View {
    @Environment(\.dismiss) private var dismiss
    let source: Workout
    let edited: Workout
    var onSave: (String, String) -> Void

    @State private var name: String
    @State private var note: String

    init(source: Workout, edited: Workout, onSave: @escaping (String, String) -> Void) {
        self.source = source
        self.edited = edited
        self.onSave = onSave
        _name = State(initialValue: "\(source.name) (custom)")
        _note = State(initialValue: source.description)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Workout name", text: $name)
                        .textFieldStyle(.plain)
                }
                Section("Description") {
                    TextField("Description", text: $note, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(2...4)
                }
                Section {
                    HStack {
                        Text("Intervals")
                        Spacer()
                        Text("\(edited.intervals.count)").foregroundStyle(CJColors.textSecondary)
                    }
                    HStack {
                        Text("Duration")
                        Spacer()
                        Text(TimeFormat.duration(edited.totalDuration))
                            .foregroundStyle(CJColors.textSecondary)
                    }
                    HStack {
                        Text("Category")
                        Spacer()
                        Text(edited.category.rawValue).foregroundStyle(CJColors.textSecondary)
                    }
                } footer: {
                    Text("Saves your edited intervals as a new custom workout. The original built-in workout is unchanged.")
                }
            }
            .navigationTitle("Save As Custom")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        onSave(trimmed, note)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
