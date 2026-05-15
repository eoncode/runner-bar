import SwiftUI

// MARK: - SystemStatsView
/// Full-page system stats view shown in the settings panel.
/// Phase 2 (#419): flat progress bars replaced with SparklineView per metric.
struct SystemStatsView: View {
    @StateObject private var viewModel = SystemStatsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System Stats")
                .font(.headline)
                .padding(.bottom, 4)

            sparklineRow(
                label: "CPU",
                history: viewModel.cpuHistory,
                currentPct: viewModel.stats.cpuPct,
                valueText: String(format: "%.1f%%", viewModel.stats.cpuPct)
            )
            sparklineRow(
                label: "MEM",
                history: viewModel.memHistory,
                currentPct: viewModel.stats.memTotalGB > 0
                    ? (viewModel.stats.memUsedGB / viewModel.stats.memTotalGB) * 100
                    : 0,
                valueText: String(
                    format: "%.1f/%.1fGB",
                    viewModel.stats.memUsedGB,
                    viewModel.stats.memTotalGB
                )
            )
            statRow(label: "Disk Used",  value: String(format: "%.1f GB", viewModel.stats.diskUsedGB))
            statRow(label: "Disk Total", value: String(format: "%.1f GB", viewModel.stats.diskTotalGB))
        }
        .padding()
        .onAppear  { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    /// Phase 2: label + SparklineView + current value in a single row.
    private func sparklineRow(
        label: String,
        history: [Double],
        currentPct: Double,
        valueText: String
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(DesignTokens.Fonts.monoLabel)
                .foregroundColor(.secondary)
                .frame(width: 36, alignment: .leading)
            SparklineView(history: history, currentPct: currentPct)
                .frame(width: 60, height: 16)
            Spacer()
            Text(valueText)
                .font(DesignTokens.Fonts.mono)
                .foregroundColor(DesignTokens.Colors.usage(pct: currentPct))
        }
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(DesignTokens.Fonts.monoLabel)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(DesignTokens.Fonts.mono)
        }
    }
}
