import SwiftUI

// ⚠️ REGRESSION GUARD — frame + padding rules (ref #52 #54 #57)
//
// RULE 1: Root VStack MUST use .frame(idealWidth: 420, maxWidth: .infinity, alignment: .top)
// AppDelegate reads hc.view.fittingSize in openPopover() to size the popover.
// ❌ NEVER remove .frame(idealWidth: 420)
// ❌ NEVER use .frame(width: 420)
// ❌ NEVER remove maxWidth: .infinity (VStack must stretch to full popover width)
// ❌ NEVER add .frame(height:) to root VStack
//
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: NEVER use .fixedSize() on any container.
// RULE 5: RunnerStoreObservable.reload() uses withAnimation(nil).

/// Root popover view. Shows system stats, action groups, inline jobs, runners, and scope settings.
struct PopoverMainView: View {
    /// The observable that bridges RunnerStore state into SwiftUI.
    @ObservedObject var store: RunnerStoreObservable
    /// Called when the user taps a job row to drill into job detail.
    let onSelectJob: (ActiveJob) -> Void
    /// Called when the user taps an action group row to drill into action detail.
    let onSelectAction: (ActionGroup) -> Void
    /// Called when the user taps the settings button.
    let onSelectSettings: () -> Void

    @State private var isAuthenticated = (githubToken() != nil)
    @StateObject private var systemStats = SystemStatsViewModel()
    /// Number of action groups visible. Starts at 10, incremented by 10 on "Load more".
    @State private var visibleCount: Int = 10
    /// Set of action group IDs whose inline job sub-rows are expanded.
    /// In-progress groups default to expanded; queued groups default to collapsed.
    @State private var expandedGroups: Set<String> = []

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
            ActionsListView(
                actions: store.actions,
                visibleCount: $visibleCount,
                expandedGroups: $expandedGroups,
                onSelectAction: onSelectAction
            )
            RunnersListView(runners: store.runners)
        }
        .frame(idealWidth: 420, maxWidth: .infinity, alignment: .top)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            systemStats.start()
            // Seed expanded state: in-progress groups open by default.
            let inProgressIDs = store.actions
                .filter { $0.groupStatus == .inProgress }
                .map { $0.id }
            expandedGroups = Set(inProgressIDs)
        }
        .onDisappear { systemStats.stop() }
    }
}

// MARK: - PopoverHeaderView

/// Header row: system stats + auth dot + gear + close (Phase 2 / #299).
private struct PopoverHeaderView: View {
    let systemStats: SystemStatsViewModel
    let isAuthenticated: Bool
    let onSelectSettings: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            SystemStatsView(stats: systemStats.stats).statsContent
            Spacer()
            if !isAuthenticated {
                Button(
                    action: onSelectSettings,
                    label: { Circle().fill(Color.orange).frame(width: 7, height: 7) }
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
            .help("Hide RunnerBar")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

// MARK: - ActionsListView

/// Scrollable actions list with per-group expand/collapse and pagination (Phase 3–5 / #302 #304 #305).
private struct ActionsListView: View {
    let actions: [ActionGroup]
    @Binding var visibleCount: Int
    @Binding var expandedGroups: Set<String>
    let onSelectAction: (ActionGroup) -> Void

    var body: some View {
        if actions.isEmpty {
            Text("No recent actions")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 4)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(actions.prefix(visibleCount)) { actionGroup in
                        ActionRowView(
                            actionGroup: actionGroup,
                            isExpanded: expandedGroups.contains(actionGroup.id),
                            onToggleExpand: {
                                if expandedGroups.contains(actionGroup.id) {
                                    expandedGroups.remove(actionGroup.id)
                                } else {
                                    expandedGroups.insert(actionGroup.id)
                                }
                            },
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
                    }
                }
            }
            .frame(maxHeight: 400)
            .padding(.bottom, 6)
        }
    }
}

// MARK: - ActionRowView

/// Single action group row with pie dot, label, title, timestamps, status, and expand toggle
/// for inline job sub-rows (Phase 3–4 / #302 #304).
private struct ActionRowView: View {
    let actionGroup: ActionGroup
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onSelect: () -> Void

    /// Whether this group has expandable inline jobs.
    private var hasInlineJobs: Bool {
        let isActive = actionGroup.groupStatus == .inProgress || actionGroup.groupStatus == .queued
        return isActive && actionGroup.jobs.contains {
            $0.status == "in_progress" || $0.status == "queued"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onSelect, label: {
                HStack(spacing: 6) {
                    PieProgressView(
                        progress: actionGroup.jobsTotal > 0
                            ? Double(actionGroup.jobsDone) / Double(actionGroup.jobsTotal)
                            : (actionGroup.groupStatus == .completed ? 1.0 : 0.0),
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
                    Text(actionStatusLabel(for: actionGroup))
                        .font(.caption)
                        .foregroundColor(actionStatusColor(for: actionGroup))
                        .frame(width: 60, alignment: .trailing)
                    if hasInlineJobs {
                        Button(
                            action: onToggleExpand,
                            label: {
                                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                        )
                        .buttonStyle(.plain)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 3)
            })
            .buttonStyle(.plain)

            if hasInlineJobs && isExpanded {
                InlineJobsView(jobs: actionGroup.jobs.filter {
                    $0.status == "in_progress" || $0.status == "queued"
                })
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
            return group.runs.allSatisfy { $0.conclusion == "success" } ? .green : .red
        }
    }
}

// MARK: - InlineJobsView

/// Container for all inline ↳ job sub-rows under a single action group (Phase 4 / #304).
private struct InlineJobsView: View {
    let jobs: [ActiveJob]

    var body: some View {
        ForEach(jobs.prefix(5)) { job in
            InlineJobRowView(job: job)
        }
    }
}

// MARK: - InlineJobRowView

/// Single ↳ inline job sub-row (Phase 4 / #304).
private struct InlineJobRowView: View {
    let job: ActiveJob

    var body: some View {
        HStack(spacing: 6) {
            Text("↳")
                .font(.caption2).foregroundColor(.secondary)
                .padding(.leading, 14)
            PieProgressView(
                progress: stepProgress(for: job),
                color: jobDotColor(for: job),
                size: 7
            )
            Text(job.name)
                .font(.caption).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer()
            Text(job.status == "in_progress" ? "IN PROGRESS" : "QUEUED")
                .font(.caption)
                .foregroundColor(job.status == "in_progress" ? .yellow : .blue)
                .frame(width: 60, alignment: .trailing)
            Text(job.elapsed)
                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 2)
    }

    private func stepProgress(for job: ActiveJob) -> Double {
        let total = job.steps.count
        guard total > 0 else { return job.status == "in_progress" ? 0.5 : 0.0 }
        let done = job.steps.filter { $0.conclusion != nil }.count
        return Double(done) / Double(total)
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

/// Conditional runners sub-section — only shown when ≥1 Runner is busy/active (Phase 6 / #307).
/// Driven by RunnerStore.runners via RunnerStoreObservable — no LocalRunnerStore dependency.
private struct RunnersListView: View {
    /// GitHub runners from RunnerStore (not LocalRunnerStore).
    let runners: [Runner]

    /// Active runners: busy first, then online-only.
    private var activeRunners: [Runner] {
        runners.filter { $0.busy || $0.status == "online" }
    }

    var body: some View {
        if !activeRunners.isEmpty {
            Divider()
            ForEach(activeRunners, id: \.id) { runner in
                Button(
                    action: {},
                    label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(dotColor(for: runner))
                                .frame(width: 7, height: 7)
                            Text(runner.name)
                                .font(.system(size: 12)).foregroundColor(.primary)
                                .lineLimit(1).truncationMode(.tail)
                            Spacer()
                            Text(runner.busy ? "BUSY" : "ONLINE")
                                .font(.caption).foregroundColor(dotColor(for: runner))
                            Image(systemName: "chevron.right")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 3)
                    }
                )
                .buttonStyle(.plain)
            }
            .padding(.bottom, 6)
        }
    }

    private func dotColor(for runner: Runner) -> Color {
        runner.busy ? .yellow : .green
    }
}
