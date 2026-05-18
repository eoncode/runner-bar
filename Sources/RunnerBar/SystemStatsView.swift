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

// MARK: - SparklineMetricView
/// A single header metric chip: label + inline sparkline + monospaced value,
/// all in one horizontal row -- matching the reference compact header design.
///
/// Layout:  CPU [▄6▄6▄6] 41.1%    MEM [▄6▄6▄6] 6.4/16.0GB
///             ^     ^     ^
///    9pt label   40x14pt sparkline   10pt mono value
///
/// Do NOT restore the VStack layout -- it makes the header ~70pt tall.
struct SparklineMetricView: View {
    let label: String
    let value: String
    let history: [Double]
    let currentPct: Double

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()

            SparklineView(history: history, currentPct: currentPct)
                .frame(width: 40, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 2))

            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(labelColor)
                .fixedSize()
        }
        .fixedSize()
    }

    private var labelColor: Color {
        if currentPct > 85 { return .rbDanger }
        if currentPct > 60 { return .rbWarning }
        return .primary
    }
}

// MARK: - DiskPillBadge
/// Compact pill showing disk FREE percentage, placed inline next to the
/// DISK sparkline in HeaderStatsBar.
///
/// Color thresholds (inverted vs. used-space -- low free = danger):
///   freePct < 15  →  rbDanger  (red)
///   freePct < 40  →  rbWarning (orange)
///   else          →  rbSuccess (green)
///
/// Always renders at its intrinsic size -- never truncates.
struct DiskPillBadge: View {
    // Percentage of disk space that is FREE (0-100).
    let freePct: Double
    var body: some View {
        Text(String(format: "%.0f%% free", freePct))
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(pillColor)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(pillColor.opacity(0.15), in: Capsule())
            .overlay(Capsule().strokeBorder(pillColor.opacity(0.35), lineWidth: 0.5))
            .fixedSize()
    }

    private var pillColor: Color {
        if freePct < 15 { return .rbDanger }
        if freePct < 40 { return .rbWarning }
        return .rbSuccess
    }
}

// MARK: - HeaderStatsBar
// Compact single-row stats header: CPU | MEM | DISK [pill] as inline chips.
//
// Layout: CPU [spark] 41.1% | MEM [spark] 7.0/16.0GB | DISK [spark] 394/460GB [13% free]  →  ⚙ ✕
//
// The DiskPillBadge sits immediately after the DISK SparklineMetricView,
// before the Spacer, so it stays adjacent to the disk graph.
//
// Accepts an existing SystemStatsViewModel so it shares the sampler
// already running in PopoverMainView -- no second timer is created.
struct HeaderStatsBar: View {
    @ObservedObject var statsVM: SystemStatsViewModel

    var body: some View {
        HStack(spacing: RBSpacing.md) {
            SparklineMetricView(
                label: "CPU",
                value: String(format: "%.1f%%", statsVM.stats.cpuPct),
                history: statsVM.cpuHistory.values,
                currentPct: statsVM.stats.cpuPct
            )

            Color.secondary.opacity(0.3)
                .frame(width: 1, height: 14)

            let memTotal = statsVM.stats.memTotalGB
            let memUsed = statsVM.stats.memUsedGB
            let memPct = memTotal > 0 ? memUsed / memTotal * 100 : 0.0
            SparklineMetricView(
                label: "MEM",
                value: String(format: "%.1f/%.1fGB", memUsed, memTotal),
                history: statsVM.memHistory.values,
                currentPct: memPct
            )

            Color.secondary.opacity(0.3)
                .frame(width: 1, height: 14)

            HStack(spacing: 5) {
                let diskTotal = statsVM.stats.diskTotalGB
                let diskUsed = statsVM.stats.diskUsedGB
                let diskUsedPct = diskTotal > 0 ? diskUsed / diskTotal * 100 : 0.0

                SparklineMetricView(
                    label: "DISK",
                    value: String(format: "%d/%dGB",
                                  Int(statsVM.stats.diskUsedGB.rounded()),
                                  Int(statsVM.stats.diskTotalGB.rounded())),
                    history: statsVM.diskHistory.values,
                    currentPct: diskUsedPct
                )

                if statsVM.stats.diskTotalGB > 0 {
                    DiskPillBadge(freePct: statsVM.stats.diskFreePct)
                }
            }
            .fixedSize()

            Spacer()
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, RBSpacing.sm)
    }
}

// MARK: - BlockBarView (kept for backward compat)
// Renders a coloured block-bar and percentage label for a given metric.
// Deprecated -- use SparklineMetricView / HeaderStatsBar instead.
struct BlockBarView: View {
    let label: String
    let pct: Double

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(DesignTokens.Fonts.monoLabel)
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
                .font(DesignTokens.Fonts.mono)
                .foregroundColor(usageColor)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var usageColor: Color {
        DesignTokens.Colors.usage(pct: pct)
    }
}
