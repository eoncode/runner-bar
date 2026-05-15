import SwiftUI

// MARK: - DiskPillView
/// Phase 2: DISK section of the header stat badge.
/// Spec (#403 comment): disk has a sparkline graph (same as CPU/MEM) plus a free-space
/// pill showing the percentage remaining. Graph color transitions green→orange→red.
///
/// diskHistory  — normalised 0–1 values, oldest first (driven by RunnerMetrics rolling buffer)
/// diskUsedPct  — current used percentage (0–100) used for graph colour and pill colour
/// freeGB       — free gigabytes shown in the pill
/// totalGB      — total gigabytes shown in the pill
struct DiskPillView: View {
    let diskHistory: [Double]
    let diskUsedPct: Double
    let freeGB: Int
    let totalGB: Int

    private var pillColor: Color {
        // free space thresholds: <10 % free = red, <30 % free = orange, else green
        let freePct = totalGB > 0 ? (Double(freeGB) / Double(totalGB)) * 100 : 100
        if freePct < 10 { return DesignTokens.Colors.statusRed }
        if freePct < 30 { return DesignTokens.Colors.statusOrange }
        return DesignTokens.Colors.statusGreen
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("DISK")
                .font(DesignTokens.Fonts.monoLabel)
                .foregroundColor(.secondary)
                .lineLimit(1)
            SparklineView(history: diskHistory, currentPct: diskUsedPct)
                .frame(width: 28, height: 14)
            // Free-space pill — e.g. "14%"
            let freePct = totalGB > 0 ? Int((Double(freeGB) / Double(totalGB)) * 100) : 0
            Text("\(freePct)%")
                .font(DesignTokens.Fonts.monoStat)
                .foregroundColor(pillColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(pillColor.opacity(0.12))
                        .overlay(
                            Capsule()
                                .strokeBorder(pillColor.opacity(0.35), lineWidth: 0.5)
                        )
                )
        }
    }
}
