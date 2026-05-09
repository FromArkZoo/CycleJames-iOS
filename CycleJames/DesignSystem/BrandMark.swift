import SwiftUI

/// Small "CJ" gradient wordmark for nav-bar leading edge — anchors brand
/// identity on tabs whose principal title describes the screen ("Favourites",
/// "Calendar", etc.) rather than the app.
struct BrandMark: View {
    var body: some View {
        Text("CJ")
            .font(.system(size: 18, weight: .thin, design: .default))
            .italic()
            .foregroundStyle(CJColors.brandGradient)
            .accessibilityLabel("CycleJames")
    }
}
