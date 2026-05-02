import SwiftUI

/// Mid-ride queue editor: lists every interval still ahead of the user, lets
/// them edit the watts/duration, delete it, or jump to it. Edit and Jump are
/// rendered as separate icon buttons with explicit confirmation on Jump so
/// you can't accidentally fast-forward through a workout when you meant to
/// tweak watts.
struct UpcomingIntervalsSheet: View {
    @EnvironmentObject private var ride: RideController
    @Environment(\.dismiss) private var dismiss

    @State private var editingIndex: Int?
    @State private var jumpConfirmIndex: Int?

    private var ftp: Int { AppSettings.ftp }

    private var workout: Workout? { ride.selectedWorkout }

    /// First future interval — anything at or before the current index is
    /// in the past and not editable.
    private var firstFutureIndex: Int {
        max((ride.currentIntervalContext?.index ?? -1) + 1, 0)
    }

    /// secondsFromNow[i] = wall-clock seconds from "now" until interval i
    /// begins. Used by the jump-confirm alert to tell the user how much
    /// training they're skipping.
    private var startsFromNow: [Int] {
        guard let workout else { return [] }
        var per: [Int] = []
        per.reserveCapacity(workout.intervals.count)
        var startAbs = 0
        for iv in workout.intervals {
            per.append(max(0, startAbs - ride.elapsed))
            startAbs += iv.duration
        }
        return per
    }

    var body: some View {
        NavigationStack {
            Group {
                if let workout, workout.intervals.indices.contains(firstFutureIndex) {
                    list(workout: workout)
                } else {
                    empty
                }
            }
            .background(CJColors.bgPrimary.ignoresSafeArea())
            .navigationTitle("Upcoming Intervals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: Binding(
                get: { editingIndex.map { IntIdentifier(value: $0) } },
                set: { editingIndex = $0?.value }
            )) { wrapper in
                if let workout, workout.intervals.indices.contains(wrapper.value) {
                    EditIntervalSheet(
                        ftp: ftp,
                        index: wrapper.value,
                        existing: workout.intervals[wrapper.value]
                    ) { updated in
                        ride.replaceInterval(at: wrapper.value, with: updated)
                    } onDelete: {
                        ride.deleteInterval(at: wrapper.value)
                    }
                }
            }
            .alert(
                "Skip to this interval?",
                isPresented: Binding(
                    get: { jumpConfirmIndex != nil },
                    set: { if !$0 { jumpConfirmIndex = nil } }
                ),
                presenting: jumpConfirmIndex
            ) { idx in
                Button("Skip", role: .destructive) {
                    ride.jumpToInterval(at: idx)
                    jumpConfirmIndex = nil
                    dismiss()
                }
                Button("Cancel", role: .cancel) { jumpConfirmIndex = nil }
            } message: { idx in
                if let workout, workout.intervals.indices.contains(idx) {
                    let iv = workout.intervals[idx]
                    let skip = max(0, startsFromNow[idx])
                    Text("Jump to \(iv.name). You'll skip \(TimeFormat.mmss(skip)) of training.")
                }
            }
        }
    }

    @ViewBuilder
    private var empty: some View {
        VStack(spacing: CJSpacing.s) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(CJColors.textMuted)
            Text("No upcoming intervals")
                .font(CJFont.body)
                .foregroundStyle(CJColors.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func list(workout: Workout) -> some View {
        ScrollView {
            LazyVStack(spacing: CJSpacing.s) {
                ForEach(firstFutureIndex..<workout.intervals.count, id: \.self) { i in
                    row(workout: workout, index: i)
                }
            }
            .padding(CJSpacing.l)
        }
    }

    @ViewBuilder
    private func row(workout: Workout, index i: Int) -> some View {
        let iv = workout.intervals[i]
        let mid = iv.midPercent
        let zone = Zones.zone(forPercent: mid)
        let watts = wattsLabel(for: iv)

        HStack(spacing: CJSpacing.s) {
            // Zone bar on the leading edge.
            Rectangle()
                .fill(zone.color)
                .frame(width: 4)
                .clipShape(RoundedRectangle(cornerRadius: 2))

            VStack(alignment: .leading, spacing: 2) {
                Text(iv.name)
                    .font(CJFont.bodyBold)
                    .foregroundStyle(CJColors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(zone.name)
                        .font(CJFont.small)
                        .foregroundStyle(zone.color)
                    Text("·").foregroundStyle(CJColors.textMuted)
                    Text(durationLabel(for: iv))
                        .font(CJFont.small)
                        .foregroundStyle(CJColors.textSecondary)
                        .monospacedDigit()
                    Text("·").foregroundStyle(CJColors.textMuted)
                    Text(watts)
                        .font(CJFont.small)
                        .foregroundStyle(CJColors.textSecondary)
                        .monospacedDigit()
                }
            }
            Spacer()

            Button {
                editingIndex = i
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(CJColors.textPrimary)
                    .background(CJColors.bgSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit interval \(iv.name)")

            Button {
                jumpConfirmIndex = i
            } label: {
                Image(systemName: "forward.end")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(.white)
                    .background(CJColors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip ahead to \(iv.name)")
        }
        .padding(CJSpacing.s)
        .background(CJColors.card)
        .overlay(
            RoundedRectangle(cornerRadius: CJRadius.medium)
                .stroke(CJColors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
    }

    private func wattsLabel(for iv: Interval) -> String {
        switch iv {
        case .steady(_, _, let p):
            let w = Int((p / 100.0 * Double(ftp)).rounded())
            return "\(w)W"
        case .ramp(_, _, let s, let e):
            let sw = Int((s / 100.0 * Double(ftp)).rounded())
            let ew = Int((e / 100.0 * Double(ftp)).rounded())
            return "\(sw)→\(ew)W"
        }
    }

    private func durationLabel(for iv: Interval) -> String {
        let m = iv.duration / 60
        let s = iv.duration % 60
        return s > 0 ? "\(m)m\(s)s" : "\(m)min"
    }
}

private struct IntIdentifier: Identifiable {
    let value: Int
    var id: Int { value }
}

/// Per-interval editor — lets the user tweak duration & watts of a single
/// upcoming interval, or delete it. Ramps remain ramps; we adjust both ends
/// by the same percentage delta so the slope is preserved.
struct EditIntervalSheet: View {
    @Environment(\.dismiss) private var dismiss
    let ftp: Int
    let index: Int
    let existing: Interval
    var onSave: (Interval) -> Void
    var onDelete: () -> Void

    @State private var minutes: Int
    @State private var seconds: Int
    @State private var powerPercent: Int     // for steady; or midpoint for ramp

    init(ftp: Int, index: Int, existing: Interval, onSave: @escaping (Interval) -> Void, onDelete: @escaping () -> Void) {
        self.ftp = ftp
        self.index = index
        self.existing = existing
        self.onSave = onSave
        self.onDelete = onDelete
        _minutes = State(initialValue: existing.duration / 60)
        _seconds = State(initialValue: existing.duration % 60)
        switch existing {
        case .steady(_, _, let p):
            _powerPercent = State(initialValue: Int(p.rounded()))
        case .ramp(_, _, let s, let e):
            _powerPercent = State(initialValue: Int(((s + e) / 2).rounded()))
        }
    }

    private var watts: Int { Int((Double(powerPercent) / 100.0 * Double(ftp)).rounded()) }
    private var zone: Zone { Zones.zone(forPercent: Double(powerPercent)) }

    private var totalSeconds: Int { max(15, minutes * 60 + seconds) }

    private var totalLabel: String {
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        return s > 0 ? "\(m)m \(s)s" : "\(m) min"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Duration") {
                    Stepper(value: $minutes, in: 0...180) {
                        HStack {
                            Text("Minutes"); Spacer()
                            Text("\(minutes)").foregroundStyle(CJColors.textSecondary).monospacedDigit()
                        }
                    }
                    Stepper(value: $seconds, in: 0...59, step: 5) {
                        HStack {
                            Text("Seconds"); Spacer()
                            Text("\(seconds)").foregroundStyle(CJColors.textSecondary).monospacedDigit()
                        }
                    }
                    HStack(spacing: 8) {
                        Text("Quick add")
                            .foregroundStyle(CJColors.textSecondary)
                        Spacer()
                        ForEach([5, 10, 30], id: \.self) { delta in
                            Button("+\(delta)m") {
                                minutes = min(180, minutes + delta)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(CJColors.accent)
                        }
                    }
                    HStack {
                        Text("Total")
                            .foregroundStyle(CJColors.textSecondary)
                        Spacer()
                        Text(totalLabel)
                            .foregroundStyle(CJColors.textPrimary)
                            .monospacedDigit()
                    }
                }

                Section("Power") {
                    Stepper(value: $powerPercent, in: 5...600, step: 5) {
                        HStack {
                            Text("Target"); Spacer()
                            Text("\(powerPercent)% · \(watts)W")
                                .foregroundStyle(CJColors.textSecondary).monospacedDigit()
                        }
                    }
                    HStack(spacing: 6) {
                        Circle().fill(zone.color).frame(width: 8, height: 8)
                        Text("Zone: \(zone.name)")
                            .foregroundStyle(zone.color)
                            .font(CJFont.caption)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        onDelete()
                        dismiss()
                    } label: {
                        Label("Delete this interval", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Edit \(existing.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.fontWeight(.semibold)
                }
            }
        }
    }

    private func save() {
        let updated: Interval
        switch existing {
        case .steady(let n, _, _):
            updated = .steady(name: n, duration: totalSeconds, powerPercent: Double(powerPercent))
        case .ramp(let n, _, let s, let e):
            // Preserve slope, just shift mid to match new powerPercent.
            let oldMid = (s + e) / 2
            let delta = Double(powerPercent) - oldMid
            updated = .ramp(
                name: n,
                duration: totalSeconds,
                startPercent: max(5, min(600, s + delta)),
                endPercent: max(5, min(600, e + delta))
            )
        }
        onSave(updated)
        dismiss()
    }
}
