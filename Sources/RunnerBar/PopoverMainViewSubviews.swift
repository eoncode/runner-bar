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
struct PopoverHeaderView: View {
    let stats: SystemStats
    let cpuHistory: [Double]
    let memHistory: [Double]
    let diskHistory: [Double]
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
struct PopoverLocalRunnerRow: View {
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
                        StatPill(label: "CPU", value: String(format: "%.1f%%", metrics.cpu))
                        StatPill(label: "MEM", value: String(format: "%.1f%%", metrics.mem))
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
struct ActionRowView: View {
    let group: ActionGroup
    let tick: Int
    let onSelect: () -> Void
    var onSelectJob: ((ActiveJob, ActionGroup) -> Void)? = nil

    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                LeftIndicatorPill(color: indicatorColor, isExpanded: isExpanded) {
                    withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                }
                .frame(maxHeight: .infinity)
                Button(action: onSelect, label: { rowContent }).buttonStyle(.plain)
                // fix(#441 bug6): explicit rotationEffect(0) prevents parent
                // animation context from rotating this chevron on expand/collapse.
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(0))
                    .padding(.trailing, 8)
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Spacing.cardRadius)
                    .fill(rowTint)
            )

            if isExpanded && group.typedGroupStatus == .inProgress {
                InlineJobRowsView(
                    group: group,
                    tick: tick,
                    onSelectJob: onSelectJob
                )
                .padding(.leading, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.rowHPad)
        .padding(.vertical, 2)
        .onAppear {
            if group.typedGroupStatus == .inProgress {
                isExpanded = true
            }
        }
    }

    private var rowContent: some View {
        _ = tick
        return HStack(spacing: 6) {
            DonutStatusView(
                status: group.typedGroupStatus,
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
        if group.typedGroupStatus == .inProgress || group.typedGroupStatus == .queued {
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
        switch group.typedGroupStatus {
        case .inProgress:
            StatusPill(label: "IN PROGRESS", color: DesignTokens.Colors.statusBlue)
        case .queued:
            StatusPill(label: "QUEUED", color: DesignTokens.Colors.statusOrange)
        case .completed, .failed, .success, .unknown:
            let color = group.conclusion == "success"
                ? DesignTokens.Colors.statusGreen
                : DesignTokens.Colors.statusRed
            let label = group.conclusion == "success" ? "SUCCESS" : "FAILED"
            StatusPill(label: label, color: color)
        }
    }

    private var indicatorColor: Color {
        switch group.typedGroupStatus {
        case .inProgress: return DesignTokens.Colors.statusBlue
        case .queued:     return DesignTokens.Colors.statusOrange
        case .completed, .failed, .success, .unknown:
            return group.conclusion == "success"
                ? DesignTokens.Colors.statusGreen
                : DesignTokens.Colors.statusRed
        }
    }

    private var rowTint: Color {
        switch group.typedGroupStatus {
        case .inProgress: return DesignTokens.Colors.statusBlue.opacity(0.04)
        case .queued:     return DesignTokens.Colors.statusOrange.opacity(0.04)
        case .completed, .failed, .success, .unknown:
            if group.isDimmed { return Color.clear }
            return group.conclusion == "success"
                ? DesignTokens.Colors.statusGreen.opacity(0.04)
                : DesignTokens.Colors.statusRed.opacity(0.04)
        }
    }
}

// MARK: - StatusPill
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

    /// fix(#441 bug1): deduplicate by id before filtering status.
    private var activeJobs: [ActiveJob] {
        var seen = Set<Int>()
        return group.jobs.filter { seen.insert($0.id).inserted }
            .filter { $0.status == "in_progress" }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
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

    private func jobRow(_ job: ActiveJob) -> some View {
        _ = tick
        return jobRowContent(job)
            .padding(.vertical, 3)
            .padding(.trailing, DesignTokens.Spacing.rowHPad)
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

    private func jobRowContent(_ job: ActiveJob) -> some View {
        let currentStep = job.steps.first(where: { $0.status == "in_progress" })
        let stepName = currentStep.map(\.name).flatMap { $0.isEmpty ? nil : $0 }
        let done = job.steps.filter { $0.conclusion != nil }.count
        let total = job.steps.count
        let stepFraction: Double? = total > 0 ? Double(done) / Double(total) : nil
        let barColor = jobBarColor(for: job)

        return HStack(spacing: 6) {
            Spacer().frame(width: 28)
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
