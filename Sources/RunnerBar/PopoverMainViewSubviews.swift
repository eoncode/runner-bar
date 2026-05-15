import SwiftUI

// MARK: - SectionHeaderLabel
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
    /// Phase 2: normalised (0–1) CPU history for sparkline, oldest first.
    let cpuHistory: [Double]
    /// Phase 2: normalised (0–1) MEM history for sparkline, oldest first.
    let memHistory: [Double]
    let isAuthenticated: Bool
    let onSelectSettings: () -> Void
    let onSignIn: () -> Void

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
                .buttonStyle(.plain).help("Sign in with GitHub")
            }
            Button(action: onSelectSettings) {
                Image(systemName: "gearshape").font(.system(size: 13)).foregroundColor(.secondary)
            }
            .buttonStyle(.plain).help("Settings")
            Button(action: { NSApplication.shared.terminate(nil) }) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            }
            .buttonStyle(.plain).help("Quit RunnerBar")
        }
        .padding(.horizontal, DesignTokens.Spacing.rowHPad)
        .padding(.top, 10).padding(.bottom, 8)
    }

    /// Phase 2: CPU sparkline + MEM sparkline + DiskPillView, separated by Dividers.
    /// ⚠️ LOAD-BEARING: `.lineLimit(1)` prevents multi-line wrapping that corrupts panel frame (ref #52 #54).
    private var systemStatsBadge: some View {
        HStack(spacing: 6) {
            // CPU sparkline chip
            sparklineChip(
                label: "CPU",
                history: cpuHistory,
                currentPct: stats.cpuPct,
                valueText: String(format: "%.1f%%", stats.cpuPct)
            )
            Divider().frame(height: 16)
            // MEM sparkline chip
            let memPct = stats.memTotalGB > 0 ? (stats.memUsedGB / stats.memTotalGB) * 100 : 0
            sparklineChip(
                label: "MEM",
                history: memHistory,
                currentPct: memPct,
                valueText: String(format: "%.1f/%.1fGB", stats.memUsedGB, stats.memTotalGB)
            )
            Divider().frame(height: 16)
            // Disk pill badge
            let total = stats.diskTotalGB
            let used  = stats.diskUsedGB
            let free  = max(0, total - used)
            let freePct = total > 0 ? (free / total) * 100 : 0
            DiskPillView(
                freePct: freePct,
                usedGB: Int(used.rounded()),
                totalGB: Int(total.rounded())
            )
        }
    }

    /// A compact label + sparkline + value chip for a single metric.
    private func sparklineChip(
        label: String,
        history: [Double],
        currentPct: Double,
        valueText: String
    ) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(DesignTokens.Fonts.monoLabel)
                .foregroundColor(.secondary)
                .lineLimit(1)
            SparklineView(history: history, currentPct: currentPct)
                .frame(width: 28, height: 14)
            Text(valueText)
                .font(DesignTokens.Fonts.monoStat)
                .foregroundColor(DesignTokens.Colors.usage(pct: currentPct))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

// MARK: - RunnerTypeIcon
private struct RunnerTypeIcon: View {
    let isLocal: Bool?
    var body: some View {
        if let local = isLocal {
            Image(systemName: local ? "desktopcomputer" : "cloud")
                .font(.system(size: 9)).foregroundColor(.secondary)
                .accessibilityLabel(local ? "Local runner" : "Cloud runner").fixedSize()
        }
    }
}

// MARK: - PopoverLocalRunnerRow
struct PopoverLocalRunnerRow: View {
    let runners: [Runner]
    var body: some View {
        let busy = runners.filter { $0.busy }
        if !busy.isEmpty { runnerList(busy) }
    }
    @ViewBuilder
    private func runnerList(_ busy: [Runner]) -> some View {
        ForEach(busy.prefix(3)) { runner in
            // Phase 3: card wrapper — RoundedRectangle with stroke + fill
            HStack(spacing: 8) {
                Circle().fill(Color.yellow).frame(width: 8, height: 8)
                Text(runner.name)
                    .font(DesignTokens.Fonts.mono)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer()
                if let metrics = runner.metrics {
                    // Phase 3: StatPill replaces plain text for CPU/MEM
                    HStack(spacing: 4) {
                        StatPill(
                            label: "CPU",
                            value: String(format: "%.1f%%", metrics.cpu)
                        )
                        StatPill(
                            label: "MEM",
                            value: String(format: "%.1f%%", metrics.mem)
                        )
                    }
                }
                // Phase 3: trailing chevron
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, DesignTokens.Spacing.rowHPad)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Spacing.cardRadius, style: .continuous)
                    .fill(DesignTokens.Colors.rowBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Spacing.cardRadius, style: .continuous)
                            .strokeBorder(DesignTokens.Colors.rowBorder, lineWidth: 0.5)
                    )
            )
            .padding(.horizontal, DesignTokens.Spacing.rowHPad)
            .padding(.vertical, 2)
        }
        if busy.count > 3 {
            Text("+ \(busy.count - 3) more…")
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, DesignTokens.Spacing.rowHPad).padding(.vertical, 2)
        }
        Divider()
    }
}

// MARK: - ActionRowView
/// Phase 4: left indicator pill + StatusDonutView + row background tint.
struct ActionRowView: View {
    let group: ActionGroup
    let tick: Int
    let onSelect: () -> Void

    @State private var isExpanded: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            // Phase 4: left indicator pill — tap toggles expansion
            LeftIndicatorPill(color: indicatorColor, isExpanded: isExpanded) {
                isExpanded.toggle()
            }
            Button(action: onSelect, label: { rowContent }).buttonStyle(.plain)
            // Phase 4d (spec): chevron always points right — rotation removed per spec requirement.
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.trailing, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Spacing.cardRadius)
                .fill(rowTint)
        )
        .padding(.horizontal, DesignTokens.Spacing.rowHPad)
        .padding(.vertical, 2)
    }

    private var rowContent: some View {
        // ⚠️ TICK CONTRACT — DO NOT REMOVE.
        // ❌ NEVER remove this line.
        _ = tick
        return HStack(spacing: 6) {
            // Phase 4: StatusDonutView replaces PieProgressDot on action rows
            StatusDonutView(
                status: group.groupStatus,
                conclusion: group.conclusion,
                progress: group.progressFraction
            )
            .padding(.leading, 8)
            RunnerTypeIcon(isLocal: group.isLocalGroup)
            Text(group.label)
                .font(DesignTokens.Fonts.mono).foregroundColor(.secondary)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            Text(group.title)
                .font(.system(size: 12))
                .foregroundColor(group.isDimmed ? .secondary : .primary)
                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
            Spacer()
            metaTrailing
        }
        .padding(.trailing, 4).padding(.vertical, 5)
    }

    @ViewBuilder
    private var metaTrailing: some View {
        if let start = group.firstJobStartedAt {
            Text(RelativeTimeFormatter.string(from: start))
                .font(DesignTokens.Fonts.mono).foregroundColor(.secondary)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        }
        if group.groupStatus == .inProgress || group.groupStatus == .queued {
            Text(group.currentJobName)
                .font(.caption).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.tail).layoutPriority(0)
        }
        Text(group.jobProgress)
            .font(DesignTokens.Fonts.mono).foregroundColor(.secondary)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        Text(group.elapsed)
            .font(DesignTokens.Fonts.mono).foregroundColor(.secondary)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
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

    /// Phase 4: colour of the left indicator pill.
    private var indicatorColor: Color {
        switch group.groupStatus {
        case .inProgress: return DesignTokens.Colors.statusBlue
        case .queued:     return DesignTokens.Colors.statusBlue.opacity(0.5)
        case .completed:
            if group.isDimmed { return .gray }
            return group.conclusion == "success" ? DesignTokens.Colors.statusGreen : DesignTokens.Colors.statusRed
        }
    }

    /// Phase 4: subtle background tint per status.
    private var rowTint: Color {
        switch group.groupStatus {
        case .inProgress: return DesignTokens.Colors.statusBlue.opacity(0.04)
        case .queued:     return DesignTokens.Colors.statusBlue.opacity(0.02)
        case .completed:
            if group.isDimmed { return Color.clear }
            return group.conclusion == "success"
                ? DesignTokens.Colors.statusGreen.opacity(0.04)
                : DesignTokens.Colors.statusRed.opacity(0.04)
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
                Button(action: { onSelectJob(job, group) }, label: { jobRow(job) }).buttonStyle(.plain)
            } else {
                jobRow(job)
            }
        }
        if activeJobs.count > cap {
            Button(
                action: { if !popoverOpenState.isOpen { cap += 4 } },
                label: {
                    Text("+ \(activeJobs.count - cap) more jobs…")
                        .font(.caption2).foregroundColor(.accentColor)
                        .padding(.leading, 24).padding(.trailing, 12).padding(.vertical, 2)
                }
            )
            .buttonStyle(.plain).disabled(popoverOpenState.isOpen)
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
        // Phase 5: step fraction drives the SubJobProgressBar
        let stepFraction: Double? = total > 0 ? Double(done) / Double(total) : nil
        return HStack(spacing: 6) {
            Text("↳").font(.caption).foregroundColor(.secondary).frame(width: 16, alignment: .trailing)
            // Phase 5: replace PieProgressDot with SubJobProgressBar
            SubJobProgressBar(
                fraction: job.status == "queued" ? nil : stepFraction,
                color: jobBarColor(for: job),
                width: 56,
                height: 3
            )
            Group {
                if let name = stepName { Text(job.name + " · " + name) } else { Text(job.name) }
            }
            .font(.caption).foregroundColor(.secondary)
            .lineLimit(1).truncationMode(.tail).layoutPriority(1)
            Spacer()
            if total > 0 {
                Text("\(done)/\(total)")
                    .font(DesignTokens.Fonts.mono).foregroundColor(.secondary)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
            Text(job.elapsed)
                .font(DesignTokens.Fonts.mono).foregroundColor(.secondary)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            if onSelectJob != nil {
                Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.leading, 24).padding(.trailing, DesignTokens.Spacing.rowHPad).padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// Phase 5: bar color replaces the old dot color helper.
    private func jobBarColor(for job: ActiveJob) -> Color {
        switch job.status {
        case "in_progress": return DesignTokens.Colors.statusBlue
        case "queued":      return DesignTokens.Colors.statusBlue.opacity(0.5)
        default: return job.conclusion == "success"
            ? DesignTokens.Colors.statusGreen
            : (job.isDimmed ? .gray : DesignTokens.Colors.statusRed)
        }
    }
}
