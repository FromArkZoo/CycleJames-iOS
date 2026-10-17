import SwiftUI

enum SettingsKeys {
    static let ftp = "cyclejames_ftp"
    static let hasOnboarded = "cyclejames_hasOnboarded"
    static let favouriteWorkoutIDs = "cyclejames_favouriteWorkoutIDs"
    static let completedRideCount = "cyclejames_completedRideCount"
    static let riderWeightKg = "cyclejames_riderWeightKg"
    static let bikeWeightKg = "cyclejames_bikeWeightKg"
    static let trainerDifficultyPct = "cyclejames_trainerDifficultyPct"
    static let graphicsQuality = "cyclejames_graphicsQuality"
    static let coursePersonalBests = "cyclejames_coursePersonalBests"
}

enum AppSettings {
    static let defaultFTP = 200
    static let minFTP = 50
    static let maxFTP = 500

    static var ftp: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: SettingsKeys.ftp)
            return v == 0 ? defaultFTP : v
        }
        set {
            UserDefaults.standard.set(max(minFTP, min(maxFTP, newValue)), forKey: SettingsKeys.ftp)
        }
    }

    static var completedRideCount: Int {
        get { UserDefaults.standard.integer(forKey: SettingsKeys.completedRideCount) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.completedRideCount) }
    }

    // MARK: 3D course rides

    static let defaultRiderWeightKg = 75.0
    static let riderWeightRange: ClosedRange<Double> = 35...160
    static let defaultBikeWeightKg = 8.5
    static let bikeWeightRange: ClosedRange<Double> = 5...20
    /// 100 % sends the real gradient to the trainer; lower values flatten it
    /// the way Zwift's "trainer difficulty" does. Speed is unaffected.
    static let defaultTrainerDifficultyPct = 100
    static let trainerDifficultyRange: ClosedRange<Int> = 0...100

    static var riderWeightKg: Double {
        get { storedDouble(SettingsKeys.riderWeightKg, default: defaultRiderWeightKg, in: riderWeightRange) }
        set { UserDefaults.standard.set(newValue.clamped(to: riderWeightRange), forKey: SettingsKeys.riderWeightKg) }
    }

    static var bikeWeightKg: Double {
        get { storedDouble(SettingsKeys.bikeWeightKg, default: defaultBikeWeightKg, in: bikeWeightRange) }
        set { UserDefaults.standard.set(newValue.clamped(to: bikeWeightRange), forKey: SettingsKeys.bikeWeightKg) }
    }

    static var trainerDifficultyPct: Int {
        get {
            guard UserDefaults.standard.object(forKey: SettingsKeys.trainerDifficultyPct) != nil else {
                return defaultTrainerDifficultyPct
            }
            return UserDefaults.standard.integer(forKey: SettingsKeys.trainerDifficultyPct)
                .clamped(to: trainerDifficultyRange)
        }
        set {
            UserDefaults.standard.set(newValue.clamped(to: trainerDifficultyRange), forKey: SettingsKeys.trainerDifficultyPct)
        }
    }

    /// "auto" or a `GraphicsQuality` raw value.
    static var graphicsQuality: String {
        get { UserDefaults.standard.string(forKey: SettingsKeys.graphicsQuality) ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.graphicsQuality) }
    }

    /// Best climb time in seconds per course id.
    static func personalBestSeconds(courseID: String) -> Double? {
        let all = UserDefaults.standard.dictionary(forKey: SettingsKeys.coursePersonalBests) as? [String: Double]
        return all?[courseID]
    }

    static func setPersonalBestSeconds(_ seconds: Double, courseID: String) {
        var all = UserDefaults.standard.dictionary(forKey: SettingsKeys.coursePersonalBests) as? [String: Double] ?? [:]
        all[courseID] = seconds
        UserDefaults.standard.set(all, forKey: SettingsKeys.coursePersonalBests)
    }

    private static func storedDouble(_ key: String, default value: Double, in range: ClosedRange<Double>) -> Double {
        guard UserDefaults.standard.object(forKey: key) != nil else { return value }
        return UserDefaults.standard.double(forKey: key).clamped(to: range)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Decides when to ask for an App Store review. Only from the 3rd completed
/// ride onward, so the prompt lands on a genuine positive moment (the system
/// further caps prompts to ~3/year).
enum ReviewPrompt {
    static func shouldRequest(afterCompletedCount count: Int) -> Bool {
        count >= 3
    }
}
