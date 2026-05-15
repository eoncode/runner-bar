// swiftlint:disable type_body_length
import SwiftUI

// MARK: - SystemStatsView

/// Compact CPU / RAM bar shown at the bottom of the popover.
struct SystemStatsView: View {
    /// Live system stats injected from the parent.
    let stats: SystemStatsSnapshot

    var body: some View {
        HStack(spacing: 10) {
            statPill(
                icon: "cpu",
                label: "CPU",
                value: stats.cpuPercent,
                color: stats.cpuPercent > 80 ? .red : .blue
            )
            statPill(
                icon: "memorychip",
                label: "RAM",
                value: stats.memPercent,
                color: stats.memPercent > 80 ? .red : .green
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func statPill(icon: String, label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Text(label)
                .font(DesignTokens.Font.monoXSmall)
                .foregroundColor(.secondary)
            Text(String(format: "%.0f%%", value))
                .font(DesignTokens.Font.monoXSmall)
                .foregroundColor(value > 80 ? color : .secondary)
        }
    }
}
// swiftlint:enable type_body_length
