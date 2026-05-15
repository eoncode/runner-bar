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
/// Layout:  CPU [▄▄▄] 41.1%    MEM [▄▄▄] 6.4/16.0GB
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

            // Sparkline inline, constrained so it does not drive row height
            SparklineView(history: history, currentPct: currentPct)
                .frame(width: 40, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 2))

            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(labelColor)
        }
    }

    private var labelColor: Color {
        if currentPct > 85 { return .rbDanger }
        if currentPct > 60 { return .rbWarning }
        return .primary
    }
}

// MARK: - DiskPillBadge
/// Pill-shaped badge showing disk usage percentage, placed inline next to the
/// DISK sparkline in HeaderStatsBar.
struct DiskPillBadge: View {
    let freeGB: Double
    let freePct: Double

    var body: some View {
        Text(String(format: "%.0f%%", (1 - freePct / 100) * 100))
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(pillColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(pillColor.opacity(0.15), in: Capsule())
            .overlay(Capsule().strokeBorder(pillColor.opacity(0.35), lineWidth: 0.5))
    }

    private var pillColor: Color {
        if freePct < 10 { return .rbDanger }
        if freePct < 20 { return .rbWarning }
        return .rbWarning
    }
}

// MARK: - HeaderStatsBar
/// Compact single-row stats header: CPU | MEM | DISK [pill] as inline chips.
///
/// Layout: CPU [spark] 41.1% | MEM [spark] 7.0/16.0GB | DISK [spark] 394/460GB [87%]  →  ⚙ ✕
///
/// The DiskPillBadge sits immediately after the DISK SparklineMetricView,
/// before the Spacer, so it stays adjacent to the disk graph.
///
/// Accepts an existing SystemStatsViewModel so it shares the sampler
/// already running in PopoverMainView -- no second timer is created.
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

            // Thin vertical separator; fixed height tied to sparkline height
            Color.secondary.opacity(0.3)
                .frame(width: 1, height: 14)

            SparklineMetricView(
                label: "MEM",
                value: String(format: "%.1f/%.1fGB",
                              statsVM.stats.memUsedGB,
                              statsVM.stats.memTotalGB),
                history: statsVM.memHistory.values,
                currentPct: statsVM.stats.memTotalGB > 0
                    ? (statsVM.stats.memUsedGB / statsVM.stats.memTotalGB) * 100
                    : 0
            )

            Color.secondary.opacity(0.3)
                .frame(width: 1, height: 14)

            // DISK chip + usage pill inline, before Spacer
            HStack(spacing: 5) {
                SparklineMetricView(
                    label: "DISK",
                    value: String(format: "%d/%dGB",
                                  Int(statsVM.stats.diskUsedGB.rounded()),
                                  Int(statsVM.stats.diskTotalGB.rounded())),
                    history: statsVM.diskHistory.values,
                    currentPct: statsVM.stats.diskTotalGB > 0
                        ? (statsVM.stats.diskUsedGB / statsVM.stats.diskTotalGB) * 100
                        : 0
                )

                if statsVM.stats.diskTotalGB > 0 {
                    let usedPct = (statsVM.stats.diskUsedGB / statsVM.stats.diskTotalGB) * 100
                    let freeGB = statsVM.stats.diskTotalGB - statsVM.stats.diskUsedGB
                    DiskPillBadge(freeGB: freeGB, freePct: 100 - usedPct)
                }
            }

            Spacer()
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, RBSpacing.sm)
    }
}

// MARK: - BlockBarView (kept for backward compat)
/// Renders a coloured block-bar and percentage label for a given metric.
/// ⚠️ Deprecated -- use SparklineMetricView / HeaderStatsBar instead.
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
