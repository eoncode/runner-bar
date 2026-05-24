// SystemStatsView.swift
// RunnerBar
import RunnerBarCore
import SwiftUI

// MARK: - SparklineMetricView
/// A single header metric chip: label + inline sparkline + monospaced value,
/// all in one horizontal row -- matching the reference compact header design.
///
/// Layout: CPU [▄6▄6▄6] 41.1% MEM [▄6▄6▄6] 6.4/16.0GB
///          ^      ^        ^    ^      ^        ^
///        9pt label  40x14pt sparkline  10pt mono value
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
///   freePct < 15 → rbDanger  (red)
///   freePct < 40 → rbWarning (orange)
///   else         → rbSuccess (green)
///
/// Always renders at its intrinsic size -- never truncates.
struct DiskPillBadge: View {
    // Percentage of disk space that is FREE (0-100).
    /// The freePct constant.
    let freePct: Double

    /// The body property.
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
// Layout: CPU [spark] 41.1% | MEM [spark] 7.0/16.0GB | DISK [spark] 394/460GB [13% free] → ⚙ ✕
//
// The DiskPillBadge sits immediately after the DISK SparklineMetricView,
// before the Spacer, so it stays adjacent to the disk graph.
//
// Accepts an existing SystemStatsViewModel so it shares the sampler
// already running in PopoverMainView -- no second timer is created.
/// A value type representing HeaderStatsBar.
struct HeaderStatsBar: View {
    /// The statsVM property.
    @ObservedObject var statsVM: SystemStatsViewModel

    /// The body property.
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
