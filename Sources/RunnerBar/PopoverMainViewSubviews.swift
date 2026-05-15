import SwiftUI

// MARK: - SectionHeaderLabel
/// Uppercase section header label used throughout the popover (e.g. "ACTIONS").
struct SectionHeaderLabel: View {
    /// The title string to display in uppercase.
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
    /// Current system stats snapshot.
    let stats: SystemStats
    /// Phase 2: normalised (0–1) CPU history for sparkline, oldest first.
    let cpuHistory: [Double]
    /// Phase 2: normalised (0–1) MEM history for sparkline, oldest first.
    let memHistory: [Double]
    /// Phase 2: normalised (0–1) DISK-used history for sparkline, oldest first.
    let diskHistory: [Double]
    /// Whether the user has a valid GitHub token.
    let isAuthenticated: Bool
    /// Called when the user taps the settings button.
    let onSelectSettings: () -> Void
    /// Called when the user taps the sign-in button.
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

    /// Phase 2: CPU sparkline + MEM sparkline + DISK sparkline+pill, separated by Dividers.
    /// ⚠️ LOAD-BEARING: `.lineLimit(1)` prevents multi-line wrapping that corrupts panel frame (ref #52 #54).
    private var systemStatsBadge: some View {
        HStack(spacing: 6) {
            sparklineChip(
                label: "CPU",
                history: cpuHistory,
                currentPct: stats.cpuPct,
                valueText: String(format: "%.1f%%", stats.cpuPct)
            )
            Divider().frame(height: 16)
            let memPct = stats.memTotalGB > 0 ? (stats.memUsedGB / stats.memTotalGB) * 100 : 0
            sparklineChip(
                label: "MEM",
                history: memHistory,
                currentPct: memPct,
                valueText: String(format: "%.1f/%.1fGB", stats.memUsedGB, stats.memTotalGB)
            )
            Divider().frame(height: 16)
            let total = stats.diskTotalGB
            let used = stats.diskUsedGB
            let free = max(0, total - used)
            let diskUsedPct = total > 0 ? (used / total) * 100 : 0
            DiskPillView(
                diskHistory: diskHistory,
                diskUsedPct: diskUsedPct,
                freeGB: Int(free.rounded()),
                totalGB: Int(total.rounded())
            )
        }
    }

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
/// Displays busy local runners at the top of the popover.
struct PopoverLocalRunnerRow: View {
    /// The full list of runners; only busy ones are displayed.
    let runners: [Runner]
    var body: some View {
        let busy = runners.filter { $0.busy }
        if !busy.isEmpty { runnerList(busy) }
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
                    .layoutPriority(1)
                Spacer()
                if let metrics = runner.metrics {
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
/// Phase 4: left indicator pill + DonutStatusView + row background tint.
/// `isExpanded` controls whether InlineJobRowsView is shown below this row.
/// Tapping the LeftIndicatorPill toggles expansion; the pill color reflects status.
/// In-progress groups auto-expand on appear so jobs are immediately visible.
struct ActionRowView: View {
    /// The action group this row represents.
    let group: ActionGroup
    /// Display tick used to force elapsed-time re-renders.
    let tick: Int
    /// Called when the user taps the row content area.
    let onSelect: () -> Void
    /// Optional callback for tapping an inline job row.
    var onSelectJob: ((ActiveJob, ActionGroup) -> Void)? = nil

    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Fix #2: LeftIndicatorPill must stretch full row height, not collapse to a dot.
                LeftIndicatorPill(color: indicatorColor, isExpanded: isExpanded) {
                    withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                }
                .frame(maxHeight: .infinity)
                Button(action: onSelect, label: { rowContent }).buttonStyle(.plain)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.trailing, 8)
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Spacing.cardRadius)
                    .fill(rowTint)
            )

            if isExpanded {
                InlineJobRowsView(
                    group: group,
                    tick: tick,
                    onSelectJob: onSelectJob
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.rowHPad)
        .padding(.vertical, 2)
        .onAppear {
            if group.groupStatus == .inProgress {
                isExpanded = true
            }
        }
    }

    private var rowContent: some View {
        // ⚠️ TICK CONTRACT — DO NOT REMOVE.
        _ = tick
        return HStack(spacing: 6) {
            DonutStatusView(
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

    // MARK: - Status chip
    /// Fix #3: IN PROGRESS / QUEUED pill now has both fill AND stroke border.
    /// Fix #4: SUCCESS/FAILED also wrapped in stroked pill (green/red).
    @ViewBuilder
    private var statusChip: some View {
        switch group.groupStatus {
        case .inProgress:
            StatusPill(label: "IN PROGRESS", color: DesignTokens.Colors.statusBlue)
        case .queued:
            StatusPill(label: "QUEUED", color: DesignTokens.Colors.statusOrange)
        case .completed:
            let color = group.conclusion == "success"
                ? DesignTokens.Colors.statusGreen
                : DesignTokens.Colors.statusRed
            let label = group.conclusion == "success" ? "SUCCESS" : "FAILED"
            StatusPill(label: label, color: color)
        }
    }

    private var indicatorColor: Color {
        switch group.groupStatus {
        case .inProgress: return DesignTokens.Colors.statusBlue
        case .queued:     return DesignTokens.Colors.statusOrange
        case .completed:
            // Fix #4: always green or red, never gray regardless of isDimmed
            return group.conclusion == "success"
                ? DesignTokens.Colors.statusGreen
                : DesignTokens.Colors.statusRed
        }
    }

    private var rowTint: Color {
        switch group.groupStatus {
        case .inProgress: return DesignTokens.Colors.statusBlue.opacity(0.04)
        case .queued:     return DesignTokens.Colors.statusOrange.opacity(0.04)
        case .completed:
            if group.isDimmed { return Color.clear }
            return group.conclusion == "success"
                ? DesignTokens.Colors.statusGreen.opacity(0.04)
                : DesignTokens.Colors.statusRed.opacity(0.04)
        }
    }
}

// MARK: - StatusPill
/// Fix #3: stroked pill for all action-row status labels.
/// Uses the status color for text, a semi-transparent fill, and a matching stroke border.
private struct StatusPill: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
                    .overlay(
                        Capsule()
                            .strokeBorder(color.opacity(0.45), lineWidth: 0.5)
                    )
            )
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
    /// The action group whose in-progress jobs are shown.
    let group: ActionGroup
    /// Display tick used to force elapsed-time re-renders.
    let tick: Int
    /// Optional callback for tapping a job row.
    var onSelectJob: ((ActiveJob, ActionGroup) -> Void)?

    @EnvironmentObject private var popoverOpenState: PopoverOpenState
    @State private var cap: Int = 4

    private var activeJobs: [ActiveJob] {
        group.jobs.filter { $0.status == "in_progress" }
    }

    var body: some View {
        // Fix #7: wrap all sub-job rows in a ZStack with a drawn connector line on the left.
        ZStack(alignment: .topLeading) {
            // Vertical connector line from top to bottom of the job list
            if !activeJobs.isEmpty {
                HierarchyConnectorLine(jobCount: min(activeJobs.count, cap))
            }
            VStack(spacing: 2) {
                ForEach(Array(activeJobs.prefix(cap).enumerated()), id: \.element.id) { _, job in
                    if let onSelectJob {
                        Button(action: { onSelectJob(job, group) }) {
                            jobRow(job)
                        }
                        .buttonStyle(.plain)
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
                                .padding(.leading, 28).padding(.trailing, 12).padding(.vertical, 2)
                        }
                    )
                    .buttonStyle(.plain).disabled(popoverOpenState.isOpen)
                }
            }
        }
        .padding(.top, 2)
    }

    /// Fix #5: row order → icon/connector | job name · step | Spacer | progress bar | done/total | elapsed | chevron
    /// Fix #6: each sub-job row gets a rounded card background.
    private func jobRow(_ job: ActiveJob) -> some View {
        // ⚠️ TICK CONTRACT — DO NOT REMOVE.
        _ = tick
        return jobRowContent(job)
            .padding(.vertical, 3)
            .padding(.trailing, DesignTokens.Spacing.rowHPad)
            // Fix #6: rounded card background per sub-job row
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Spacing.cardRadius, style: .continuous)
                    .fill(DesignTokens.Colors.rowBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Spacing.cardRadius, style: .continuous)
                            .strokeBorder(DesignTokens.Colors.rowBorder, lineWidth: 0.5)
                    )
            )
            .contentShape(Rectangle())
    }

    /// Builds the inner HStack content for a single inline job row.
    private func jobRowContent(_ job: ActiveJob) -> some View {
        let currentStep = job.steps.first(where: { $0.status == "in_progress" })
        let stepName = currentStep.map(\.name).flatMap { $0.isEmpty ? nil : $0 }
        let done = job.steps.filter { $0.conclusion != nil }.count
        let total = job.steps.count
        let stepFraction: Double? = total > 0 ? Double(done) / Double(total) : nil
        let barColor = jobBarColor(for: job)

        return HStack(spacing: 6) {
            // 28 pt left indent to clear the hierarchy connector
            Spacer().frame(width: 28)
            // Job name · current step  (fix #5: name comes before progress bar)
            Group {
                if let name = stepName {
                    Text(job.name + " · " + name)
                } else {
                    Text(job.name)
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(1)
            Spacer()
            // Progress bar — after the name (fix #5)
            SubJobProgressBar(
                fraction: job.status == "queued" ? nil : stepFraction,
                color: barColor,
                width: 56,
                height: 3
            )
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
    }

    private func jobBarColor(for job: ActiveJob) -> Color {
        switch job.status {
        case "in_progress": return DesignTokens.Colors.statusBlue
        case "queued":      return DesignTokens.Colors.statusOrange.opacity(0.5)
        default: return job.conclusion == "success"
            ? DesignTokens.Colors.statusGreen
            : (job.isDimmed ? .gray : DesignTokens.Colors.statusRed)
        }
    }
}
