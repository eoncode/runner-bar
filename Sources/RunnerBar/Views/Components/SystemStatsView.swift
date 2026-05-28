// SystemStatsView.swift
// RunnerBar
import RunnerBarCore
import SwiftUI

// MARK: - SystemStatsView
// periphery:ignore
/// Full-page system stats view shown in the settings panel.
struct SystemStatsView: View {
    /// The viewModel property.
    @StateObject private var viewModel = SystemStatsViewModel()

    /// The body property.
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
        .glassCard(cornerRadius: RBRadius.card)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    /// Returns a single label/value row for display in the stats panel.
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

// MARK: - GlassBadgeContainer
/// A stable glass wrapper for live-updating chip content.
///
/// Places the glass layer in a `.background {}` block so SwiftUI evaluates
/// it independently from the foreground content — the `CABackdropLayer`
/// never re-composites on timer ticks. Only the inner text/sparkline diffs.
///
/// Shape: `RoundedRectangle(cornerRadius: RBRadius.small)` — matches the
/// settings and quit button shape language in `PanelHeaderView`.
///
/// ❌ Do NOT use Capsule — use RoundedRectangle to match toolbar button shape.
/// ❌ Do NOT use `.tint()` on glassEffect — renders too aggressively.
struct GlassBadgeContainer<Content: View>: View {
    /// The semantic tint colour for the badge stroke (danger / warning / primary).
    let labelColor: Color
    /// The live-updating chip content rendered in the foreground.
    @ViewBuilder let content: () -> Content

    private let shape = RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous)

    /// The body property.
    var body: some View {
        content()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                if #available(macOS 26, *) {
                    shape.glassEffect(.regular, in: shape)
                } else {
                    shape.fill(Color.primary.opacity(0.06))
                }
            }
            .overlay(shape.strokeBorder(labelColor.opacity(0.30), lineWidth: 0.5))
    }
}

// MARK: - SparklineMetricView
/// A single header metric chip: label + inline sparkline + monospaced value,
/// all in one horizontal row -- matching the reference compact header design.
///
/// Layout: CPU [▄6▄6▄6] 41.1% MEM [▄6▄6▄6] 6.4/16.0GB
///
/// Do NOT restore the VStack layout -- it makes the header ~70pt tall.
struct SparklineMetricView: View {
    /// The label constant.
    let label: String
    /// The value constant.
    let value: String
    /// The history constant.
    let history: [Double]
    /// The currentPct constant.
    let currentPct: Double

    /// The body property.
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

    /// The labelColor property.
    var labelColor: Color {
        if currentPct > 85 { return .rbDanger }
        if currentPct > 60 { return .rbWarning }
        return .primary
    }
}

// MARK: - DiskPillBadge
/// Compact pill showing disk FREE percentage.
///
/// Color thresholds (based on free space, not used):
/// - `freePct < 15` → `rbDanger`  (disk nearly full)
/// - `freePct < 40` → `rbWarning` (disk getting full)
/// - `freePct >= 40` → `rbSuccess` (plenty of space)
struct DiskPillBadge: View {
    /// The freePct constant.
    let freePct: Double

    private let shape = RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous)

    /// The body property.
    var body: some View {
        Text(String(format: "%.0f%% free", freePct))
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(pillColor)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                if #available(macOS 26, *) {
                    shape.glassEffect(.regular, in: shape)
                } else {
                    shape.fill(Color.primary.opacity(0.06))
                }
            }
            .overlay(shape.strokeBorder(pillColor.opacity(0.30), lineWidth: 0.5))
            .fixedSize()
    }

    /// The pillColor property.
    private var pillColor: Color {
        if freePct < 15 { return .rbDanger }
        if freePct < 40 { return .rbWarning }
        return .rbSuccess
    }
}

// MARK: - HeaderStatsBar
// Compact single-row stats header: CPU | MEM | DISK [pill] as inline chips.
//
// Accepts an existing SystemStatsViewModel so it shares the sampler
// already running in PopoverMainView — no second timer is created.
/// A value type representing HeaderStatsBar.
struct HeaderStatsBar: View {
    /// The statsVM property.
    @ObservedObject var statsVM: SystemStatsViewModel

    /// The body property.
    var body: some View {
        HStack(spacing: RBSpacing.md) {
            let cpuPct = statsVM.stats.cpuPct
            GlassBadgeContainer(labelColor: chipColor(for: cpuPct)) {
                SparklineMetricView(
                    label: "CPU",
                    value: String(format: "%.1f%%", cpuPct),
                    history: statsVM.cpuHistory.values,
                    currentPct: cpuPct
                )
            }

            Color.secondary.opacity(0.3)
                .frame(width: 1, height: 14)

            let memTotal = statsVM.stats.memTotalGB
            let memUsed = statsVM.stats.memUsedGB
            let memPct = memTotal > 0 ? memUsed / memTotal * 100 : 0.0
            GlassBadgeContainer(labelColor: chipColor(for: memPct)) {
                SparklineMetricView(
                    label: "MEM",
                    value: String(format: "%.1f/%.1fGB", memUsed, memTotal),
                    history: statsVM.memHistory.values,
                    currentPct: memPct
                )
            }

            Color.secondary.opacity(0.3)
                .frame(width: 1, height: 14)

            HStack(spacing: 5) {
                let diskTotal = statsVM.stats.diskTotalGB
                let diskUsed = statsVM.stats.diskUsedGB
                let diskUsedPct = diskTotal > 0 ? diskUsed / diskTotal * 100 : 0.0
                GlassBadgeContainer(labelColor: chipColor(for: diskUsedPct)) {
                    SparklineMetricView(
                        label: "DISK",
                        value: String(format: "%d/%dGB",
                                      Int(statsVM.stats.diskUsedGB.rounded()),
                                      Int(statsVM.stats.diskTotalGB.rounded())),
                        history: statsVM.diskHistory.values,
                        currentPct: diskUsedPct
                    )
                }
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

    /// Returns the semantic badge colour for a given usage percentage.
    /// - Parameter pct: Usage percentage (0–100).
    private func chipColor(for pct: Double) -> Color {
        if pct > 85 { return .rbDanger }
        if pct > 60 { return .rbWarning }
        return .primary
    }
}
