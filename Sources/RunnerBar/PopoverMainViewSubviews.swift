import SwiftUI

// MARK: - SectionHeaderLabel
/// Uppercase section header label used throughout the popover (e.g. "ACTIONS").
struct SectionHeaderLabel: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, DesignTokens.Spacing.rowHPad)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

// MARK: - PopoverHeaderView
/// Header row: system stats left, settings + close right.
/// ⚠️ Auth green dot removed — auth status lives in Settings > Account only (#10).
struct PopoverHeaderView: View {
    let stats: SystemStats
    let isAuthenticated: Bool
    let onSelectSettings: () -> Void
    let onSignIn: () -> Void
    /// Phase 2: history buffers passed from the view model
    var cpuHistory: [Double] = []
    var memHistory: [Double] = []

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
        .padding(.horizontal, DesignTokens.Spacing.rowHPad)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// Phase 2: sparkline stat blocks separated by vertical dividers.
    /// ⚠️ LOAD-BEARING: `.lineLimit(1)` on chip texts prevents multi-line wrapping that
    /// would change `preferredContentSize.height` and corrupt the panel frame (ref #52 #54).
    private var systemStatsBadge: some View {
        HStack(spacing: 0) {
            // CPU block
            statBlock(
                label: "CPU",
                value: String(format: "%.1f%%", stats.cpuPct),
                pct: stats.cpuPct,
                history: cpuHistory
            )
            divider
            // MEM block
            let memPct = stats.memTotalGB > 0 ? (stats.memUsedGB / stats.memTotalGB) * 100 : 0
            statBlock(
                label: "MEM",
                value: String(format: "%.1f/%.1fGB", stats.memUsedGB, stats.memTotalGB),
                pct: memPct,
                history: memHistory
            )
            divider
            // DISK block — pill style
            diskBlock
        }
    }

    /// Vertical hairline divider between stat blocks.
    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(width: 0.5, height: 20)
            .padding(.horizontal, 8)
    }

    /// Single stat block: label + sparkline + value.
    private func statBlock(label: String, value: String, pct: Double, history: [Double]) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(DesignTokens.Fonts.monoLabel)
                .foregroundColor(.secondary)
                .lineLimit(1)
            // Phase 2: sparkline replaces the block-bar glyph string
            if history.count >= 2 {
                SparklineView(history: history, currentPct: pct)
                    .frame(width: 44, height: 18)
            }
            Text(value)
                .font(DesignTokens.Fonts.monoStat)
                .foregroundColor(DesignTokens.Colors.usage(pct: pct))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// Phase 2: DISK pill view.
    private var diskBlock: some View {
        HStack(spacing: 5) {
            Text("DISK")
                .font(DesignTokens.Fonts.monoLabel)
                .foregroundColor(.secondary)
                .lineLimit(1)
            DiskPillView(
                freePct: stats.diskFreePct,
                usedGB: Int(stats.diskUsedGB.rounded()),
                totalGB: Int(stats.diskTotalGB.rounded())
            )
        }
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

// MARK: - PopoverLocalRunnerRow
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
                Circle().fill(Color.yellow).frame(width: 8, height: 8)
                Text(runner.name)
                    .font(DesignTokens.Fonts.mono)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer()
                if let metrics = runner.metrics {
                    Text(String(format: "CPU: %.1f%% MEM: %.1f%%", metrics.cpu, metrics.mem))
                        .font(DesignTokens.Fonts.mono)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.rowHPad)
            .padding(.vertical, 3)
        }
        if busy.count > 3 {
            Text("+ \(busy.count - 3) more…")
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, DesignTokens.Spacing.rowHPad)
                .padding(.vertical, 2)
        }
        Divider()
    }
}

// MARK: - ActionRowView
struct ActionRowView: View {
    let group: ActionGroup
    let tick: Int
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect, label: { rowContent }).buttonStyle(.plain)
            Image(systemName: "chevron.right")
                .font(.caption2).foregroundColor(.secondary).padding(.trailing, 12)
        }
    }

    private var rowContent: some View {
        // ⚠️ TICK CONTRACT — DO NOT REMOVE.
        // ❌ NEVER remove this line.
        _ = tick
        return HStack(spacing: 6) {
            PieProgressDot(progress: group.progressFraction, color: dotColor)
            RunnerTypeIcon(isLocal: group.isLocalGroup)
            Text(group.label)
                .font(DesignTokens.Fonts.mono)
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
        .padding(.leading, DesignTokens.Spacing.rowHPad)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var metaTrailing: some View {
        if let start = group.firstJobStartedAt {
            Text(RelativeTimeFormatter.string(from: start))
                .font(DesignTokens.Fonts.mono)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        if group.groupStatus == .inProgress || group.groupStatus == .queued {
            Text(group.currentJobName)
                .font(.caption).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(0)
        }
        Text(group.jobProgress)
            .font(DesignTokens.Fonts.mono)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        Text(group.elapsed)
            .font(DesignTokens.Fonts.mono)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        statusChip
    }

    @ViewBuilder
    private var statusChip: some View {
        switch group.groupStatus {
        case .inProgress:
            Text("IN PROGRESS")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(DesignTokens.Colors.statusBlue)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        case .queued:
            Text("QUEUED")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(DesignTokens.Colors.statusBlue)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        case .completed:
            let success = group.conclusion == "success"
            Text(success ? "SUCCESS" : "FAILED")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(success ? DesignTokens.Colors.statusGreen : DesignTokens.Colors.statusRed)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        }
    }

    private var dotColor: Color {
        switch group.groupStatus {
        case .inProgress: return DesignTokens.Colors.statusBlue
        case .queued:     return DesignTokens.Colors.statusBlue
        case .completed:
            if group.isDimmed { return .gray }
            return group.conclusion == "success" ? DesignTokens.Colors.statusGreen : DesignTokens.Colors.statusRed
        }
    }
}

// MARK: - InlineJobRowsView
/// Passive read-only ↳ job rows shown beneath every in-progress action group.
/// Only shows jobs that are currently `in_progress`.
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
            .font(.caption).foregroundColor(.secondary)
            .lineLimit(1).truncationMode(.tail)
            .layoutPriority(1)
            Spacer()
            if total > 0 {
                Text("\(done)/\(total)")
                    .font(DesignTokens.Fonts.mono)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text(job.elapsed)
                .font(DesignTokens.Fonts.mono)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if onSelectJob != nil {
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, DesignTokens.Spacing.rowHPad)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func jobDotColor(for job: ActiveJob) -> Color {
        switch job.status {
        case "in_progress": return DesignTokens.Colors.statusBlue
        case "queued":      return DesignTokens.Colors.statusBlue
        default: return job.conclusion == "success"
            ? DesignTokens.Colors.statusGreen
            : (job.isDimmed ? .gray : DesignTokens.Colors.statusRed)
        }
    }
}
