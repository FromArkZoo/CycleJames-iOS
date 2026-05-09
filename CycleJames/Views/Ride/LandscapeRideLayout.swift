import SwiftUI

/// Stripped-down Ride layout for iPhone landscape (e.g. when the phone is in
/// a landscape bike mount). Top row of pills (interval / power / HR / elapsed),
/// the workout graph in the middle, and the interval edit bar at the bottom.
struct LandscapeRideLayout: View {
    @EnvironmentObject private var ride: RideController
    var onShowUpcoming: () -> Void
    var onShowAddInterval: () -> Void

    private var ftp: Int { AppSettings.ftp }
    private var canEditLive: Bool { ride.state == .riding || ride.state == .paused }

    var body: some View {
        VStack(spacing: CJSpacing.s) {
            pillsRow
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
                .frame(maxHeight: .infinity)
            }
            if canEditLive {
                IntervalEditBar(
                    onShowUpcoming: onShowUpcoming,
                    onShowAddInterval: onShowAddInterval
                )
            }
        }
        .padding(.horizontal, CJSpacing.m)
        .padding(.top, CJSpacing.xs)
    }

    private var pillsRow: some View {
        HStack(spacing: CJSpacing.s) {
            IntervalPill()
            MetricCard(
                label: "Power",
                value: valueOrDash(ride.rolling3sPower),
                unit: "W",
                emphasis: true,
                tint: ride.rolling3sPower > 0 ? ride.currentZone.color : nil
            )
            MetricCard(
                label: "Heart Rate",
                value: valueOrDash(ride.currentHR),
                unit: "bpm",
                emphasis: true
            )
            MetricCard(
                label: "Elapsed",
                value: ride.elapsed > 0 ? TimeFormat.mmss(ride.elapsed) : "--:--",
                emphasis: true
            )
        }
    }

    private func valueOrDash(_ v: Int) -> String { v > 0 ? "\(v)" : "--" }
}
