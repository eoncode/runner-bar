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

    /// Green dot when authenticated; tappable orange dot + caption when not.
    @ViewBuilder
    private var authIndicator: some View {
        if isAuthenticated {
            Circle().fill(Color.green).frame(width: 7, height: 7)
        } else {
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
    }

    /// Inline CPU / MEM / DISK chips.
    private var systemStatsBadge: some View {
        HStack(spacing: 8) {
            statChip(label: "CPU", value: String(format: "%.1f%%", stats.cpuPct), pct: stats.cpuPct)
            statChip(
                label: "MEM",
                value: String(format: "%.1f/%.1fGB", stats.memUsedGB, stats.memTotalGB),
                pct: stats.memTotalGB > 0 ? (stats.memUsedGB / stats.memTotalGB) * 100 : 0
            )
            statChip(
                label: "DISK",
                value: String(
                    format: "%d/%dGB",
                    Int(stats.diskUsedGB.rounded()), Int(stats.diskTotalGB.rounded())
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

    /// Traffic-light colour: red > 85 %, yellow > 60 %, green otherwise.
    private func usageColor(pct: Double) -> Color {
        if pct > 85 { return .red }
        if pct > 60 { return .yellow }
        return .green
    }
}

// MARK: - PopoverLocalRunnerRow

/// Conditionally shows online local runners — hidden when all are idle/offline.
/// The parent (PopoverMainView) always renders a leading Divider above this view.
/// This view only renders a trailing Divider after its runner rows.
struct PopoverLocalRunnerRow: View {
    /// All known runners; view filters to online ones internally.
    let runners: [Runner]

    var body: some View {
        let active = runners.filter { $0.status == "online" }
        if !active.isEmpty { runnerList(active) }
    }

    /// Runner rows (capped at 3) — overflow indicator — trailing Divider.
    /// Leading Divider is owned by the parent view.
    @ViewBuilder
    private func runnerList(_ active: [Runner]) -> some View {
        ForEach(active.prefix(3)) { runner in
            HStack(spacing: 8) {
                Circle().fill(runner.busy ? Color.yellow : Color.green).frame(width: 8, height: 8)
                Text(runner.name)
                    .font(.system(size: 12)).foregroundColor(.primary).lineLimit(1)
                Spacer()
                if let metrics = runner.metrics {
                    Text(String(format: "CPU: %.1f%%  MEM: %.1f%%", metrics.cpu, metrics.mem))
                        .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 3)
        }
        if active.count > 3 {
            Text("+ \(active.count - 3) more…")
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 2)
        }
        Divider()
    }
}

// MARK: - ActionRowView

/// Single action-group row with pie progress dot, started-ago timestamp,
/// and spec-parity typography.
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
        HStack(spacing: 0) {
            rowContentButton
            if group.groupStatus == .inProgress && !group.jobs.isEmpty {
                expandButton
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundColor(.secondary).padding(.trailing, 12)
            }
        }
    }

    /// Tappable main area of the row (navigates to action detail).
    private var rowContentButton: some View {
        Button(action: onSelect, label: { rowContent }).buttonStyle(.plain)
    }

    /// Row content: pie dot, label, title, and trailing meta.
    private var rowContent: some View {
        HStack(spacing: 6) {
            PieProgressDot(progress: group.progressFraction, color: dotColor)
            Text(group.label)
                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                .lineLimit(1).frame(width: 52, alignment: .leading)
            Text(group.title)
                .font(.system(size: 12))
                .foregroundColor(group.isDimmed ? .secondary : .primary)
                .lineLimit(1).truncationMode(.tail)
            Spacer()
            metaTrailing
        }
        .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 3)
    }

    /// Trailing meta: started-ago + elapsed + job progress + status chip.
    @ViewBuilder
    private var metaTrailing: some View {
        if let start = group.firstJobStartedAt {
            Text(RelativeTimeFormatter.string(from: start))
                .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        if group.groupStatus == .inProgress || group.groupStatus == .queued {
            Text(group.currentJobName)
                .font(.caption).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: 72, alignment: .trailing)
        }
        Text(group.jobProgress)
            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
            .frame(width: 30, alignment: .trailing)
        Text(group.elapsed)
            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
            .frame(width: 40, alignment: .trailing)
        statusChip
    }

    /// Expand/collapse chevron button for groups with in-progress jobs.
    private var expandButton: some View {
        Button(
            action: onToggleExpand,
            label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2).foregroundColor(.secondary)
            }
        )
        .buttonStyle(.plain).padding(.trailing, 12).padding(.vertical, 3)
    }

    /// Status chip with bold weight for spec parity (#178).
    @ViewBuilder
    private var statusChip: some View {
        switch group.groupStatus {
        case .inProgress:
            Text("IN PROGRESS")
                .font(.system(size: 9, weight: .bold)).foregroundColor(.yellow)
        case .queued:
            Text("QUEUED")
                .font(.system(size: 9, weight: .bold)).foregroundColor(.blue)
        case .completed:
            let success = group.conclusion == "success"
            Text(success ? "SUCCESS" : "FAILED")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(success ? .green : .red)
        }
    }

    /// Pie dot colour derived from group status and conclusion.
    private var dotColor: Color {
        switch group.groupStatus {
        case .inProgress: return .yellow
        case .queued: return .blue
        case .completed:
            if group.isDimmed { return .gray }
            return group.conclusion == "success" ? .green : .red
        }
    }
}

// MARK: - InlineJobRowsView

/// Inline ↳ job rows shown beneath an expanded action group.
/// Supports paginated reveal via `jobLimit` binding (tappable "Load more jobs" affordance).
struct InlineJobRowsView: View {
    /// The parent action group whose jobs are displayed.
    let group: ActionGroup
    /// Current display cap for this group's inline jobs. Mutated by "Load more jobs" tap.
    @Binding var jobLimit: Int
    /// Called when the user taps a job row.
    let onSelectJob: (ActiveJob) -> Void

    /// Jobs currently in-progress or queued inside this group.
    private var activeJobs: [ActiveJob] {
        group.jobs.filter { $0.status == "in_progress" || $0.status == "queued" }
    }

    var body: some View {
        let capped = Array(activeJobs.prefix(jobLimit))
        ForEach(capped) { job in
            Button(action: { onSelectJob(job) }, label: { jobRow(job) })
                .buttonStyle(.plain)
        }
        overflowFooter
    }

    /// "+ N more…" caption or "Load more jobs" button depending on remaining count.
    @ViewBuilder
    private var overflowFooter: some View {
        let remaining = activeJobs.count - jobLimit
        if remaining > 0 {
            Button(
                action: { jobLimit = min(jobLimit + 4, activeJobs.count) },
                label: {
                    Text(remaining <= 4 ? "+ \(remaining) more…" : "Load more jobs…")
                        .font(.caption2).foregroundColor(.secondary)
                }
            )
            .buttonStyle(.plain)
            .padding(.leading, 24).padding(.trailing, 12).padding(.vertical, 2)
        }
    }

    /// Renders a single inline job row with pie dot, step progress, and elapsed time.
    private func jobRow(_ job: ActiveJob) -> some View {
        HStack(spacing: 6) {
            Text("↳").font(.caption).foregroundColor(.secondary).frame(width: 16, alignment: .trailing)
            PieProgressDot(progress: job.progressFraction, color: jobDotColor(for: job), size: 7)
            Text(job.name)
                .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
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

    /// Pie dot colour for a job row.
    private func jobDotColor(for job: ActiveJob) -> Color {
        switch job.status {
        case "in_progress": return .yellow
        case "queued": return .blue
        default: return job.conclusion == "success" ? .green : (job.isDimmed ? .gray : .red)
        }
    }
}
