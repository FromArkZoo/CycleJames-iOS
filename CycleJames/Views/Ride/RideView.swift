import SwiftUI
import SwiftData

struct RideView: View {
    @EnvironmentObject private var ride: RideController
    @EnvironmentObject private var trainer: FTMSManager
    @EnvironmentObject private var hr: HRManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showStopOverlay = false
    @State private var showCompleteOverlay = false
    @State private var showAddIntervalSheet = false
    @State private var showUpcomingSheet = false
    @State private var showConnectSheet = false
    @State private var savedSession: RideSessionModel?

    private var ftp: Int { AppSettings.ftp }
    private var canEditLive: Bool { ride.state == .riding || ride.state == .paused }
    private var showDisconnectBanner: Bool {
        canEditLive && trainer.connectionState != .connected
    }
    private var showConnectRow: Bool {
        // Only show inline connect buttons before/at countdown — once riding,
        // the disconnect banner takes over for the trainer; HR is optional.
        guard ride.state == .ready || ride.state == .countdown else { return false }
        return trainer.connectionState != .connected || hr.connectionState != .connected
    }

    private var isRideActive: Bool {
        ride.state == .riding || ride.state == .paused || ride.state == .countdown
    }

    private var hideNavBarInLandscape: Visibility {
        verticalSizeClass == .compact && isRideActive ? .hidden : .automatic
    }

    var body: some View {
        ZStack {
            CJColors.bgPrimary.ignoresSafeArea()

            if verticalSizeClass == .compact {
                landscapeContent
            } else {
                portraitContent
            }
        }
        .navigationTitle(ride.selectedWorkout?.name ?? "Ride")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(CJColors.bgSecondary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar(hideNavBarInLandscape, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            ControlsBar(onStart: handleStart, onStop: handleStopRequested)
        }
        .overlay {
            if ride.state == .countdown {
                CountdownOverlay(number: ride.countdownNumber)
            }
        }
        .overlay {
            if showStopOverlay {
                StopConfirmOverlay(
                    onSave: handleSaveAndStop,
                    onDiscard: handleDiscardAndStop,
                    onCancel: { showStopOverlay = false }
                )
            }
        }
        .overlay {
            if ride.state == .completed && showCompleteOverlay,
               let session = savedSession {
                CompleteSummaryOverlay(session: session) {
                    showCompleteOverlay = false
                    ride.dismissCompletion()
                    dismiss()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    if ride.state == .ready {
                        ride.deselect()
                        dismiss()
                    } else {
                        handleStopRequested()
                    }
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                }
                .tint(CJColors.accent)
            }
            ToolbarItem(placement: .topBarTrailing) {
                connectionStatusIndicator
            }
        }
        .onAppear {
            OrientationLock.shared.lock(.allButUpsideDown)
        }
        .onDisappear {
            OrientationLock.shared.lock(.portrait)
        }
        .onChange(of: ride.state) { _, new in
            if new == .completed && !showCompleteOverlay {
                // Workout finished naturally — persist and show summary.
                if savedSession == nil {
                    savedSession = ride.savedSessionAndDismiss(context: modelContext)
                }
                showCompleteOverlay = true
            }
        }
        .sheet(isPresented: $showAddIntervalSheet) {
            if let workout = ride.selectedWorkout {
                AddIntervalSheet(
                    ftp: ftp,
                    workout: workout,
                    currentIntervalIndex: ride.currentIntervalContext?.index ?? -1
                ) { interval, insertIndex in
                    ride.insertInterval(interval, atIndex: insertIndex)
                }
            }
        }
        .sheet(isPresented: $showConnectSheet) {
            ConnectDevicesSheet(trainer: trainer, hr: hr)
        }
        .sheet(isPresented: $showUpcomingSheet) {
            UpcomingIntervalsSheet()
                .environmentObject(ride)
        }
    }

    @ViewBuilder
    private var portraitContent: some View {
        VStack(spacing: CJSpacing.s) {
            if showDisconnectBanner {
                disconnectBanner
                    .padding(.horizontal, CJSpacing.l)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if showConnectRow {
                connectRow
                    .padding(.horizontal, CJSpacing.l)
            }

            if let workout = ride.selectedWorkout {
                WorkoutGraphView(
                    workout: workout,
                    ftp: ftp,
                    elapsed: ride.elapsed,
                    showWatts: false,
                    showFTPLine: true,
                    showElapsedMarker: true,
                    showAxisLabels: false,
                    compact: true
                )
                .frame(height: 130)
                .padding(.horizontal, CJSpacing.l)
            }

            if canEditLive {
                IntervalEditBar(
                    onShowUpcoming: { showUpcomingSheet = true },
                    onShowAddInterval: { showAddIntervalSheet = true }
                )
                .padding(.horizontal, CJSpacing.l)
            }

            MetricsGrid()
                .padding(.bottom, CJSpacing.s)
        }
        .animation(.easeInOut(duration: 0.2), value: showDisconnectBanner)
    }

    @ViewBuilder
    private var landscapeContent: some View {
        VStack(spacing: CJSpacing.s) {
            if showDisconnectBanner {
                disconnectBanner
                    .padding(.horizontal, CJSpacing.l)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            LandscapeRideLayout(
                onShowUpcoming: { showUpcomingSheet = true },
                onShowAddInterval: { showAddIntervalSheet = true }
            )
        }
        .animation(.easeInOut(duration: 0.2), value: showDisconnectBanner)
    }

    @ViewBuilder
    private var connectRow: some View {
        Button {
            showConnectSheet = true
        } label: {
            HStack(spacing: CJSpacing.s) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .semibold))
                Text("Connect Devices")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                deviceStatusDot(connected: trainer.connectionState == .connected, label: "Trainer", icon: "bolt.horizontal.fill")
                deviceStatusDot(connected: hr.connectionState == .connected, label: "HR", icon: "heart.fill")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, CJSpacing.m)
            .padding(.vertical, CJSpacing.s)
            .background(CJColors.accent)
            .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func deviceStatusDot(connected: Bool, label: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Image(systemName: connected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11))
                .opacity(connected ? 1.0 : 0.5)
        }
        .foregroundStyle(.white)
        .accessibilityLabel("\(label) \(connected ? "connected" : "not connected")")
    }

    @ViewBuilder
    private var connectionStatusIndicator: some View {
        let trainerOK = trainer.connectionState == .connected
        let hrOK = hr.connectionState == .connected
        HStack(spacing: 6) {
            statusPill(connected: trainerOK, icon: "bolt.horizontal.fill")
            statusPill(connected: hrOK, icon: "heart.fill")
        }
    }

    @ViewBuilder
    private func statusPill(connected: Bool, icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(connected ? CJColors.success : CJColors.textMuted)
    }

    @ViewBuilder
    private var disconnectBanner: some View {
        let isReconnecting = trainer.connectionState == .connecting || trainer.connectionState == .scanning
        HStack(spacing: CJSpacing.s) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(CJColors.warning)
            VStack(alignment: .leading, spacing: 1) {
                Text(isReconnecting ? "Reconnecting trainer…" : "Trainer disconnected")
                    .font(CJFont.bodyBold)
                    .foregroundStyle(CJColors.textPrimary)
                Text("Ride keeps recording. Power targets resume on reconnect.")
                    .font(.system(size: 11))
                    .foregroundStyle(CJColors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: CJSpacing.s)
            if isReconnecting {
                ProgressView().controlSize(.small).tint(CJColors.accent)
            } else {
                Button {
                    ride.reconnectTrainer()
                } label: {
                    Text("Reconnect")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, CJSpacing.s)
                        .frame(height: 30)
                        .foregroundStyle(.white)
                        .background(CJColors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, CJSpacing.s)
        .padding(.vertical, 8)
        .background(CJColors.warning.opacity(0.12))
        .overlay(RoundedRectangle(cornerRadius: CJRadius.medium).stroke(CJColors.warning.opacity(0.4), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
    }

    private func handleStart() {
        Task { await ride.startRide() }
    }

    private func handleStopRequested() {
        ride.requestStop()
        showStopOverlay = true
    }

    private func handleSaveAndStop() {
        showStopOverlay = false
        savedSession = ride.saveAndStop(context: modelContext)
        showCompleteOverlay = true
    }

    private func handleDiscardAndStop() {
        showStopOverlay = false
        ride.discardAndStop()
        dismiss()
    }
}

struct AddIntervalSheet: View {
    @Environment(\.dismiss) private var dismiss
    let ftp: Int
    let workout: Workout
    /// Index of the interval currently playing (-1 if no ride yet).
    let currentIntervalIndex: Int
    var onAdd: (Interval, Int) -> Void

    @State private var minutes: Int = 5
    @State private var seconds: Int = 0
    @State private var powerPercent: Int = 65
    @State private var insertIndex: Int = -1  // sentinel -1 → "after current"

    private var watts: Int { Int((Double(powerPercent) / 100.0 * Double(ftp)).rounded()) }
    private var zone: Zone { Zones.zone(forPercent: Double(powerPercent)) }
    private var totalSeconds: Int { max(15, minutes * 60 + seconds) }
    private var totalLabel: String {
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        return s > 0 ? "\(m)m \(s)s" : "\(m) min"
    }

    /// All valid insertion points the user can pick from. Position 0 means
    /// "before interval 0", position N means "at the end". We skip any
    /// position that would land in the past (≤ current interval).
    private var positions: [(label: String, index: Int)] {
        var out: [(String, Int)] = []
        let firstFuture = max(currentIntervalIndex + 1, 0)
        // Default convenience option.
        if currentIntervalIndex >= 0,
           workout.intervals.indices.contains(currentIntervalIndex) {
            out.append(("After current (\(workout.intervals[currentIntervalIndex].name))", firstFuture))
        }
        // Before each remaining interval.
        for i in firstFuture..<workout.intervals.count {
            out.append(("Before \(workout.intervals[i].name)", i))
        }
        // End of workout.
        out.append(("End of workout", workout.intervals.count))
        return out
    }

    private var resolvedIndex: Int {
        insertIndex == -1 ? (positions.first?.index ?? workout.intervals.count) : insertIndex
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
                            Text("Target")
                            Spacer()
                            Text("\(powerPercent)% · \(watts)W")
                                .foregroundStyle(CJColors.textSecondary)
                                .monospacedDigit()
                        }
                    }
                    HStack(spacing: 6) {
                        Circle().fill(zone.color).frame(width: 8, height: 8)
                        Text("Zone: \(zone.name)")
                            .foregroundStyle(zone.color)
                            .font(CJFont.caption)
                    }
                }

                Section("When to insert") {
                    Picker("Position", selection: $insertIndex) {
                        ForEach(Array(positions.enumerated()), id: \.offset) { _, p in
                            Text(p.label).tag(p.index)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle("Add Interval")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let interval = Interval.steady(
                            name: "Custom",
                            duration: totalSeconds,
                            powerPercent: Double(powerPercent)
                        )
                        onAdd(interval, resolvedIndex)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                if insertIndex == -1, let first = positions.first {
                    insertIndex = first.index
                }
            }
        }
        .presentationDetents([.large])
    }
}
