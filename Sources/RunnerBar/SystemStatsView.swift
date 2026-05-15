import SwiftUI

// MARK: - SystemStatsView
/// Full-page system stats view shown in the settings panel.
struct SystemStatsView: View {
    @StateObject private var viewModel = SystemStatsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System Stats")
                .font(.headline)
                .padding(.bottom, 4)

            statRow(label: "CPU",          value: String(format: "%.1f%%",    viewModel.stats.cpuPct))
            statRow(label: "Memory Used",  value: String(format: "%.1f GB",   viewModel.stats.memUsedGB))
            statRow(label: "Memory Total", value: String(format: "%.1f GB",   viewModel.stats.memTotalGB))
            statRow(label: "Disk Used",    value: String(format: "%.1f GB",   viewModel.stats.diskUsedGB))
            statRow(label: "Disk Total",   value: String(format: "%.1f GB",   viewModel.stats.diskTotalGB))
        }
        .padding()
        .onAppear  { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(DesignTokens.Fonts.monoLabel)   // Phase 1: mono font token
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(DesignTokens.Fonts.mono)         // Phase 1: mono font token
        }
    }
}

// MARK: - BlockBarView
/// Renders a coloured block-bar and percentage label for a given metric.
struct BlockBarView: View {
    let label: String
    let pct: Double

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(DesignTokens.Fonts.monoLabel)   // Phase 1: mono font token
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
                .font(DesignTokens.Fonts.mono)         // Phase 1: mono font token
                .foregroundColor(usageColor)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var usageColor: Color {
        DesignTokens.Colors.usage(pct: pct)            // Phase 1: colour token
    }
}
