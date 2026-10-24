import SwiftUI

/// Rider weight, bike weight, trainer difficulty, Wattbike gears and graphics
/// quality for 3D course rides. Shown in Settings and as shortcuts on each
/// course page; both write the same `AppSettings` keys.
struct CourseRideSettingsControls: View {
    @AppStorage(SettingsKeys.riderWeightKg) private var riderWeightKg: Double = AppSettings.defaultRiderWeightKg
    @AppStorage(SettingsKeys.bikeWeightKg) private var bikeWeightKg: Double = AppSettings.defaultBikeWeightKg
    @AppStorage(SettingsKeys.trainerDifficultyPct) private var difficultyPct: Int = AppSettings.defaultTrainerDifficultyPct
    @AppStorage(SettingsKeys.wattbikeGearCount) private var wattbikeGears: Int = AppSettings.defaultWattbikeGearCount
    @AppStorage(SettingsKeys.graphicsQuality) private var graphicsQuality: String = "auto"

    var showsBikeWeight: Bool = true

    private var difficultyBinding: Binding<Double> {
        Binding(
            get: { Double(difficultyPct.clamped(to: AppSettings.trainerDifficultyRange)) },
            set: { difficultyPct = Int(($0 / 5).rounded() * 5).clamped(to: AppSettings.trainerDifficultyRange) }
        )
    }

    private var autoQualityLabel: String {
        GraphicsQuality.resolved(setting: "auto").label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CJSpacing.m) {
            weightRow(
                "Rider weight",
                value: $riderWeightKg,
                range: AppSettings.riderWeightRange,
                caption: "Sets your speed on the climbs and your W/kg."
            )
            if showsBikeWeight {
                weightRow("Bike weight", value: $bikeWeightKg, range: AppSettings.bikeWeightRange, caption: nil)
            }

            Divider().overlay(CJColors.border)

            VStack(alignment: .leading, spacing: CJSpacing.xs) {
                HStack {
                    Text("Trainer difficulty")
                        .font(CJFont.body)
                        .foregroundStyle(CJColors.textPrimary)
                    Spacer()
                    Text("\(difficultyPct.clamped(to: AppSettings.trainerDifficultyRange))%")
                        .font(CJFont.bodyBold)
                        .foregroundStyle(CJColors.textPrimary)
                        .monospacedDigit()
                }
                Slider(value: difficultyBinding, in: 0...100, step: 5)
                    .tint(CJColors.accent)
                    .accessibilityLabel("Trainer difficulty")
                    .accessibilityValue("\(difficultyPct) percent")
                Text("How much of the real gradient your trainer applies. 100% is the true climb; 50% feels half as steep. Speed and times always use the real road.")
                    .font(CJFont.caption)
                    .foregroundStyle(CJColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(CJColors.border)

            VStack(alignment: .leading, spacing: CJSpacing.xs) {
                HStack {
                    Text("Wattbike gears")
                        .font(CJFont.body)
                        .foregroundStyle(CJColors.textPrimary)
                    Spacer()
                    Picker("Wattbike gears", selection: $wattbikeGears) {
                        ForEach(AppSettings.wattbikeGearCounts, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
                Text("Match the gearing chosen in Wattbike Hub, so the gear badge's ladder tops out at your hardest gear.")
                    .font(CJFont.caption)
                    .foregroundStyle(CJColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(CJColors.border)

            VStack(alignment: .leading, spacing: CJSpacing.xs) {
                HStack {
                    Text("Graphics quality")
                        .font(CJFont.body)
                        .foregroundStyle(CJColors.textPrimary)
                    Spacer()
                    Picker("Graphics quality", selection: $graphicsQuality) {
                        Text("Auto").tag("auto")
                        ForEach(GraphicsQuality.allCases, id: \.self) { q in
                            Text(q.label).tag(q.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(CJColors.accent)
                }
                Text(graphicsQuality == "auto"
                     ? "Auto picks for this iPhone and its battery and temperature at the start of each ride (now: \(autoQualityLabel))."
                     : "Battery saver keeps the phone cool on long sessions: fewer effects and 30 fps.")
                    .font(CJFont.caption)
                    .foregroundStyle(CJColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func weightRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, caption: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Stepper(value: value, in: range, step: 0.5) {
                HStack {
                    Text(title)
                        .font(CJFont.body)
                        .foregroundStyle(CJColors.textPrimary)
                    Spacer()
                    Text(String(format: "%.1f kg", value.wrappedValue.clamped(to: range)))
                        .font(CJFont.bodyBold)
                        .foregroundStyle(CJColors.textPrimary)
                        .monospacedDigit()
                }
            }
            if let caption {
                Text(caption)
                    .font(CJFont.caption)
                    .foregroundStyle(CJColors.textSecondary)
            }
        }
    }
}
