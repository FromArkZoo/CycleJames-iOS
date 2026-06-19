import SwiftUI

/// Stripped-down Ride layout for iPhone landscape (e.g. when the phone is in
/// a landscape bike mount). Top row of pills (interval / power / HR / elapsed),
/// the workout graph in the middle, and the interval edit bar at the bottom.
struct LandscapeRideLayout: View {
    @EnvironmentObject private var ride: RideController
    var onShowUpcoming: () -> Void
    var onShowAddInterval: () -> Void
    var onShowSettings: () -> Void

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
                    compact: true,
                    powerHistory: ride.powerHistory,
                    ghostTarget: ride.mode == .freeRide
                )
                .frame(maxHeight: .infinity)
            }
            if canEditLive {
                IntervalEditBar(
                    onShowUpcoming: onShowUpcoming,
                    onShowAddInterval: onShowAddInterval,
                    onShowSettings: onShowSettings
                )
            }
        }
        .padding(.horizontal, CJSpacing.m)
        .padding(.top, CJSpacing.xs)
    }

    private var pillsRow: some View {
        HStack(alignment: .top, spacing: CJSpacing.xs) {
            IntervalPill()
            MetricCard(
                label: "Power",
                value: valueOrDash(ride.rolling3sPower),
                unit: "W",
                emphasis: true,
                tint: ride.rolling3sPower > 0 ? ride.currentZone.color : nil,
                valueColor: powerTextColor
            )
            MetricCard(
                label: "Target",
                value: ride.currentTarget > 0 ? "\(ride.currentTarget)" : "--",
                unit: "W",
                emphasis: true
            )
            MetricCard(
                label: "Heart Rate",
                value: valueOrDash(ride.currentHR),
                unit: "bpm",
                emphasis: true
            )
            MetricCard(
                label: "RPM",
                value: valueOrDash(ride.currentCadence),
                emphasis: true
            )
            MetricCard(
                label: "Elapsed",
                value: ride.elapsed > 0 ? TimeFormat.mmss(ride.elapsed) : "--:--",
                emphasis: true
            )
        }
    }

    /// Red below target, green above, default within a small dead-band so it
    /// doesn't strobe when you're holding the prescribed power.
    private var powerTextColor: Color? {
        guard ride.currentTarget > 0, ride.rolling3sPower > 0 else { return nil }
        let target = ride.currentTarget
        let band = max(5, Int(Double(target) * 0.02))
        if ride.rolling3sPower < target - band { return CJColors.danger }
        if ride.rolling3sPower > target + band { return CJColors.success }
        return nil
    }

    private func valueOrDash(_ v: Int) -> String { v > 0 ? "\(v)" : "--" }
}
