import SwiftUI

enum SettingsKeys {
    static let ftp = "cyclejames_ftp"
    static let hasOnboarded = "cyclejames_hasOnboarded"
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
}
