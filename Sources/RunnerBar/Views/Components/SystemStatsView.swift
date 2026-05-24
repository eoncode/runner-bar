// SystemStatsView.swift
// RunnerBar
import SwiftUI

// MARK: - SystemStatsView
/// Horizontal strip of stat tiles showing live CPU, memory, disk, and network metrics.
/// Each tile uses GlassCard as its container surface.
struct SystemStatsView: View {
    @ObservedObject var vm: SystemStatsViewModel

    var body: some View {
        HStack(spacing: 6) {
            statTile(label: "CPU", value: vm.cpuLabel, chart: vm.cpuHistory)
            statTile(label: "MEM", value: vm.memLabel, chart: vm.memHistory)
            statTile(label: "DISK", value: vm.diskLabel, chart: nil)
            statTile(label: "NET", value: vm.netLabel, chart: nil)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func statTile(label: String, value: String, chart: [Double]?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(.primary)
                .lineLimit(1)
            if let history = chart {
                SparklineView(values: history)
                    .frame(height: 16)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .glassCard(cornerRadius: 6)
        .frame(minWidth: 44)
    }
}
