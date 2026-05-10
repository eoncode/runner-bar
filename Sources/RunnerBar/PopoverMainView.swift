import SwiftUI

// ⚠️ REGRESSION GUARD — frame + padding rules (ref #52 #54 #57 #296)
//
// RULE 1: Root VStack MUST use .frame(idealWidth: 420, maxWidth: .infinity, alignment: .top)
// AppDelegate reads hc.view.fittingSize in openPopover() to size the popover.
// ❌ NEVER remove .frame(idealWidth: 420)
// ❌ NEVER use .frame(width: 420)
// ❌ NEVER remove maxWidth: .infinity
// ❌ NEVER add .frame(height:) or .frame(maxHeight:) to the ScrollView or any container
//    The maxHeight cap lives ONLY in AppDelegate (maxHeight: 620), applied once before .show().
// ❌ NEVER add expandedGroups toggle for in-progress groups — they are ALWAYS expanded per spec #296
//
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: NEVER use .fixedSize() on any container.
// RULE 5: RunnerStoreObservable.reload() uses withAnimation(nil).
// RULE 6: ActionsListView uses ScrollView with NO .frame(maxHeight:).
//         AppDelegate.maxHeight = 620 is the only height ceiling.
//         InlineJobsView has NO cap — all non-concluded jobs are shown immediately per spec #178.

/// Root popover view. Shows system stats, runners, action groups, inline jobs, and scope settings.
struct PopoverMainView: View {
    @ObservedObject var store: RunnerStoreObservable
    let onSelectJob: (ActiveJob) -> Void
    let onSelectAction: (ActionGroup) -> Void
    let onSelectSettings: () -> Void

    @State private var isAuthenticated = (githubToken() != nil)
    @StateObject private var systemStats = SystemStatsViewModel()
    /// Number of action groups visible. Starts at 10, incremented by 10 on "Load more".
    @State private var visibleCount: Int = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeaderView(
                systemStats: systemStats,
                isAuthenticated: isAuthenticated,
                onSelectSettings: onSelectSettings
            )
            Divider()
            if store.isRateLimited {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow).font(.caption)
                    Text("GitHub rate limit reached — pausing polls")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                Divider()
            }
            // ⚠️ SPEC ORDER (#296): Runners section ABOVE actions list.
            RunnersListView(runners: store.runners)
            ActionsListView(
                actions: store.actions,
                visibleCount: $visibleCount,
                onSelectAction: onSelectAction
            )
        }
        .frame(idealWidth: 420, maxWidth: .infinity, alignment: .top)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            systemStats.start()
        }
        .onDisappear { systemStats.stop() }
        .onChange(of: store.actions) { _ in visibleCount = 10 }
    }
}

// MARK: - MiniBarView

private struct MiniBarView: View {
    let fraction: Double
    var width: CGFloat = 22
    var height: CGFloat = 6

    private var clampedFraction: Double { max(0, min(1, fraction)) }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.primary.opacity(0.12))
                .frame(width: width, height: height)
            RoundedRectangle(cornerRadius: 1)
                .fill(barColor)
                .frame(width: CGFloat(clampedFraction) * width, height: height)
        }
    }

    private var barColor: Color {
        if clampedFraction > 0.85 { return .red }
        if clampedFraction > 0.60 { return .yellow }
        return .green
    }
}

// MARK: - PopoverHeaderView

private struct PopoverHeaderView: View {
    let systemStats: SystemStatsViewModel
    let isAuthenticated: Bool
    let onSelectSettings: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            statChip(
                label: "CPU",
                fraction: systemStats.stats.cpuPct / 100,
                value: String(format: "%.1f%%", systemStats.stats.cpuPct)
            )
            statChip(
                label: "MEM",
                fraction: systemStats.stats.memTotalGB > 0
                    ? systemStats.stats.memUsedGB / systemStats.stats.memTotalGB : 0,
                value: String(format: "%.1f/%.0fGB",
                              systemStats.stats.memUsedGB, systemStats.stats.memTotalGB)
            )
            statChip(
                label: "DISK",
                fraction: systemStats.stats.diskTotalGB > 0
                    ? systemStats.stats.diskUsedGB / systemStats.stats.diskTotalGB : 0,
                value: String(format: "%.0f/%.0fGB",
                              systemStats.stats.diskUsedGB, systemStats.stats.diskTotalGB)
            )
            Spacer()
            if !isAuthenticated {
                Button(
                    action: onSelectSettings,
                    label: {
                        HStack(spacing: 4) {
                            Circle().fill(Color.orange).frame(width: 7, height: 7)
                            Text("Sign in").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                )
                .buttonStyle(.plain)
                .help("Not authenticated — open Settings to add a GitHub token")
            }
            Button(
                action: onSelectSettings,
                label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            )
            .buttonStyle(.plain)
            .help("Settings")
            Button(
                action: { NSApplication.shared.hide(nil) },
                label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            )
            .buttonStyle(.plain)
            .help("Close popover")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    @ViewBuilder
    private func statChip(label: String, fraction: Double, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundColor(.secondary)
            MiniBarView(fraction: fraction)
            Text(value).font(.caption2.monospacedDigit()).foregroundColor(.primary)
        }
    }
}

// MARK: - ActionsListView

/// Scrollable actions list with pagination (Phase 3–5 / #302 #304 #305).
/// ⚠️ ScrollView has NO .frame(maxHeight:) — height cap is AppDelegate.maxHeight = 620 only.
/// ⚠️ In-progress groups are ALWAYS expanded — no toggle per spec #296/#178.
private struct ActionsListView: View {
    let actions: [ActionGroup]
    @Binding var visibleCount: Int
    let onSelectAction: (ActionGroup) -> Void

    var body: some View {
        if actions.isEmpty {
            Text("No recent actions")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 4)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(actions.prefix(visibleCount)) { actionGroup in
                        ActionRowView(
                            actionGroup: actionGroup,
                            onSelect: { onSelectAction(actionGroup) }
                        )
                    }
                    if actions.count > visibleCount {
                        Button(
                            action: { visibleCount += 10 },
                            label: {
                                Text("Load 10 more actions…")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        )
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                    } else if visibleCount > 10 {
                        Text("No more actions")
                            .font(.caption2).foregroundColor(.secondary.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 6)
                    }
                }
            }
            .padding(.bottom, 6)
        }
    }
}

// MARK: - ActionRowView

/// Single action group row.
/// ⚠️ In-progress groups: inline ↳ job rows are ALWAYS shown — no toggle.
/// ⚠️ Do NOT guard on job.status == "in_progress" for inline rows — queued jobs
///    at job-level still belong to an actively running workflow (#296).
private struct ActionRowView: View {
    let actionGroup: ActionGroup
    let onSelect: () -> Void

    /// Inline jobs shown when group is in_progress and has jobs — pure computed, no @State.
    private var showInlineJobs: Bool {
        actionGroup.groupStatus == .inProgress && !actionGroup.jobs.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(
                action: onSelect,
                label: {
                    HStack(spacing: 6) {
                        PieProgressView(
                            progress: actionGroup.progressFraction,
                            color: actionDotColor(for: actionGroup)
                        )
                        Text(actionGroup.label)
                            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                            .lineLimit(1).frame(width: 46, alignment: .leading)
                        Text(actionGroup.title)
                            .font(.system(size: 12))
                            .foregroundColor(actionGroup.isDimmed ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer()
                        Text(actionGroup.startedAgo)
                            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                            .frame(width: 44, alignment: .trailing)
                        Text(actionGroup.elapsed)
                            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                            .frame(width: 36, alignment: .trailing)
                        Text(actionGroup.jobProgress)
                            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                            .frame(width: 28, alignment: .trailing)
                        // ⚠️ width 80 required — "IN PROGRESS" is 11 chars in .caption.
                        // width 60 causes line-wrap and double-height rows (#296).
                        Text(actionStatusLabel(for: actionGroup))
                            .font(.caption)
                            .foregroundColor(actionStatusColor(for: actionGroup))
                            .frame(width: 80, alignment: .trailing)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 3)
                }
            )
            .buttonStyle(.plain)

            // ⚠️ Always shown when in_progress — no toggle.
            // Includes queued jobs at job-level; they belong to the active run.
            // Filter: exclude only jobs that have already concluded.
            if showInlineJobs {
                InlineJobsView(
                    jobs: actionGroup.jobs.filter { $0.conclusion == nil }
                )
            }
        }
    }

    private func actionStatusLabel(for group: ActionGroup) -> String {
        switch group.groupStatus {
        case .inProgress: return "IN PROGRESS"
        case .queued:     return "QUEUED"
        case .completed:
            switch group.conclusion {
            case "success":   return "SUCCESS"
            case "failure":   return "FAILED"
            case "cancelled": return "CANCELED"
            case "skipped":   return "SKIPPED"
            default:          return "DONE"
            }
        }
    }

    private func actionStatusColor(for group: ActionGroup) -> Color {
        switch group.groupStatus {
        case .inProgress: return .yellow
        case .queued:     return .blue
        case .completed:
            if group.isDimmed { return .secondary }
            return group.conclusion == "success" ? .green : .red
        }
    }

    private func actionDotColor(for group: ActionGroup) -> Color {
        switch group.groupStatus {
        case .inProgress: return .yellow
        case .queued:     return .blue
        case .completed:
            if group.isDimmed { return .gray }
            return group.conclusion == "success" ? .green : .red
        }
    }
}

// MARK: - InlineJobsView

/// Container for inline ↳ job sub-rows under a single action group (Phase 4 / #304).
/// ⚠️ Receives non-concluded jobs — caller filters out jobs with conclusion != nil.
/// ⚠️ NO cap — all jobs are shown immediately per spec #178.
///    With 10 jobs, all 10 must be visible without any "Load more" interaction.
private struct InlineJobsView: View {
    let jobs: [ActiveJob]

    var body: some View {
        ForEach(jobs) { job in
            InlineJobRowView(job: job)
        }
    }
}

// MARK: - InlineJobRowView

private struct InlineJobRowView: View {
    let job: ActiveJob

    var body: some View {
        HStack(spacing: 6) {
            Text("↳")
                .font(.caption2).foregroundColor(.secondary)
                .padding(.leading, 14)
            PieProgressView(
                progress: job.progressFraction,
                color: jobDotColor(for: job),
                size: 7
            )
            Text(job.name)
                .font(.caption).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer()
            Text(currentStepTitle(for: job))
                .font(.caption).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.tail)
            Text(stepFraction(for: job))
                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                .frame(width: 30, alignment: .trailing)
            Text(job.elapsed)
                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 2)
    }

    private func stepFraction(for job: ActiveJob) -> String {
        let total = job.steps.count
        guard total > 0 else { return "" }
        let done = job.steps.filter { $0.conclusion != nil }.count
        return "\(done)/\(total)"
    }

    private func currentStepTitle(for job: ActiveJob) -> String {
        if let active = job.steps.first(where: { $0.status == "in_progress" }) { return active.name }
        if let last = job.steps.last(where: { $0.conclusion != nil }) { return last.name }
        return "—"
    }

    private func jobDotColor(for job: ActiveJob) -> Color {
        switch job.status {
        case "in_progress": return .yellow
        case "queued":      return .blue
        default: return job.conclusion == "success" ? .green : (job.isDimmed ? .gray : .red)
        }
    }
}

// MARK: - RunnersListView

/// Conditional runners sub-section — only shown when ≥1 Runner is busy (Phase 6 / #307).
private struct RunnersListView: View {
    let runners: [Runner]

    private var activeRunners: [Runner] { runners.filter { $0.busy } }

    var body: some View {
        if !activeRunners.isEmpty {
            ForEach(activeRunners, id: \.id) { runner in
                HStack(spacing: 6) {
                    Circle().fill(Color.yellow).frame(width: 7, height: 7)
                    Text(runner.name)
                        .font(.system(size: 12)).foregroundColor(.primary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer()
                    if let metrics = runner.metrics {
                        Text(String(format: "CPU: %.1f%%", metrics.cpu))
                            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        Text(String(format: "MEM: %.1f%%", metrics.mem))
                            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    } else {
                        Text("CPU: — MEM: —").font(.caption).foregroundColor(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundColor(.secondary.opacity(0.4))
                }
                .padding(.horizontal, 12).padding(.vertical, 3)
            }
            Divider()
        }
    }
}
