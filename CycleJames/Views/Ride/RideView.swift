import SwiftUI
import SwiftData

struct RideView: View {
    @EnvironmentObject private var ride: RideController
    @EnvironmentObject private var trainer: FTMSManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showStopOverlay = false
    @State private var showCompleteOverlay = false
    @State private var showAddIntervalSheet = false
    @State private var savedSession: RideSessionModel?

    private var ftp: Int { AppSettings.ftp }
    private var canEditLive: Bool { ride.state == .riding || ride.state == .paused }
    private var showDisconnectBanner: Bool {
        canEditLive && trainer.connectionState != .connected
    }

    var body: some View {
        ZStack {
            CJColors.bgPrimary.ignoresSafeArea()

            VStack(spacing: CJSpacing.s) {
                header

                if showDisconnectBanner {
                    disconnectBanner
                        .padding(.horizontal, CJSpacing.l)
                        .transition(.move(edge: .top).combined(with: .opacity))
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
                    intervalEditBar
                        .padding(.horizontal, CJSpacing.l)
                }

                ScrollView { MetricsGrid().padding(.bottom, 100) }
            }
            .animation(.easeInOut(duration: 0.2), value: showDisconnectBanner)

            if ride.state == .countdown {
                CountdownOverlay(number: ride.countdownNumber)
            }

            if showStopOverlay {
                StopConfirmOverlay(
                    onSave: handleSaveAndStop,
                    onDiscard: handleDiscardAndStop,
                    onCancel: { showStopOverlay = false }
                )
            }

            if ride.state == .completed && showCompleteOverlay {
                if let session = savedSession {
                    CompleteSummaryOverlay(session: session) {
                        showCompleteOverlay = false
                        ride.dismissCompletion()
                        dismiss()
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .safeAreaInset(edge: .bottom) {
            ControlsBar(onStart: handleStart, onStop: handleStopRequested)
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
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .tint(CJColors.accent)
            }
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
            AddIntervalSheet(ftp: ftp) { interval in
                ride.insertIntervalAfterCurrent(interval)
            }
        }
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

    @ViewBuilder
    private var intervalEditBar: some View {
        let ctx = ride.currentIntervalContext
        HStack(spacing: CJSpacing.s) {
            VStack(alignment: .leading, spacing: 0) {
                Text(ctx?.interval.name ?? "Current interval")
                    .font(CJFont.small)
                    .foregroundStyle(CJColors.textSecondary)
                    .lineLimit(1)
                Text("\(ride.currentTarget)W target")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(CJColors.accent)
                    .monospacedDigit()
            }
            Spacer(minLength: CJSpacing.s)
            adjustButton(systemName: "minus", enabled: ctx != nil) {
                ride.adjustCurrentInterval(byWatts: -5)
            }
            adjustButton(systemName: "plus", enabled: ctx != nil) {
                ride.adjustCurrentInterval(byWatts: 5)
            }
            Button {
                showAddIntervalSheet = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.rectangle.on.rectangle")
                    Text("Add")
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, CJSpacing.s)
                .frame(height: 32)
                .foregroundStyle(.white)
                .background(CJColors.card)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(CJColors.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, CJSpacing.s)
        .padding(.vertical, 6)
        .background(CJColors.bgSecondary.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
    }

    @ViewBuilder
    private func adjustButton(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 32, height: 32)
                .foregroundStyle(.white)
                .background(CJColors.card)
                .clipShape(Circle())
                .opacity(enabled ? 1.0 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(ride.selectedWorkout?.name ?? "")
                    .font(CJFont.title)
                    .foregroundStyle(CJColors.textPrimary)
                Spacer()
                Circle()
                    .fill(trainer.connectionState == .connected ? CJColors.success : CJColors.textMuted)
                    .frame(width: 10, height: 10)
                Text(trainer.connectionState == .connected ? "Trainer" : "No trainer")
                    .font(CJFont.caption)
                    .foregroundStyle(CJColors.textSecondary)
            }
            Text(ride.selectedWorkout?.category.rawValue ?? "")
                .font(CJFont.caption)
                .foregroundStyle(CJColors.textMuted)
        }
        .padding(.horizontal, CJSpacing.l)
        .padding(.top, CJSpacing.s)
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
    var onAdd: (Interval) -> Void

    @State private var minutes: Int = 5
    @State private var powerPercent: Int = 65

    private var watts: Int { Int((Double(powerPercent) / 100.0 * Double(ftp)).rounded()) }
    private var zone: Zone { Zones.zone(forPercent: Double(powerPercent)) }
    private var durationLabel: String { minutes == 1 ? "1 min" : "\(minutes) min" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $minutes, in: 1...60) {
                        HStack {
                            Text("Duration")
                            Spacer()
                            Text(durationLabel)
                                .foregroundStyle(CJColors.textSecondary)
                                .monospacedDigit()
                        }
                    }
                    Stepper(value: $powerPercent, in: 5...600, step: 5) {
                        HStack {
                            Text("Power")
                            Spacer()
                            Text("\(powerPercent)% · \(watts)W")
                                .foregroundStyle(CJColors.textSecondary)
                                .monospacedDigit()
                        }
                    }
                } footer: {
                    HStack(spacing: 6) {
                        Circle().fill(zone.color).frame(width: 8, height: 8)
                        Text("Zone: \(zone.name)")
                            .foregroundStyle(zone.color)
                    }
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
                            duration: minutes * 60,
                            powerPercent: Double(powerPercent)
                        )
                        onAdd(interval)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
