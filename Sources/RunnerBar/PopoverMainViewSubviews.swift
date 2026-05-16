// swiftlint:disable file_length
import AppKit
import SwiftUI

// MARK: - Design Tokens

private extension Color {
    static let tokenGreen  = Color(red: 0.27, green: 0.80, blue: 0.39)
    static let tokenRed    = Color(red: 0.95, green: 0.33, blue: 0.33)
    static let tokenBlue   = Color(red: 0.25, green: 0.60, blue: 1.00)
    static let tokenYellow = Color(red: 0.98, green: 0.73, blue: 0.22)
    static let cardBorder  = Color.white.opacity(0.08)
    static let cardFill    = Color.white.opacity(0.05)
    static let pillFill    = Color.white.opacity(0.10)
    static let pillBorder  = Color.white.opacity(0.14)
}

// MARK: - SectionHeaderLabel

/// Uppercased section header label used throughout the popover.
struct SectionHeaderLabel: View {
    /// The text to display (will be uppercased).
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

// MARK: - StatusBadge

/// Capsule-shaped status badge with coloured text and tinted background.
struct StatusBadge: View {
    /// The text label displayed inside the badge.
    let label: String
    /// The foreground and tint colour for the badge.
    let color: Color

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 0.5))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - JobProgressBarView

/// Horizontal progress bar that fills proportionally to `fraction`.
struct JobProgressBarView: View {
    /// Fill fraction in the range 0–1.
    let fraction: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.secondary.opacity(0.15))
                Rectangle()
                    .fill(Color.tokenBlue.opacity(0.8))
                    .frame(width: geo.size.width * max(0, min(1, fraction)))
            }
        }
    }
}

// MARK: - SparklineView

/// Mini sparkline rendered via Canvas from a normalised sample array.
struct SparklineView: View {
    /// Normalised sample values (0–1) ordered oldest → newest.
    let samples: [Double]
    /// Stroke and fill tint colour.
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            guard samples.count >= 2 else { return }
            let line = buildLinePath(size: size)
            let fill = buildFillPath(linePath: line, size: size)
            ctx.fill(fill, with: .color(color.opacity(0.18)))
            ctx.stroke(line, with: .color(color.opacity(0.85)), lineWidth: 1)
        }
    }

    private func buildLinePath(size: CGSize) -> Path {
        let step = size.width / CGFloat(samples.count - 1)
        var path = Path()
        for (idx, val) in samples.enumerated() {
            let point = CGPoint(
                x: CGFloat(idx) * step,
                y: size.height - CGFloat(max(0, min(1, val))) * size.height
            )
            idx == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }

    private func buildFillPath(linePath: Path, size: CGSize) -> Path {
        let lastX = size.width
        var fill = linePath
        fill.addLine(to: CGPoint(x: lastX, y: size.height))
        fill.addLine(to: CGPoint(x: 0, y: size.height))
        fill.closeSubpath()
        return fill
    }
}

// MARK: - StatusDonut

/// Phase 4: 3-state donut — solid fill+icon for success/failed, animated arc for in-progress.
private struct StatusDonut: View {
    /// The visual state the donut should render.
    enum State {
        /// Workflow completed successfully.
        case success
        /// Workflow failed.
        case failed
        /// Workflow is in progress with given completion fraction (0–1).
        case inProgress(Double)
    }

    /// Current donut state.
    let state: State
    @SwiftUI.State private var rotation: Double = 0

    var body: some View {
        ZStack {
            switch state {
            case .success:
                Circle().fill(Color.tokenGreen)
                    .frame(width: 20, height: 20)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.black.opacity(0.85))
            case .failed:
                Circle().fill(Color.tokenRed)
                    .frame(width: 20, height: 20)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.black.opacity(0.85))
            case .inProgress(let pct):
                Circle().stroke(Color.tokenBlue.opacity(0.2), lineWidth: 2.5)
                    .frame(width: 20, height: 20)
                Circle()
                    .trim(from: 0, to: max(0.06, CGFloat(pct)))
                    .stroke(Color.tokenBlue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 20, height: 20)
                    .rotationEffect(.degrees(-90 + rotation))
                    .onAppear {
                        withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                            rotation = 360
                        }
                    }
            }
        }
        .frame(width: 20, height: 20)
    }
}

// MARK: - PopoverHeaderView

/// Top header bar showing live system stats and action buttons.
struct PopoverHeaderView: View {
    /// Latest system stats snapshot.
    let stats: SystemStats
    /// Whether a GitHub token is present.
    let isAuthenticated: Bool
    /// Called when the user taps the settings gear.
    let onSelectSettings: () -> Void
    /// Called when the user taps Sign In.
    let onSignIn: () -> Void
    /// Historical CPU samples (normalised 0–1) for the sparkline.
    var cpuHistory: [Double] = []
    /// Historical memory samples (normalised 0–1) for the sparkline.
    var memHistory: [Double] = []
    /// Historical disk samples (normalised 0–1) for the sparkline.
    var diskHistory: [Double] = []

    var body: some View {
        HStack(spacing: 6) {
            systemStatsBadge
            Spacer()
            if !isAuthenticated {
                Button(action: onSignIn) {
                    HStack(spacing: 4) {
                        Circle().fill(Color.orange).frame(width: 7, height: 7)
                        Text("Sign in").font(.caption2).foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Sign in with GitHub")
            }
            Button(action: onSelectSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13)).foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
            Button(action: { NSApplication.shared.terminate(nil) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit RunnerBar")
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
    }

    private var systemStatsBadge: some View {
        HStack(spacing: 10) {
            statChip(
                label: "CPU",
                value: String(format: "%.1f%%", stats.cpuPct),
                pct: stats.cpuPct,
                history: cpuHistory
            )
            divider
            statChip(
                label: "MEM",
                value: String(format: "%.1f/%.1fGB", stats.memUsedGB, stats.memTotalGB),
                pct: stats.memTotalGB > 0 ? (stats.memUsedGB / stats.memTotalGB) * 100 : 0,
                history: memHistory
            )
            divider
            diskChip
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 14)
    }

    private var diskChip: some View {
        let total   = stats.diskTotalGB
        let used    = stats.diskUsedGB
        let free    = max(0, total - used)
        let usedPct = total > 0 ? (used / total) * 100 : 0
        let freePct = total > 0 ? Int((free / total * 100).rounded()) : 0
        let value   = String(format: "%d/%dGB", Int(used.rounded()), Int(total.rounded()))
        let color   = usageColor(pct: usedPct)
        return HStack(spacing: 3) {
            Text("DISK")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary).lineLimit(1)
            if diskHistory.count >= 2 {
                SparklineView(samples: diskHistory, color: color)
                    .frame(width: 28, height: 12)
            }
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(color).lineLimit(1)
            Text("FREE \(freePct)%")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(color.opacity(0.15)))
                .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 0.5))
                .lineLimit(1)
        }
    }

    private func statChip(label: String, value: String, pct: Double, history: [Double]) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary).lineLimit(1)
            if history.count >= 2 {
                SparklineView(samples: history, color: usageColor(pct: pct))
                    .frame(width: 28, height: 12)
            }
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(usageColor(pct: pct)).lineLimit(1)
        }
    }

    private func usageColor(pct: Double) -> Color {
        if pct > 85 { return .tokenRed }
        if pct > 60 { return .tokenYellow }
        return .tokenGreen
    }
}

// MARK: - RunnerTypeIcon

/// Small icon indicating local (desktop) vs cloud runner.
private struct RunnerTypeIcon: View {
    /// `true` = local runner, `false` = cloud runner, `nil` = unknown.
    let isLocal: Bool?

    var body: some View {
        if let local = isLocal {
            Image(systemName: local ? "desktopcomputer" : "cloud")
                .font(.system(size: 9)).foregroundColor(.secondary)
                .accessibilityLabel(local ? "Local runner" : "Cloud runner")
                .fixedSize()
        }
    }
}

// MARK: - PopoverLocalRunnerRow

/// Phase 3: each busy runner wrapped in a bordered card with pill CPU/MEM stats.
struct PopoverLocalRunnerRow: View {
    /// All runners; only busy ones are rendered.
    let runners: [Runner]

    var body: some View {
        let busy = runners.filter { $0.busy }
        if !busy.isEmpty {
            runnerList(busy)
        }
    }

    @ViewBuilder
    private func runnerList(_ busy: [Runner]) -> some View {
        VStack(spacing: 4) {
            ForEach(busy.prefix(3)) { runner in
                HStack(spacing: 8) {
                    Circle().fill(Color.tokenYellow).frame(width: 8, height: 8)
                    Text(runner.name)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.primary).lineLimit(1)
                    Spacer()
                    if let metrics = runner.metrics {
                        metricPill(label: "CPU", value: String(format: "%.1f%%", metrics.cpu))
                        metricPill(label: "MEM", value: String(format: "%.1f%%", metrics.mem))
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.cardFill))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.cardBorder, lineWidth: 1))
            }
            if busy.count > 3 {
                Text("+ \(busy.count - 3) more…")
                    .font(.caption2).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        Divider()
    }

    private func metricPill(label: String, value: String) -> some View {
        HStack(spacing: 2) {
            Text(label + ":").font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
            Text(value).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.primary)
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.pillFill))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.pillBorder, lineWidth: 0.5))
    }
}

// MARK: - ActionRowView

/// Phase 4: left-side vertical half-pill indicator (color = status) + status donut.
struct ActionRowView: View {
    /// The action group this row represents.
    let group: ActionGroup
    /// Monotonically-increasing tick used to force re-render during polling.
    let tick: Int
    /// Called when the user taps the row to drill into the action detail.
    let onSelect: () -> Void
    /// Optional callback when the user taps an inline job row.
    var onSelectJob: ((ActiveJob, ActionGroup) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                indicatorBar
                Button(action: onSelect) { rowContent }.buttonStyle(.plain)
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundColor(.secondary).padding(.trailing, 12)
            }
            if group.groupStatus == .inProgress {
                InlineJobRowsView(group: group, tick: tick, onSelectJob: onSelectJob)
                    .padding(.leading, 6)
            }
        }
    }

    private var indicatorBar: some View {
        Capsule()
            .fill(indicatorColor)
            .frame(width: 3)
            .padding(.vertical, 6)
            .padding(.leading, 6)
            .padding(.trailing, 4)
    }

    private var rowContent: some View {
        _ = tick // ⚠️ TICK CONTRACT — DO NOT REMOVE
        return HStack(spacing: 6) {
            statusDonut
            RunnerTypeIcon(isLocal: group.isLocalGroup)
            Text(group.label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(group.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(group.isDimmed ? .secondary : .primary)
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
            Spacer()
            metaTrailing
        }
        .padding(.leading, 4).padding(.trailing, 4).padding(.vertical, 6)
        .background(rowBackground)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if group.groupStatus == .inProgress {
            RoundedRectangle(cornerRadius: 0).fill(Color.tokenBlue.opacity(0.05))
        } else if group.groupStatus == .completed {
            if group.conclusion == "success" {
                RoundedRectangle(cornerRadius: 0).fill(Color.tokenGreen.opacity(0.04))
            } else {
                RoundedRectangle(cornerRadius: 0).fill(Color.tokenRed.opacity(0.04))
            }
        }
    }

    @ViewBuilder
    private var statusDonut: some View {
        switch group.groupStatus {
        case .inProgress:
            // ⚠️ progressFraction is Double? — always coalesce to 0, do NOT remove ?? 0
            StatusDonut(state: .inProgress(group.progressFraction ?? 0))
        case .queued:
            StatusDonut(state: .inProgress(0.0))
        case .completed:
            if group.conclusion == "success" {
                StatusDonut(state: .success)
            } else {
                StatusDonut(state: .failed)
            }
        }
    }

    @ViewBuilder
    private var metaTrailing: some View {
        if let start = group.firstJobStartedAt {
            Text(RelativeTimeFormatter.string(from: start))
                .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        }
        Text(group.jobProgress)
            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        Text(group.elapsed)
            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        statusChip
    }

    @ViewBuilder
    private var statusChip: some View {
        switch group.groupStatus {
        case .inProgress:
            StatusBadge(label: "IN PROGRESS", color: .tokenBlue)
        case .queued:
            StatusBadge(label: "QUEUED", color: .tokenBlue)
        case .completed:
            StatusBadge(
                label: group.conclusion == "success" ? "SUCCESS" : "FAILED",
                color: group.conclusion == "success" ? .tokenGreen : .tokenRed
            )
        }
    }

    private var indicatorColor: Color {
        switch group.groupStatus {
        case .inProgress: return .tokenBlue
        case .queued:     return .tokenBlue.opacity(0.6)
        case .completed:
            if group.isDimmed { return .gray.opacity(0.3) }
            return group.conclusion == "success" ? .tokenGreen : .tokenRed
        }
    }
}

// MARK: - InlineJobRowsView

/// Passive ↳ job rows beneath in-progress action groups.
///
/// ⚠️ REGRESSION GUARD (#377):
/// cap += 4 on button tap mutates @State while the popover is visible.
/// isPopoverOpen is read from @EnvironmentObject PopoverOpenState — NOT from a plain Bool prop.
/// ❌ NEVER add `var isPopoverOpen: Bool` prop back.
/// ❌ NEVER mutate cap while popoverOpenState.isOpen == true.
/// ❌ NEVER remove .disabled(popoverOpenState.isOpen) from the expand button.
/// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
/// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
/// is major major major.
struct InlineJobRowsView: View {
    /// The action group whose in-progress jobs are shown.
    let group: ActionGroup
    /// Tick counter used to force re-render on each poll cycle.
    let tick: Int
    /// Optional callback fired when the user taps a job row.
    var onSelectJob: ((ActiveJob, ActionGroup) -> Void)?
    @EnvironmentObject private var popoverOpenState: PopoverOpenState
    @State private var cap: Int = 4

    private var activeJobs: [ActiveJob] {
        group.jobs.filter { $0.status == "in_progress" }
    }

    var body: some View {
        ForEach(activeJobs.prefix(cap)) { job in
            if let onSelectJob {
                Button(action: { onSelectJob(job, group) }) { jobRow(job) }.buttonStyle(.plain)
            } else {
                jobRow(job)
            }
        }
        if activeJobs.count > cap {
            Button(action: {
                if !popoverOpenState.isOpen { cap += 4 }
            }) {
                Text("+ \(activeJobs.count - cap) more jobs…")
                    .font(.caption2).foregroundColor(.accentColor)
                    .padding(.leading, 24).padding(.trailing, 12).padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .disabled(popoverOpenState.isOpen)
        }
    }

    private func jobRow(_ job: ActiveJob) -> some View {
        _ = tick // ⚠️ TICK CONTRACT — DO NOT REMOVE
        let currentStep = job.steps.first(where: { $0.status == "in_progress" })
        let stepName = currentStep.map(\.name).flatMap { $0.isEmpty ? nil : $0 }
        let done  = job.steps.filter { $0.conclusion != nil }.count
        let total = job.steps.count
        return HStack(spacing: 6) {
            Text("↳").font(.caption).foregroundColor(.secondary).frame(width: 16, alignment: .trailing)
            PieProgressDot(progress: job.progressFraction, color: jobDotColor(for: job), size: 7)
            Group {
                if let name = stepName {
                    Text(job.name + " · " + name)
                } else {
                    Text(job.name)
                }
            }
            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
            .lineLimit(1).truncationMode(.tail).layoutPriority(1)
            Spacer()
            if total > 0 {
                Text("\(done)/\(total)")
                    .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
            if total > 0 {
                JobProgressBarView(fraction: CGFloat(done) / CGFloat(total))
                    .frame(width: 80, height: 3)
                    .cornerRadius(2)
            }
            Text(job.elapsed)
                .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            if onSelectJob != nil {
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.leading, 24).padding(.trailing, 12).padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func jobDotColor(for job: ActiveJob) -> Color {
        switch job.status {
        case "in_progress": return .tokenBlue
        case "queued":      return .tokenBlue.opacity(0.5)
        default:            return job.conclusion == "success" ? .tokenGreen : (job.isDimmed ? .gray : .tokenRed)
        }
    }
}
