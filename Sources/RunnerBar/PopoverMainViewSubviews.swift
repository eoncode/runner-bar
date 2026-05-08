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

    /// Renders the header HStack with stats, auth, settings and close controls.
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

    /// Green dot when authenticated; tappable orange dot + `"Sign in"` caption when not.
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
    /// ⚠️ LOAD-BEARING: `.lineLimit(1)` on chip texts prevents multi-line wrapping that
    /// would change `hc.view.fittingSize.height` and corrupt the popover frame in
    /// `AppDelegate.openPopover()` (ref #52 #54).
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
    /// Both texts are `.lineLimit(1)` — load-bearing, see `systemStatsBadge` doc.
    private func statChip(label: String, value: String, pct: Double) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(usageColor(pct: pct))
                .lineLimit(1)
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
/// Triggers a `LocalRunnerStore.shared.refresh()` on appear.
struct PopoverLocalRunnerRow: View {
    /// All known runners; view filters to online ones internally.
    let runners: [Runner]

    /// Renders runner rows if any are online, or nothing otherwise.
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
/// and spec-parity typography (#178). Inline job rows are always visible
/// beneath in-progress groups — there is no expand/collapse interaction.
struct ActionRowView: View {
    /// The action group this row represents.
    let group: ActionGroup
    /// Called when the user taps the main row area (navigate to action detail).
    let onSelect: () -> Void

    /// Renders the tappable row content with a trailing chevron.
    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect, label: { rowContent }).buttonStyle(.plain)
            Image(systemName: "chevron.right")
                .font(.caption2).foregroundColor(.secondary).padding(.trailing, 12)
        }
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

    /// Trailing meta: started-ago + current job name + job progress + elapsed + status chip.
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

/// Passive inline ↳ job rows shown beneath every in-progress action group.
/// Always visible — no expand/collapse interaction. Capped at 4 with a
/// `+ N more…` caption when the group has more active jobs.
struct InlineJobRowsView: View {
    /// The parent action group whose active jobs are displayed.
    let group: ActionGroup
    /// Called when the user taps a job row to drill into job detail.
    let onSelectJob: (ActiveJob) -> Void

    /// Maximum number of inline job rows to display before showing overflow caption.
    private let cap = 4

    /// Jobs currently in-progress or queued inside this group.
    private var activeJobs: [ActiveJob] {
        group.jobs.filter { $0.status == "in_progress" || $0.status == "queued" }
    }

    /// Renders up to `cap` job rows followed by an optional overflow caption.
    var body: some View {
        ForEach(activeJobs.prefix(cap)) { job in
            Button(action: { onSelectJob(job) }, label: { jobRow(job) })
                .buttonStyle(.plain)
        }
        if activeJobs.count > cap {
            Text("+ \(activeJobs.count - cap) more…")
                .font(.caption2).foregroundColor(.secondary)
                .padding(.leading, 24).padding(.trailing, 12).padding(.vertical, 2)
        }
    }

    /// Renders a single inline job row.
    /// Format: `↳ [●] JobName · Current step name  done/total  elapsed`
    /// The middle-dot segment is omitted when no in_progress step exists or step name is empty.
    private func jobRow(_ job: ActiveJob) -> some View {
        let currentStep = job.steps.first(where: { $0.status == "in_progress" })
        let stepName = currentStep.map(\.name).flatMap { $0.isEmpty ? nil : $0 }
        let done = job.steps.filter { $0.conclusion != nil }.count
        let total = job.steps.count
        return HStack(spacing: 6) {
            Text("↳").font(.caption).foregroundColor(.secondary).frame(width: 16, alignment: .trailing)
            PieProgressDot(progress: job.progressFraction, color: jobDotColor(for: job), size: 7)
            // Job name + optional middle-dot step name, truncated together
            Group {
                if let name = stepName {
                    Text(job.name + " · " + name)
                } else {
                    Text(job.name)
                }
            }
            .font(.caption).foregroundColor(.secondary)
            .lineLimit(1).truncationMode(.tail)
            Spacer()
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
