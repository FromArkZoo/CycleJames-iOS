import SwiftUI

enum CJFont {
    static let metricLarge = Font.system(size: 36, weight: .heavy, design: .rounded).monospacedDigit()
    static let metricMedium = Font.system(size: 28, weight: .heavy, design: .rounded).monospacedDigit()
    static let metricSmall = Font.system(size: 22, weight: .bold, design: .rounded).monospacedDigit()
    static let title = Font.system(size: 20, weight: .bold)
    static let body = Font.system(size: 14, weight: .regular)
    static let bodyBold = Font.system(size: 14, weight: .semibold)
    static let caption = Font.system(size: 12, weight: .regular)
    static let labelUpper = Font.system(size: 11, weight: .semibold)
    static let small = Font.system(size: 10, weight: .regular)
    static let buttonText = Font.system(size: 16, weight: .semibold)
    static let button = Font.system(size: 14, weight: .semibold)
}
