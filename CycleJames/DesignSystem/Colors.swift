import SwiftUI

enum CJColors {
    static let bgPrimary    = Color(red: 0.102, green: 0.102, blue: 0.180) // #1a1a2e
    static let bgSecondary  = Color(red: 0.086, green: 0.129, blue: 0.243) // #16213e
    static let card         = Color(red: 0.059, green: 0.204, blue: 0.376) // #0f3460
    static let cardHover    = Color(red: 0.082, green: 0.251, blue: 0.502) // #154080
    static let border       = Color(red: 0.165, green: 0.165, blue: 0.290) // #2a2a4a

    static let textPrimary   = Color(red: 0.878, green: 0.878, blue: 0.878) // #e0e0e0
    static let textSecondary = Color(red: 0.627, green: 0.627, blue: 0.627) // #a0a0a0
    static let textMuted     = Color(red: 0.376, green: 0.376, blue: 0.502) // #606080

    static let accent       = Color(red: 0.000, green: 0.706, blue: 0.847) // #00b4d8
    static let accentDim    = Color(red: 0.000, green: 0.467, blue: 0.714) // #0077b6
    static let success      = Color(red: 0.298, green: 0.686, blue: 0.314) // #4CAF50
    static let warning      = Color(red: 1.000, green: 0.596, blue: 0.000) // #FF9800
    static let danger       = Color(red: 0.957, green: 0.263, blue: 0.212) // #F44336

    static let positionMarker = Color(red: 1.000, green: 0.843, blue: 0.000) // #FFD700

    // Brand wordmark gradient — matches the app icon (amber → orange → red).
    static let brandWarm1 = Color(red: 1.000, green: 0.784, blue: 0.341) // #FFC857
    static let brandWarm2 = Color(red: 1.000, green: 0.549, blue: 0.180) // #FF8C2E
    static let brandWarm3 = Color(red: 0.914, green: 0.294, blue: 0.235) // #E94B3C

    static let brandGradient = LinearGradient(
        colors: [brandWarm1, brandWarm2, brandWarm3],
        startPoint: .top,
        endPoint: .bottom
    )
}
