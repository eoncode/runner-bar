import SwiftUI

// MARK: - SystemStatChip

/// A single metric chip with label, value, and a sparkline history bar.
struct SystemStatChip: View {
    let label: String
    let value: String
    let pct: Double
    let history: [Double]

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(DesignTokens.Font.statLabel)
                .foregroundColor(DesignTokens.Color.labelSecondary)
            SparklineView(values: history, highlight: pct)
                .frame(width: DesignTokens.Layout.sparklineWidth,
                       height: DesignTokens.Layout.sparklineHeight)
            Text(value)
                .font(DesignTokens.Font.statValue)
                .foregroundColor(.primary)
                .frame(minWidth: 30, alignment: .trailing)
        }
    }
}

// MARK: - SparklineView

/// A tiny multi-bar sparkline for CPU/MEM/DISK history.
/// Uses Canvas instead of GeometryReader to avoid zero-width collapse
/// when placed inside an HStack that contains a Spacer().
struct SparklineView: View {
    let values: [Double]
    let highlight: Double

    private var color: Color {
        DesignTokens.Color.statColor(for: highlight)
    }

    var body: some View {
        Canvas { ctx, size in
            let samples = values.suffix(10)
            guard !samples.isEmpty else { return }
            let count = samples.count
            let gap: CGFloat = 1
            let barW = max(1, (size.width - CGFloat(count - 1) * gap) / CGFloat(count))
            for (i, v) in samples.enumerated() {
                let fraction = CGFloat(min(max(v, 0), 100)) / 100
                let barH = max(1, size.height * fraction)
                let x = CGFloat(i) * (barW + gap)
                let y = size.height - barH
                let rect = CGRect(x: x, y: y, width: barW, height: barH)
                ctx.fill(
                    Path(roundedRect: rect, cornerRadius: 1),
                    with: .color(color.opacity(0.75))
                )
            }
        }
    }
}

// MARK: - ActionStatusDonut

/// A small circular status dot for an `ActionGroup`.
struct ActionStatusDonut: View {
    let conclusion: String?
    let status: GroupStatus?
    let size: CGFloat

    private var color: Color {
        switch conclusion {
        case "success":              return DesignTokens.Color.statusGreen
        case "failure":              return DesignTokens.Color.statusRed
        case "cancelled", "skipped": return DesignTokens.Color.labelTertiary
        default:
            switch status {
            case .inProgress: return DesignTokens.Color.statusBlue
            case .queued:     return DesignTokens.Color.statusOrange
            default:          return DesignTokens.Color.labelTertiary
            }
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size * 0.45, height: size * 0.45)
    }
}

// MARK: - JobProgressBarView

/// A thin horizontal progress bar for a job whose progress fraction is known.
struct JobProgressBarView: View {
    let progress: Double?

    private var displayProgress: Double? {
        guard let p = progress, p > 0 else { return nil }
        return min(p, 1.0)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                if let fraction = displayProgress {
                    Rectangle()
                        .fill(DesignTokens.Color.statusBlue)
                        .frame(width: geo.size.width * CGFloat(fraction))
                }
            }
            .clipShape(Capsule())
        }
    }
}

// MARK: - LogCopyButton

/// A button that fetches log text asynchronously and copies it to the clipboard.
struct LogCopyButton: View {
    var fetch: (@escaping (String?) -> Void) -> Void
    var isDisabled: Bool = false

    @State private var copied = false

    var body: some View {
        Button(action: doCopy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .foregroundColor(copied ? DesignTokens.Color.statusGreen : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help("Copy log to clipboard")
    }

    private func doCopy() {
        fetch { text in
            DispatchQueue.main.async {
                if let text {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
        }
    }
}

// MARK: - PopoverHeaderView

/// The system-stats header shown at the top of the main popover.
struct PopoverHeaderView: View {
    let onSelectSettings: () -> Void
    @ObservedObject private var vm = SystemStatsViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    statChip(label: "CPU",  value: String(format: "%.0f%%", vm.stats.cpuPct),
                             pct: vm.stats.cpuPct, history: vm.cpuHistory)
                    statChip(label: "MEM",  value: String(format: "%.1fG", vm.stats.memUsedGB),
                             pct: vm.stats.memTotalGB > 0 ? (vm.stats.memUsedGB / vm.stats.memTotalGB) * 100 : 0,
                             history: vm.memHistory)
                    statChip(label: "DISK", value: String(format: "%.0f%%",
                                                         vm.stats.diskTotalGB > 0
                                                         ? (vm.stats.diskUsedGB / vm.stats.diskTotalGB) * 100 : 0),
                             pct: vm.stats.diskTotalGB > 0 ? (vm.stats.diskUsedGB / vm.stats.diskTotalGB) * 100 : 0,
                             history: vm.diskHistory)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 6) {
                        Button(action: onSelectSettings) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 13)).foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
        }
    }

    private func statChip(label: String, value: String, pct: Double, history: [Double]) -> some View {
        SystemStatChip(label: label, value: value, pct: pct, history: history)
    }
}

// MARK: - PopoverLocalRunnerRow

/// A single row in the local-runners section of the popover.
struct PopoverLocalRunnerRow: View {
    let runner: Runner
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(runner.busy ? DesignTokens.Color.statusGreen : DesignTokens.Color.labelTertiary)
                .frame(width: 7, height: 7)
            Text(runner.name)
                .font(.system(size: 12))
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
            Spacer()
            runnerList(runner.metrics.map { [$0] } ?? [])
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    private func runnerList(_ busy: [RunnerMetrics]) -> some View {
        HStack(spacing: 4) {
            if runner.metrics == nil {
                Text(runner.busy ? "busy" : "idle")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                ForEach(runner.metrics.map { [$0] } ?? [], id: \.cpu) { m in
                    metricPill(label: "CPU", value: String(format: "%.0f%%", m.cpu))
                    metricPill(label: "MEM", value: String(format: "%.0f%%", m.mem))
                }
            }
        }
    }

    private func metricPill(label: String, value: String) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.1)))
    }
}
