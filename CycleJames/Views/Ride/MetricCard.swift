import SwiftUI

struct MetricCard: View {
    let label: String
    let value: String
    var unit: String? = nil
    var emphasis: Bool = false
    var tint: Color? = nil

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var compact: Bool { verticalSizeClass == .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(CJFont.labelUpper)
                .foregroundStyle(CJColors.textSecondary)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(valueFont)
                    .foregroundStyle(CJColors.textPrimary)
                if let unit {
                    Text(unit)
                        .font(CJFont.caption)
                        .foregroundStyle(CJColors.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 0 : 54, alignment: .leading)
        .padding(.horizontal, CJSpacing.s)
        .padding(.vertical, compact ? 4 : 8)
        .background(tint?.opacity(0.18) ?? CJColors.card.opacity(0.85))
        .overlay(
            RoundedRectangle(cornerRadius: CJRadius.medium)
                .stroke(tint ?? CJColors.border, lineWidth: tint == nil ? 1 : 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
    }

    private var valueFont: Font {
        if compact && emphasis {
            return .system(size: 28, weight: .heavy, design: .rounded).monospacedDigit()
        }
        return emphasis ? CJFont.metricLarge : CJFont.metricSmall
    }
}
