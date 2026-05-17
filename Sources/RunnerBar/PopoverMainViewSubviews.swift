import AppKit
import SwiftUI

// MARK: - SectionHeaderLabel
/// Uppercase section header label used throughout the popover (e.g. "ACTIONS").
struct SectionHeaderLabel: View {
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
/// A pill-shaped label used to display job status/conclusion.
struct StatusBadge: View {
    let label: String
    let color: Color
    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - JobProgressBarView
/// A thin horizontal progress bar for in-progress job rows.
struct JobProgressBarView: View {
    let fraction: CGFloat
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(DesignTokens.Color.statusBlue.opacity(0.7))
                    .frame(width: geo.size.width * max(0, min(1, fraction)))
            }
        }
    }
}

// MARK: - SparklineView
/// Tiny inline sparkline drawn from a history of 0.0–1.0 samples.
/// Uses Canvas (not GeometryReader) to avoid zero-width collapse inside HStack/Spacer.
/// Per #420 Phase 2: this is the sole visual graph element — no block-bar text prefix.
struct SparklineView: View {
    /// Values in chronological order, each 0.0–1.0.
    let samples: [Double]
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            guard samples.count >= 2 else { return }
            let w = size.width
            let h = size.height
            let step = w / CGFloat(samples.count - 1)

            var path = Path()
            for (idx, v) in samples.enumerated() {
                let x = CGFloat(idx) * step
                let y = h - CGFloat(max(0, min(1, v))) * h
                if idx == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else       { path.addLine(to: CGPoint(x: x, y: y)) }
            }

            // Fill area under line
            var fill = path
            let lastX = CGFloat(samples.count - 1) * step
            fill.addLine(to: CGPoint(x: lastX, y: h))
            fill.addLine(to: CGPoint(x: 0, y: h))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(color.opacity(0.18)))

            // Draw line on top
            ctx.stroke(path, with: .color(color.opacity(0.85)), lineWidth: 1)
        }
    }
}

// MARK: - PopoverHeaderView
/// Header row: system stats left (sparkline chips), settings + close right.
/// Per #420 Phase 2: CPU/MEM/DISK shown as [label] [sparkline] [value] chips.
/// ⚠️ Auth green dot removed — auth status lives in Settings > Account only (#10).
struct PopoverHeaderView: View {
    let stats: SystemStats
    let isAuthenticated: Bool
    let onSelectSettings: () -> Void
    let onSignIn: () -> Void
    /// CPU utilisation history (0.0–1.0 per sample) for sparkline display.
    var cpuHistory: [Double] = []
    /// Memory utilisation history (0.0–1.0 per sample) for sparkline display.
    var memHistory: [Double] = []
    /// Disk utilisation history (0.0–1.0 per sample) for sparkline display.
    var diskHistory: [Double] = []

    var body: some View {
        HStack(spacing: 6) {
            systemStatsBadge
            Spacer()
            if !isAuthenticated {
                Button(
                    action: onSignIn,
                    label: {
                        HStack(spacing: 4) {
                            Circle().fill(Color.orange).frame(width: 7, height: 7)
                            Text("Sign in")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                )
                .buttonStyle(.plain)
                .help("Sign in with GitHub")
            }
            Button(
                action: onSelectSettings,
                label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13)).foregroundColor(.secondary)
                }
            )
            .buttonStyle(.plain).help("Settings")
            Button(
                action: { NSApplication.shared.terminate(nil) },
                label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                }
            )
            .buttonStyle(.plain).help("Quit RunnerBar")
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
    }

    /// CPU / MEM / DISK chips: [label] [sparkline] [value]
    /// ⚠️ LOAD-BEARING: `.lineLimit(1)` prevents multi-line wrapping that corrupts panel height (ref #52 #54).
    private var systemStatsBadge: some View {
        HStack(spacing: 8) {
            statChip(
                label: "CPU",
                value: String(format: "%.1f%%", stats.cpuPct),
                pct: stats.cpuPct,
                history: cpuHistory
            )
            statChip(
                label: "MEM",
                value: String(format: "%.1f/%.1fGB", stats.memUsedGB, stats.memTotalGB),
                pct: stats.memTotalGB > 0 ? (stats.memUsedGB / stats.memTotalGB) * 100 : 0,
                history: memHistory
            )
            diskChip
        }
    }

    private var diskChip: some View {
        let total   = stats.diskTotalGB
        let used    = stats.diskUsedGB
        let free    = max(0, total - used)
        let pct     = total > 0 ? (used / total) * 100 : 0
        let freePct = total > 0 ? (free / total) * 100 : 0
        let diskColor = DesignTokens.Color.statColor(for: pct)
        let pillLabel = String(format: "%d%%", Int(freePct.rounded()))
        return HStack(spacing: 3) {
            Text("DISK")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
            if diskHistory.count >= 2 {
                SparklineView(samples: diskHistory, color: diskColor)
                    .frame(width: 28, height: 12)
            }
            Text(String(format: "%d/%dGB", Int(used.rounded()), Int(total.rounded())))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(diskColor)
                .lineLimit(1)
            // Pill badge showing free percentage
            Text(pillLabel)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(diskColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(
                    Capsule()
                        .fill(diskColor.opacity(0.14))
                        .overlay(Capsule().strokeBorder(diskColor.opacity(0.3), lineWidth: 0.5))
                )
                .lineLimit(1)
        }
    }

    private func statChip(label: String, value: String, pct: Double, history: [Double]) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
            if history.count >= 2 {
                SparklineView(samples: history, color: usageColor(pct: pct))
                    .frame(width: 28, height: 12)
            }
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(usageColor(pct: pct))
                .lineLimit(1)
        }
    }

    private func usageColor(pct: Double) -> Color {
        DesignTokens.Color.statColor(for: pct)
    }
}

// MARK: - RunnerTypeIcon
private struct RunnerTypeIcon: View {
    let isLocal: Bool?
    var body: some View {
        if let local = isLocal {
            Image(systemName: local ? "desktopcomputer" : "cloud")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .accessibilityLabel(local ? "Local runner" : "Cloud runner")
                .fixedSize()
        }
    }
}

// MARK: - MetricPill
/// A small Capsule pill badge showing a CPU or MEM metric label+value.
private struct MetricPill: View {
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.primary.opacity(0.75))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(DesignTokens.Color.pillBg)
                .overlay(Capsule().strokeBorder(DesignTokens.Color.pillBorder, lineWidth: 0.5))
        )
    }
}

// MARK: - PopoverLocalRunnerRow
/// Phase 3: Shows busy local runners as bordered card rows with CPU/MEM pill badges.
struct PopoverLocalRunnerRow: View {
    let runners: [Runner]

    var body: some View {
        let busy = runners.filter { $0.busy }
        if !busy.isEmpty {
            runnerList(busy)
        }
    }

    @ViewBuilder
    private func runnerList(_ busy: [Runner]) -> some View {
        ForEach(busy.prefix(3)) { runner in
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 8, height: 8)
                Text(runner.name)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer()
                if let metrics = runner.metrics {
                    MetricPill(
                        label: "CPU:",
                        value: String(format: "%.1f%%", metrics.cpu)
                    )
                    MetricPill(
                        label: "MEM:",
                        value: String(format: "%.1f%%", metrics.mem)
                    )
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(DesignTokens.Color.labelTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Layout.cardRadius)
                    .fill(Color.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Layout.cardRadius)
                            .strokeBorder(DesignTokens.Color.cardBorder, lineWidth: 1)
                    )
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
        }
        if busy.count > 3 {
            Text("+ \(busy.count - 3) more…")
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 2)
        }
        Divider()
    }
}

// MARK: - ActionRowView
/// Phase 4: Action row with left-side colored indicator bar, StatusDonutView,
/// row tint background, branch pill, and proper status pill badge.
struct ActionRowView: View {
    let group: ActionGroup
    let tick: Int
    let onSelect: () -> Void
    var onSelectJob: ((ActiveJob, ActionGroup) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            rowWithIndicator
            if group.groupStatus == .inProgress {
                InlineJobRowsView(group: group, tick: tick, onSelectJob: onSelectJob)
            }
        }
    }

    // Left-side colored indicator bar + main row content
    private var rowWithIndicator: some View {
        HStack(spacing: 0) {
            // Phase 4: left-side half-pill indicator bar (leading corners rounded, trailing flat)
            UnevenRoundedRectangle(
                topLeadingRadius: DesignTokens.Layout.leftIndicatorWidth,
                bottomLeadingRadius: DesignTokens.Layout.leftIndicatorWidth,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
            .fill(indicatorColor)
            .frame(width: DesignTokens.Layout.leftIndicatorWidth)
            .padding(.vertical, 4)

            Button(action: onSelect, label: { rowContent })
                .buttonStyle(.plain)

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(DesignTokens.Color.labelTertiary)
                .padding(.trailing, 12)
        }
        .background(rowTint)
    }

    private var rowContent: some View {
        // ⚠️ TICK CONTRACT — DO NOT REMOVE.
        // ❌ NEVER remove this line.
        _ = tick
        return HStack(spacing: 6) {
            StatusDonutView(
                status: group.groupStatus,
                conclusion: group.conclusion,
                progress: group.progressFraction
            )
            .frame(width: DesignTokens.Layout.donutSize, height: DesignTokens.Layout.donutSize)

            RunnerTypeIcon(isLocal: group.isLocalGroup)

            Text(group.label)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Text(group.title)
                .font(.system(size: 12))
                .foregroundColor(group.isDimmed ? .secondary : .primary)
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)

            Spacer()
            metaTrailing
        }
        .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 5)
    }

    @ViewBuilder
    private var metaTrailing: some View {
        // Relative time
        if let start = group.firstJobStartedAt {
            Text(RelativeTimeFormatter.string(from: start))
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }

        // Branch pill: 🌿 branchName
        if let branch = group.headBranch, !branch.isEmpty {
            HStack(spacing: 2) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 8))
                Text(branch)
                    .font(.system(size: 9, design: .monospaced))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.06))
                    .overlay(Capsule().strokeBorder(DesignTokens.Color.cardBorder, lineWidth: 0.5))
            )
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }

        // Job progress e.g. 6/10
        Text(group.jobProgress)
            .font(.caption.monospacedDigit())
            .foregroundColor(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)

        // Elapsed time
        Text(group.elapsed)
            .font(.caption.monospacedDigit())
            .foregroundColor(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)

        // Status pill badge
        statusPill
    }

    @ViewBuilder
    private var statusPill: some View {
        switch group.groupStatus {
        case .inProgress:
            StatusBadge(label: "IN PROGRESS", color: DesignTokens.Color.statusBlue)
        case .queued:
            StatusBadge(label: "QUEUED", color: DesignTokens.Color.statusBlue.opacity(0.7))
        case .completed:
            let success = group.conclusion == "success"
            StatusBadge(
                label: success ? "SUCCESS" : "FAILED",
                color: success ? DesignTokens.Color.statusGreen : DesignTokens.Color.statusRed
            )
        }
    }

    private var indicatorColor: Color {
        switch group.groupStatus {
        case .inProgress: return DesignTokens.Color.statusBlue
        case .queued:     return DesignTokens.Color.statusBlue.opacity(0.5)
        case .completed:
            if group.isDimmed { return .gray.opacity(0.4) }
            return group.conclusion == "success"
                ? DesignTokens.Color.statusGreen
                : DesignTokens.Color.statusRed
        }
    }

    private var rowTint: Color {
        switch group.groupStatus {
        case .inProgress: return DesignTokens.Color.tintBlue
        case .queued:     return DesignTokens.Color.tintBlue
        case .completed:
            if group.isDimmed { return .clear }
            return group.conclusion == "success"
                ? DesignTokens.Color.tintGreen
                : DesignTokens.Color.tintRed
        }
    }
}

// MARK: - InlineJobRowsView
/// Phase 5: ↳ inline job rows with spinning 14pt StatusDonutView and step progress bar.
///
/// ⚠️ REGRESSION GUARD (#377):
/// `cap += 4` on button tap mutates @State while the popover is visible.
/// isPopoverOpen is read from @EnvironmentObject PopoverOpenState — NOT from a plain Bool prop.
/// ❌ NEVER add `var isPopoverOpen: Bool` prop back.
/// ❌ NEVER mutate cap while popoverOpenState.isOpen == true.
/// ❌ NEVER remove .disabled(popoverOpenState.isOpen) from the expand button.
/// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
/// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
/// is major major major.
struct InlineJobRowsView: View {
    let group: ActionGroup
    let tick: Int
    var onSelectJob: ((ActiveJob, ActionGroup) -> Void)?

    @EnvironmentObject private var popoverOpenState: PopoverOpenState
    @State private var cap: Int = 4

    private var activeJobs: [ActiveJob] {
        group.jobs.filter { $0.status == "in_progress" }
    }

    var body: some View {
        ForEach(activeJobs.prefix(cap)) { job in
            if let onSelectJob {
                Button(action: { onSelectJob(job, group) }, label: { jobRow(job) })
                    .buttonStyle(.plain)
            } else {
                jobRow(job)
            }
        }
        if activeJobs.count > cap {
            Button(
                action: {
                    if !popoverOpenState.isOpen { cap += 4 }
                },
                label: {
                    Text("+ \(activeJobs.count - cap) more jobs…")
                        .font(.caption2).foregroundColor(.accentColor)
                        .padding(.leading, 24).padding(.trailing, 12).padding(.vertical, 2)
                }
            )
            .buttonStyle(.plain)
            .disabled(popoverOpenState.isOpen)
        }
    }

    private func jobRow(_ job: ActiveJob) -> some View {
        // ⚠️ TICK CONTRACT — DO NOT REMOVE.
        // ❌ NEVER remove this line.
        _ = tick
        let currentStep = job.steps.first(where: { $0.status == "in_progress" })
        let stepName    = currentStep.map(\.name).flatMap { $0.isEmpty ? nil : $0 }
        let done  = job.steps.filter { $0.conclusion != nil }.count
        let total = job.steps.count
        let fraction: CGFloat = total > 0 ? CGFloat(done) / CGFloat(total) : 0

        return HStack(spacing: 6) {
            // Phase 5: → arrow + 14pt spinning donut
            Text("→")
                .font(.caption)
                .foregroundColor(DesignTokens.Color.labelTertiary)
                .frame(width: 16, alignment: .trailing)

            StatusDonutView(
                status: .inProgress,
                conclusion: nil,
                progress: job.progressFraction
            )
            .frame(width: 14, height: 14)

            // Job name · current step
            Group {
                if let name = stepName {
                    Text(job.name + " · " + name)
                } else {
                    Text(job.name)
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1).truncationMode(.tail)
            .layoutPriority(1)

            Spacer()

            // Phase 5: thin progress bar (90×3)
            if total > 0 {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 90, height: 3)
                    Capsule()
                        .fill(DesignTokens.Color.statusBlue.opacity(0.75))
                        .frame(width: 90 * fraction, height: 3)
                }
            }

            // Step count e.g. 20/21
            if total > 0 {
                Text("\(done)/\(total)")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            // Elapsed
            Text(job.elapsed)
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            if onSelectJob != nil {
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundColor(DesignTokens.Color.labelTertiary)
            }
        }
        .padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func jobDotColor(for job: ActiveJob) -> Color {
        switch job.status {
        case "in_progress": return DesignTokens.Color.statusBlue
        case "queued":      return DesignTokens.Color.statusBlue
        default: return job.conclusion == "success"
            ? DesignTokens.Color.statusGreen
            : (job.isDimmed ? .gray : DesignTokens.Color.statusRed)
        }
    }
}
