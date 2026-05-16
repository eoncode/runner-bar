import SwiftUI

// MARK: - Design Tokens

extension Color {
    /// Accent blue used for in-progress status indicators and sparklines.
    static let tokenBlue   = Color(red: 0.20, green: 0.60, blue: 1.00)
    /// Accent green used for success indicators.
    static let tokenGreen  = Color(red: 0.20, green: 0.78, blue: 0.35)
    /// Accent red used for failure indicators.
    static let tokenRed    = Color(red: 1.00, green: 0.27, blue: 0.23)
    /// Neutral gray used for dimmed/offline runners.
    static let tokenGray   = Color(red: 0.55, green: 0.55, blue: 0.57)
    /// Accent orange used for queued/warning states.
    static let tokenOrange = Color(red: 1.00, green: 0.58, blue: 0.00)
}

// MARK: - SectionHeaderLabel

/// Bold section-header label used to divide the popover into logical groups.
struct SectionHeaderLabel: View {
    /// The text displayed as the section header.
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 8).padding(.bottom, 2)
    }
}

// MARK: - StatusBadge

/// Pill-shaped coloured badge showing a short status label.
struct StatusBadge: View {
    /// The short uppercase text displayed inside the badge.
    let label: String
    /// Background tint colour for the badge.
    let color: Color
    var body: some View {
        Text(label)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.15))
            )
            .fixedSize()
    }
}

// MARK: - JobProgressBarView

/// Thin horizontal progress bar reflecting a workflow run’s completion fraction.
struct JobProgressBarView: View {
    /// Completion fraction in the range 0.0–1.0.
    let progress: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.secondary.opacity(0.15))
                Rectangle()
                    .fill(Color.tokenBlue)
                    .frame(width: geo.size.width * CGFloat(min(max(progress, 0), 1)))
            }
        }
        .frame(height: 2)
        .cornerRadius(1)
    }
}

// MARK: - SparklineView

/// Renders a filled sparkline chart from an array of 0.0–1.0 values.
struct SparklineView: View {
    /// Normalised data points (0.0–1.0) ordered oldest-to-newest.
    let values: [Double]
    /// Stroke and fill tint colour.
    let color: Color
    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let linePath = buildLinePath(size: size)
            let fillPath = buildFillPath(linePath: linePath, size: size)
            ZStack {
                fillPath.fill(color.opacity(0.15))
                linePath.stroke(color, lineWidth: 1)
            }
        }
    }

    private func buildLinePath(size: CGSize) -> Path {
        Path { path in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(values.count - 1)
            for (idx, val) in values.enumerated() {
                let x = CGFloat(idx) * step
                let y = size.height * (1 - CGFloat(val))
                let point = CGPoint(x: x, y: y)
                if idx == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }

    private func buildFillPath(linePath: Path, size: CGSize) -> Path {
        var fill = linePath
        fill.addLine(to: CGPoint(x: size.width, y: size.height))
        fill.addLine(to: CGPoint(x: 0, y: size.height))
        fill.closeSubpath()
        return fill
    }
}

// MARK: - StatusDonut

/// Circular donut progress indicator for workflow run status.
struct StatusDonut: View {
    /// The visual state the donut should reflect.
    enum State {
        /// An in-progress run with a known completion fraction.
        case inProgress(Double)
        /// A successfully completed run.
        case success
        /// A failed or cancelled run.
        case failed
    }
    /// The current display state.
    let state: State

    var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: 2.5)
                .frame(width: 14, height: 14)
            Circle()
                .trim(from: 0, to: trimAmount)
                .stroke(fillColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(-90))
        }
    }

    private var trimAmount: CGFloat {
        switch state {
        case .inProgress(let f): return CGFloat(max(0.05, min(f, 1.0)))
        case .success, .failed:  return 1.0
        }
    }

    private var fillColor: Color {
        switch state {
        case .inProgress: return .tokenBlue
        case .success:    return .tokenGreen
        case .failed:     return .tokenRed
        }
    }

    private var trackColor: Color {
        switch state {
        case .inProgress: return .tokenBlue.opacity(0.2)
        case .success:    return .tokenGreen.opacity(0.2)
        case .failed:     return .tokenRed.opacity(0.2)
        }
    }
}

// MARK: - PopoverHeaderView

/// The system-stats header shown at the top of the main popover.
/// Displays CPU / memory / disk sparklines, stat chips, and the toolbar buttons.
struct PopoverHeaderView: View {
    /// Callback fired when the user taps the settings gear icon.
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
                        .help("Settings")
                        Button(action: { NSApplication.shared.terminate(nil) }, label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                        })
                        .buttonStyle(.plain)
                        .help("Quit RunnerBar")
                    }
                }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
        }
    }

    private func statChip(label: String, value: String, pct: Double, history: [Double]) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 28, alignment: .leading)
            SparklineView(values: history, color: usageColor(pct: pct))
                .frame(width: 48, height: 14)
            Text(value)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(usageColor(pct: pct))
                .frame(width: 36, alignment: .trailing)
        }
    }

    private func usageColor(pct: Double) -> Color {
        if pct > 85 { return .tokenRed }
        if pct > 60 { return .tokenOrange }
        return .tokenGreen
    }
}

// MARK: - RunnerTypeIcon

/// Small icon indicating whether a runner is local or GitHub-hosted.
struct RunnerTypeIcon: View {
    /// When `true` the runner is locally registered; when `false` it is GitHub-hosted.
    let isLocal: Bool
    var body: some View {
        Image(systemName: isLocal ? "desktopcomputer" : "cloud")
            .font(.system(size: 9))
            .foregroundColor(.secondary)
            .help(isLocal ? "Local runner" : "GitHub-hosted runner")
    }
}

// MARK: - PopoverLocalRunnerRow

/// A single row in the local-runners section of the popover.
struct PopoverLocalRunnerRow: View {
    /// The runner model to display.
    let runner: Runner
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(runner.isBusy ? Color.tokenGreen : Color.tokenGray)
                .frame(width: 7, height: 7)
            Text(runner.name)
                .font(.system(size: 12))
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
            Spacer()
            runnerList(runner.metrics.sorted { $0.cpu > $1.cpu }.prefix(3).map { $0 })
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    private func runnerList(_ busy: [Runner]) -> some View {
        HStack(spacing: 4) {
            if runner.metrics.isEmpty {
                Text(runner.isBusy ? "busy" : "idle")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                ForEach(runner.metrics.prefix(2), id: \.cpu) { m in
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
