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
    static let wattbikeGearCount = "cyclejames_wattbikeGearCount"
    static let coursePersonalBests = "cyclejames_coursePersonalBests"
    static let coursePersonalBestSplits = "cyclejames_coursePersonalBestSplits"
    static let coursePersonalBestSessions = "cyclejames_coursePersonalBestSessions"
    static let coursePersonalBestClearedAt = "cyclejames_coursePersonalBestClearedAt"
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

    /// Gears on the rider's Wattbike Hub preset: 11 or 22 linear, 24 for the
    /// 12-speed compact presets. Sets the gear badge's "/22" and ladder; a
    /// higher gear reported mid-ride raises it for that ride.
    static let wattbikeGearCounts = [11, 22, 24]
    static let defaultWattbikeGearCount = GearTracker.defaultCount

    static var wattbikeGearCount: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: SettingsKeys.wattbikeGearCount)
            return wattbikeGearCounts.contains(v) ? v : defaultWattbikeGearCount
        }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.wattbikeGearCount) }
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

    /// The personal-best run's time since the climb start at every 10 m of
    /// the climb (see `ClimbTimer.splitDistances`), for live PB deltas.
    static func personalBestSplits(courseID: String) -> [Double]? {
        let all = UserDefaults.standard.dictionary(forKey: SettingsKeys.coursePersonalBestSplits) as? [String: [Double]]
        return all?[courseID]
    }

    /// The History ride (`RideSessionModel.id`) that set the personal best,
    /// when known.
    static func personalBestSessionID(courseID: String) -> UUID? {
        let all = UserDefaults.standard.dictionary(forKey: SettingsKeys.coursePersonalBestSessions) as? [String: String]
        return all?[courseID].flatMap(UUID.init(uuidString:))
    }

    /// Stores a new personal best: the climb time, its splits and the
    /// History ride it came from.
    static func setPersonalBest(seconds: Double, splits: [Double], courseID: String, sessionID: UUID? = nil) {
        setPersonalBestSeconds(seconds, courseID: courseID)
        let defaults = UserDefaults.standard
        var all = defaults.dictionary(forKey: SettingsKeys.coursePersonalBestSplits) as? [String: [Double]] ?? [:]
        all[courseID] = splits
        defaults.set(all, forKey: SettingsKeys.coursePersonalBestSplits)
        var sessions = defaults.dictionary(forKey: SettingsKeys.coursePersonalBestSessions) as? [String: String] ?? [:]
        sessions[courseID] = sessionID?.uuidString
        defaults.set(sessions, forKey: SettingsKeys.coursePersonalBestSessions)
    }

    /// Forgets a course's personal best (time, splits and source ride).
    /// Rides started before now can't become it again when History is
    /// worked out anew (`CourseRideRecorder.recomputePersonalBest`), so a
    /// reset holds even if the next PB ride is deleted.
    static func clearPersonalBest(courseID: String) {
        let defaults = UserDefaults.standard
        for key in [SettingsKeys.coursePersonalBests, SettingsKeys.coursePersonalBestSplits,
                    SettingsKeys.coursePersonalBestSessions] {
            guard var all = defaults.dictionary(forKey: key) else { continue }
            all[courseID] = nil
            defaults.set(all, forKey: key)
        }
        var cleared = defaults.dictionary(forKey: SettingsKeys.coursePersonalBestClearedAt) as? [String: Double] ?? [:]
        cleared[courseID] = Date().timeIntervalSince1970
        defaults.set(cleared, forKey: SettingsKeys.coursePersonalBestClearedAt)
    }

    /// When the course's personal best was last cleared, if ever.
    static func personalBestClearedAt(courseID: String) -> Date? {
        let all = UserDefaults.standard.dictionary(forKey: SettingsKeys.coursePersonalBestClearedAt) as? [String: Double]
        return all?[courseID].map(Date.init(timeIntervalSince1970:))
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
