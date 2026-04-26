import SwiftUI

struct MetricCard: View {
    let label: String
    let value: String
    var unit: String? = nil
    var emphasis: Bool = false
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(CJFont.labelUpper)
                .foregroundStyle(CJColors.textSecondary)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(emphasis ? CJFont.metricLarge : CJFont.metricSmall)
                    .foregroundStyle(CJColors.textPrimary)
                if let unit {
                    Text(unit)
                        .font(CJFont.caption)
                        .foregroundStyle(CJColors.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        .padding(CJSpacing.m)
        .background(tint?.opacity(0.18) ?? CJColors.card.opacity(0.85))
        .overlay(
            RoundedRectangle(cornerRadius: CJRadius.medium)
                .stroke(tint ?? CJColors.border, lineWidth: tint == nil ? 1 : 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
    }
}
