import SwiftUI

struct CountdownOverlay: View {
    let number: Int

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            Text(number == 0 ? "GO!" : "\(number)")
                .font(.system(size: 180, weight: .heavy, design: .rounded))
                .foregroundStyle(CJColors.accent)
                .shadow(color: CJColors.accent.opacity(0.5), radius: 20)
                .scaleEffect(number == 0 ? 1.2 : 1.0)
                .animation(.easeOut(duration: 0.4), value: number)
        }
    }
}
