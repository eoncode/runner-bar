// swiftlint:disable all
import SwiftUI

struct DiskPillView: View {
    /// Percentage history for the sparkline (0–100), oldest first.
    let diskHistory: [Double]
    /// Current used percentage (0–100).
    let diskUsedPct: Double
    /// Free gigabytes (integer).
    let freeGB: Int
    /// Total gigabytes (integer).
    let totalGB: Int

    private var pct: Double { diskUsedPct / 100.0 }
    private var color: Color {
        if pct > 0.9 { return DesignTokens.Colors.statusRed }
        if pct > 0.75 { return DesignTokens.Colors.statusOrange }
        return DesignTokens.Colors.statusGreen
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "internaldrive").font(.caption2).foregroundColor(color)
            SparklineView(history: diskHistory, currentPct: diskUsedPct, color: color)
                .frame(width: 24, height: 12)
            Text(String(format: "%.0f%%", diskUsedPct))
                .font(.caption2.monospacedDigit())
                .foregroundColor(color)
            Text("\(freeGB)GB free")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.08)))
    }
}
// swiftlint:enable all
