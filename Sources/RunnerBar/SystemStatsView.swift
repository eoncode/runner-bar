import SwiftUI

// MARK: - SystemStatsView

/// Full-page system stats view shown in the settings panel.
struct SystemStatsView: View {
    @StateObject private var viewModel = SystemStatsViewModel()

    /// Main body: stacked stat rows with start/stop lifecycle hooks.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System Stats")
                .font(.headline)
                .padding(.bottom, 4)

            statRow(label: "CPU", value: String(format: "%.1f%%", viewModel.stats.cpuPct))
            statRow(label: "Memory Used", value: String(format: "%.1f GB", viewModel.stats.memUsedGB))
            statRow(label: "Memory Total", value: String(format: "%.1f GB", viewModel.stats.memTotalGB))
            statRow(label: "Disk Used", value: String(format: "%.1f GB", viewModel.stats.diskUsedGB))
            statRow(label: "Disk Total", value: String(format: "%.1f GB", viewModel.stats.diskTotalGB))
        }
        .padding()
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    /// Renders a single label/value row.
    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
        }
    }
}

// MARK: - BlockBarView

/// Renders a coloured block-bar and percentage label for a given metric.
struct BlockBarView: View {
    /// Metric label shown to the left of the bar.
    let label: String
    /// Current usage percentage (0–100).
    let pct: Double

    /// Main body: label, bar, and percentage readout.
    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)

            GeometryReader { geo in
                let barWidth = geo.size.width * CGFloat(min(max(pct / 100.0, 0), 1))
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                    Rectangle()
                        .fill(usageColor)
                        .frame(width: barWidth)
                }
                .cornerRadius(2)
            }
            .frame(height: 6)

            Text(String(format: "%.0f%%", pct))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(usageColor)
                .frame(width: 36, alignment: .trailing)
        }
    }

    /// Color for the bar fill and percentage label, based on usage level.
    private var usageColor: Color {
        if pct > 85 { return .red }
        if pct > 60 { return .yellow }
        return .green
    }
}
