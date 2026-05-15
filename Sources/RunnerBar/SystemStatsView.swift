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

// MARK: - SparklineMetricView
/// A single header metric tile: label + sparkline graph + monospaced value.
struct SparklineMetricView: View {
    let label: String
    let value: String
    let history: [Double]
    let currentPct: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)

            SparklineView(history: history, currentPct: currentPct)
                .frame(height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 3))

            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(labelColor)
        }
        .frame(maxWidth: .infinity)
    }

    private var labelColor: Color {
        if currentPct > 85 { return .rbDanger }
        if currentPct > 60 { return .rbWarning }
        return .primary
    }
}

// MARK: - DiskPillBadge
/// Pill-shaped badge showing free disk space, with ultraThinMaterial background.
struct DiskPillBadge: View {
    let freeGB: Double
    let freePct: Double

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "internaldrive")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(String(format: "%.0f GB free", freeGB))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(pillColor)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(pillColor.opacity(0.3), lineWidth: 0.5)
        )
    }

    private var pillColor: Color {
        if freePct < 10 { return .rbDanger }
        if freePct < 20 { return .rbWarning }
        return .rbSuccess
    }
}

// MARK: - HeaderStatsBar
/// The compact 3-column sparkline header used in the popover.
/// Drop-in replacement for BlockBarView rows — call from PopoverMainView.
struct HeaderStatsBar: View {
    @StateObject private var vm = SystemStatsViewModel()

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                SparklineMetricView(
                    label: "CPU",
                    value: String(format: "%.0f%%", vm.stats.cpuPct),
                    history: vm.cpuHistory.values,
                    currentPct: vm.stats.cpuPct
                )

                Divider()
                    .frame(height: 36)
                    .padding(.horizontal, 4)

                SparklineMetricView(
                    label: "MEM",
                    value: String(format: "%.1f GB", vm.stats.memUsedGB),
                    history: vm.memHistory.values,
                    currentPct: vm.stats.memTotalGB > 0
                        ? (vm.stats.memUsedGB / vm.stats.memTotalGB) * 100
                        : 0
                )

                Divider()
                    .frame(height: 36)
                    .padding(.horizontal, 4)

                SparklineMetricView(
                    label: "DISK",
                    value: String(format: "%.0f%%", vm.stats.diskTotalGB > 0
                        ? (vm.stats.diskUsedGB / vm.stats.diskTotalGB) * 100
                        : 0),
                    history: vm.diskHistory.values,
                    currentPct: vm.stats.diskTotalGB > 0
                        ? (vm.stats.diskUsedGB / vm.stats.diskTotalGB) * 100
                        : 0
                )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: RBRadius.card))

            HStack {
                Spacer()
                DiskPillBadge(
                    freeGB: vm.stats.diskFreeGB,
                    freePct: vm.stats.diskFreePct
                )
            }
            .padding(.horizontal, 8)
        }
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }
}

// MARK: - BlockBarView (kept for backward compat)
/// Renders a coloured block-bar and percentage label for a given metric.
/// ⚠️ Deprecated — use SparklineMetricView / HeaderStatsBar instead.
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
