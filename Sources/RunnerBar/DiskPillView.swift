// swiftlint:disable all
import SwiftUI

struct DiskPillView: View {
    let usedGB: Double
    let totalGB: Double

    private var pct: Double { totalGB > 0 ? usedGB / totalGB : 0 }
    private var color: Color {
        if pct > 0.9 { return DesignTokens.Colors.statusRed }
        if pct > 0.75 { return DesignTokens.Colors.statusOrange }
        return DesignTokens.Colors.statusGreen
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "internaldrive").font(.caption2).foregroundColor(color)
            Text(String(format: "%.0f%%", pct * 100))
                .font(.caption2.monospacedDigit())
                .foregroundColor(color)
            Text(String(format: "%.0f/%.0fGB", usedGB, totalGB))
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.08)))
    }
}
// swiftlint:enable all
