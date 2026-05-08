import SwiftUI

// swiftlint:disable file_length
// Reason: PopoverMainView and all its private sub-views live in one file for
// co-location. Each struct is small; the total line count reflects SwiftUI
// verbosity, not unrelated code. Splitting would hurt navigability.

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

/// Root popover view. Shows system stats, runners, action groups, inline jobs, and scope settings.
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
            // ⚠️ SPEC ORDER (#296): Runners section ABOVE actions list.
            RunnersListView(runners: store.runners)
            ActionsListView(
                actions: store.actions,
                visibleCount: $visibleCount,
                expandedGroups: $expandedGroups,
                onSelectAction: onSelectAction
            )
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
        // Reset pagination when the action list is replaced by a fresh store poll.
        .onChange(of: store.actions.count) { _ in visibleCount = 10 }
    }
}

// MARK: - PopoverHeaderView

/// Header row: system stats + auth dot + gear + close (Phase 2 / #299).
private struct PopoverHeaderView: View {
    /// System stats view-model for CPU/MEM/DISK display.
    let systemStats: SystemStatsViewModel
    /// Whether a GitHub token is present; drives the orange auth-warning dot.
    let isAuthenticated: Bool
    /// Called when the user taps the gear or the orange auth dot.
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
            // ⚠️ hide() is intentional for a menu-bar app — keeps the process alive.
            // terminate(nil) would quit the app; hide(nil) just closes the popover.
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
}

// MARK: - ActionsListView

/// Scrollable actions list with per-group expand/collapse and pagination (Phase 3–5 / #302 #304 #305).
private struct ActionsListView: View {
    /// Action groups from the store (full list; view enforces display cap via visibleCount).
    let actions: [ActionGroup]
    /// Number of rows currently shown; incremented by 10 on "Load more".
    @Binding var visibleCount: Int
    /// IDs of groups whose inline job sub-rows are expanded.
    @Binding var expandedGroups: Set<String>
    /// Called when the user taps an action group row.
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
                    // Phase 5 (#305): pagination footer
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
                        // All actions loaded — replace button with muted end-of-list label.
                        Text("No more actions")
                            .font(.caption2).foregroundColor(.secondary.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 6)
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
    /// The action group this row represents.
    let actionGroup: ActionGroup
    /// Whether the inline job sub-rows are currently expanded.
    let isExpanded: Bool
    /// Toggles the expanded state for this group's inline jobs.
    let onToggleExpand: () -> Void
    /// Navigates to the action detail view.
    let onSelect: () -> Void

    /// Whether this group has expandable inline ↳ rows.
    /// ⚠️ Gap 2 fix (#323 / #304): only in_progress jobs qualify — queued jobs are excluded.
    private var hasInlineJobs: Bool {
        actionGroup.groupStatus == .inProgress &&
            actionGroup.jobs.contains { $0.status == "in_progress" }
    }

    // swiftlint:disable:next function_body_length
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
                // ⚠️ Gap 2 fix (#323 / #304): pass only in_progress jobs to InlineJobsView.
                InlineJobsView(jobs: actionGroup.jobs.filter { $0.status == "in_progress" })
            }
        }
    }

    /// Short status label shown in the trailing column of an action row.
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

    /// Foreground color for the trailing status label of an action row.
    private func actionStatusColor(for group: ActionGroup) -> Color {
        switch group.groupStatus {
        case .inProgress: return .yellow
        case .queued:     return .blue
        case .completed:
            if group.isDimmed { return .secondary }
            return group.conclusion == "success" ? .green : .red
        }
    }

    /// Fill color for the pie-progress dot of an action row.
    private func actionDotColor(for group: ActionGroup) -> Color {
        switch group.groupStatus {
        case .inProgress: return .yellow
        case .queued:     return .blue
        case .completed:
            if group.isDimmed { return .gray }
            // ⚠️ Use group.conclusion (the merged conclusion), NOT runs.allSatisfy —
            // the latter mis-labels partial-success groups as red (fixed #311).
            return group.conclusion == "success" ? .green : .red
        }
    }
}

// MARK: - InlineJobsView

/// Container for all inline ↳ job sub-rows under a single action group (Phase 4 / #304).
/// ⚠️ Receives only in_progress jobs — caller is responsible for pre-filtering.
private struct InlineJobsView: View {
    /// Pre-filtered in_progress jobs to render as ↳ child rows (max 5 shown).
    let jobs: [ActiveJob]

    var body: some View {
        ForEach(jobs.prefix(5)) { job in
            InlineJobRowView(job: job)
        }
    }
}

// MARK: - InlineJobRowView

/// Single ↳ inline job sub-row (Phase 4 / #304).
/// Shows: ↳ · pie-dot · job-name · current-step-title · step-fraction · elapsed.
/// ⚠️ Gap 1 fix (#323 / #304): replaced IN PROGRESS/QUEUED status label with
///   step title + step fraction as specified in #304 acceptance criteria.
private struct InlineJobRowView: View {
    /// The in_progress job this row represents.
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
            // Step title: first in_progress step name, or last completed step name.
            Text(currentStepTitle(for: job))
                .font(.caption).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.tail)
            // Step fraction e.g. "3/8"
            Text(stepFraction(for: job))
                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                .frame(width: 30, alignment: .trailing)
            Text(job.elapsed)
                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 2)
    }

    /// Completion fraction 0.0–1.0 based on steps with a non-nil conclusion.
    /// Falls back to 0.5 when in_progress with no step data, or 0.0 when queued.
    private func stepProgress(for job: ActiveJob) -> Double {
        let total = job.steps.count
        guard total > 0 else { return job.status == "in_progress" ? 0.5 : 0.0 }
        let done = job.steps.filter { $0.conclusion != nil }.count
        return Double(done) / Double(total)
    }

    /// Step fraction label, e.g. `"3/8"`. Returns `""` when no step data is available.
    private func stepFraction(for job: ActiveJob) -> String {
        let total = job.steps.count
        guard total > 0 else { return "" }
        let done = job.steps.filter { $0.conclusion != nil }.count
        return "\(done)/\(total)"
    }

    /// Name of the first `in_progress` step; falls back to the last completed step;
    /// falls back to an em-dash when no step data is available.
    private func currentStepTitle(for job: ActiveJob) -> String {
        if let active = job.steps.first(where: { $0.status == "in_progress" }) {
            return active.name
        }
        if let last = job.steps.last(where: { $0.conclusion != nil }) {
            return last.name
        }
        return "—"
    }

    /// Fill color for the inline job’s pie-progress dot.
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
/// Spec: section is hidden entirely when no runners are active (busy = executing a job).
/// Online-idle runners are intentionally excluded — presence = running.
/// Driven by RunnerStore.runners via RunnerStoreObservable — no LocalRunnerStore dependency.
/// ⚠️ Runner row navigation is intentionally disabled until #307 detail view is implemented.
/// The chevron signals future navigability but the button is disabled to avoid no-op taps.
private struct RunnersListView: View {
    /// GitHub runners from RunnerStore (not LocalRunnerStore).
    let runners: [Runner]

    /// Runners currently executing a job (`busy == true`).
    /// Online-idle runners are excluded per spec (#307).
    private var activeRunners: [Runner] {
        runners.filter { $0.busy }
    }

    var body: some View {
        if !activeRunners.isEmpty {
            Divider()
            ForEach(activeRunners, id: \.id) { runner in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.yellow)
                        .frame(width: 7, height: 7)
                    Text(runner.name)
                        .font(.system(size: 12)).foregroundColor(.primary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer()
                    // ⚠️ Gap 4 fix (#323 / #307): show CPU% + MEM% from runner.metrics.
                    // Falls back to em-dash when no matching ps aux process was found.
                    if let m = runner.metrics {
                        Text(String(format: "CPU: %.1f%%", m.cpu))
                            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        Text(String(format: "MEM: %.1f%%", m.mem))
                            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    } else {
                        Text("CPU: — MEM: —")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    // ⚠️ Chevron shown for future navigability (#307 detail view not yet implemented)
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundColor(.secondary.opacity(0.4))
                }
                .padding(.horizontal, 12).padding(.vertical, 3)
            }
            .padding(.bottom, 6)
        }
    }
}

// swiftlint:enable file_length
