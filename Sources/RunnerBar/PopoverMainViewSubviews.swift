import SwiftUI

// MARK: - PopoverHeaderView

/// Header row: system stats left, auth indicator + settings + close right.
struct PopoverHeaderView: View {
    /// Latest system stats snapshot.
    let stats: SystemStats
    /// Whether the user has a valid GitHub token.
    let isAuthenticated: Bool
    /// Called when the user taps the settings gear.
    let onSelectSettings: () -> Void
    /// Called when the user taps the orange auth dot.
    let onSignIn: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            systemStatsBadge
            Spacer()
            authIndicator
            Button(
                action: onSelectSettings,
                label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13)).foregroundColor(.secondary)
                }
            )
            .buttonStyle(.plain).help("Settings")
            Button(
                action: { NSApplication.shared.hide(nil) },
                label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                }
            )
            .buttonStyle(.plain).help("Close")
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
    }

    /// Green dot when authenticated; tappable orange dot when not.
    @ViewBuilder
    private var authIndicator: some View {
        if isAuthenticated {
            Circle().fill(Color.green).frame(width: 7, height: 7)
        } else {
            Button(
                action: onSignIn,
                label: { Circle().fill(Color.orange).frame(width: 7, height: 7) }
            )
            .buttonStyle(.plain)
            .help("Sign in with GitHub")
        }
    }

    /// Inline CPU / MEM / DISK chips.
    private var systemStatsBadge: some View {
        HStack(spacing: 8) {
            statChip(
                label: "CPU",
                value: String(format: "%.1f%%", stats.cpuPct),
                pct: stats.cpuPct
            )
            statChip(
                label: "MEM",
                value: String(format: "%.1f/%.1fGB", stats.memUsedGB, stats.memTotalGB),
                pct: stats.memTotalGB > 0 ? (stats.memUsedGB / stats.memTotalGB) * 100 : 0
            )
            statChip(
                label: "DISK",
                value: String(
                    format: "%d/%dGB",
                    Int(stats.diskUsedGB.rounded()),
                    Int(stats.diskTotalGB.rounded())
                ),
                pct: stats.diskTotalGB > 0 ? (stats.diskUsedGB / stats.diskTotalGB) * 100 : 0
            )
        }
    }

    /// Single label+value chip coloured by usage level.
    private func statChip(label: String, value: String, pct: Double) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(usageColor(pct: pct))
        }
    }

    /// Traffic-light colour based on a usage percentage.
    private func usageColor(pct: Double) -> Color {
        if pct > 85 { return .red }
        if pct > 60 { return .yellow }
        return .green
    }
}

// MARK: - PopoverLocalRunnerRow

/// Conditionally shows online local runners — hidden when all are idle/offline.
/// Owns its own leading + trailing Dividers so the caller never adds an extra one (fix #2).
struct PopoverLocalRunnerRow: View {
    /// All known runners; view filters to online ones internally.
    let runners: [Runner]

    var body: some View {
        let active = runners.filter { $0.status == "online" }
        if !active.isEmpty {
            runnerList(active)
        }
    }

    /// Divider — runner rows — Divider stack for the active case.
    @ViewBuilder
    private func runnerList(_ active: [Runner]) -> some View {
        Divider()
        ForEach(active.prefix(3)) { runner in
            HStack(spacing: 8) {
                Circle()
                    .fill(runner.busy ? Color.yellow : Color.green)
                    .frame(width: 8, height: 8)
                Text(runner.name)
                    .font(.system(size: 12)).foregroundColor(.primary).lineLimit(1)
                Spacer()
                if let metrics = runner.metrics {
                    Text(String(format: "CPU: %.1f%%  MEM: %.1f%%", metrics.cpu, metrics.mem))
                        .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 3)
        }
        Divider()
    }
}

// MARK: - ActionRowView

/// Single action-group row.
/// Fix #1: expand chevron is NOT nested inside the outer row Button — it lives in a
/// separate Button in an HStack so onToggleExpand fires reliably on macOS SwiftUI.
struct ActionRowView: View {
    /// The action group this row represents.
    let group: ActionGroup
    /// Whether the inline job rows beneath this group are currently expanded.
    let isExpanded: Bool
    /// Called when the user taps the main row area (navigate to action detail).
    let onSelect: () -> Void
    /// Called when the user taps the expand/collapse chevron.
    let onToggleExpand: () -> Void

    var body: some View {
        // Two independent tappable zones in the same visual row:
        //   1. rowContentButton — label + title + stats → navigates to detail
        //   2. expandButton / static chevron on the right → toggles inline jobs
        // A plain HStack (not nesting one Button inside another's label)
        // ensures macOS SwiftUI delivers taps to the correct target.
        HStack(spacing: 0) {
            rowContentButton
            if group.groupStatus == .inProgress && !group.jobs.isEmpty {
                expandButton
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundColor(.secondary)
                    .padding(.trailing, 12)
            }
        }
    }

    /// The selectable portion of the row (everything except the expand chevron).
    private var rowContentButton: some View {
        Button(action: onSelect, label: { rowContent })
            .buttonStyle(.plain)
    }

    /// Visual content of the main row area.
    private var rowContent: some View {
        HStack(spacing: 8) {
            // TODO: replace with pie-dot radial progress indicator — see #310 / #182
            Circle().fill(dotColor).frame(width: 8, height: 8)
            Text(group.label)
                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                .lineLimit(1).frame(width: 52, alignment: .leading)
            Text(group.title)
                .font(.system(size: 12))
                .foregroundColor(group.isDimmed ? .secondary : .primary)
                .lineLimit(1).truncationMode(.tail)
            Spacer()
            if group.groupStatus == .inProgress || group.groupStatus == .queued {
                Text(group.currentJobName)
                    .font(.caption).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: 80, alignment: .trailing)
            }
            Text(group.jobProgress)
                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                .frame(width: 30, alignment: .trailing)
            Text(group.elapsed)
                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                .frame(width: 40, alignment: .trailing)
            statusLabel
        }
        .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 3)
    }

    /// The expand/collapse chevron button (only for in-progress rows with jobs).
    private var expandButton: some View {
        Button(
            action: onToggleExpand,
            label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2).foregroundColor(.secondary)
            }
        )
        .buttonStyle(.plain)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
    }

    /// Status badge (IN PROGRESS / QUEUED / SUCCESS / FAILED).
    @ViewBuilder
    private var statusLabel: some View {
        switch group.groupStatus {
        case .inProgress:
            Text("IN PROGRESS")
                .font(.system(size: 9, weight: .semibold)).foregroundColor(.yellow)
        case .queued:
            Text("QUEUED")
                .font(.system(size: 9, weight: .semibold)).foregroundColor(.blue)
        case .completed:
            let success = group.runs.allSatisfy { $0.conclusion == "success" }
            Text(success ? "SUCCESS" : "FAILED")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(success ? .green : .red)
        }
    }

    /// Status dot colour for this group.
    private var dotColor: Color {
        switch group.groupStatus {
        case .inProgress: return .yellow
        case .queued: return .blue
        case .completed:
            if group.isDimmed { return .gray }
            return group.runs.allSatisfy({ $0.conclusion == "success" }) ? .green : .red
        }
    }
}

// MARK: - InlineJobRowsView

/// Inline ↳ job rows shown beneath an expanded action group.
struct InlineJobRowsView: View {
    /// The parent action group whose jobs are displayed.
    let group: ActionGroup
    /// Called when the user taps a job row.
    let onSelectJob: (ActiveJob) -> Void

    /// Jobs currently in-progress or queued inside this group.
    private var activeJobs: [ActiveJob] {
        group.jobs.filter { $0.status == "in_progress" || $0.status == "queued" }
    }

    var body: some View {
        ForEach(activeJobs.prefix(4)) { job in
            Button(
                action: { onSelectJob(job) },
                label: { jobRow(job) }
            )
            .buttonStyle(.plain)
        }
    }

    /// Visual content for a single inline job row.
    private func jobRow(_ job: ActiveJob) -> some View {
        HStack(spacing: 6) {
            Text("↳").font(.caption).foregroundColor(.secondary)
                .frame(width: 16, alignment: .trailing)
            Circle().fill(jobDotColor(for: job)).frame(width: 7, height: 7)
            Text(job.name)
                .font(.caption).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer()
            if let step = job.steps.first(where: { $0.status == "in_progress" }) {
                Text(step.name)
                    .font(.caption2).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: 120, alignment: .trailing)
            }
            let done = job.steps.filter { $0.conclusion != nil }.count
            let total = job.steps.count
            if total > 0 {
                Text("\(done)/\(total)")
                    .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }
            Text(job.elapsed)
                .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.leading, 24).padding(.trailing, 12).padding(.vertical, 2)
    }

    /// Status dot colour for a job.
    private func jobDotColor(for job: ActiveJob) -> Color {
        switch job.status {
        case "in_progress": return .yellow
        case "queued": return .blue
        default: return job.conclusion == "success" ? .green : (job.isDimmed ? .gray : .red)
        }
    }
}
