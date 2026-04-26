import SwiftUI
import SwiftData

struct RideView: View {
    @EnvironmentObject private var ride: RideController
    @EnvironmentObject private var trainer: FTMSManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showStopOverlay = false
    @State private var showCompleteOverlay = false
    @State private var savedSession: RideSessionModel?

    private var ftp: Int { AppSettings.ftp }

    var body: some View {
        ZStack {
            CJColors.bgPrimary.ignoresSafeArea()

            VStack(spacing: CJSpacing.s) {
                header

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

                ScrollView { MetricsGrid().padding(.bottom, 100) }
            }

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
