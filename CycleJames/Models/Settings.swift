import SwiftUI

enum SettingsKeys {
    static let ftp = "cyclejames_ftp"
    static let hasOnboarded = "cyclejames_hasOnboarded"
    static let favouriteWorkoutIDs = "cyclejames_favouriteWorkoutIDs"
    static let completedRideCount = "cyclejames_completedRideCount"
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
}

/// Decides when to ask for an App Store review. Only from the 3rd completed
/// ride onward, so the prompt lands on a genuine positive moment (the system
/// further caps prompts to ~3/year).
enum ReviewPrompt {
    static func shouldRequest(afterCompletedCount count: Int) -> Bool {
        count >= 3
    }
}
