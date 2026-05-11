import SwiftUI

// ⚠️ REGRESSION GUARD — frame + layout rules (ref #52 #54 #57 #296 #376 #377)
//
// ARCHITECTURE IN USE: Architecture 1 — Fully Dynamic Height (SwiftUI-driven)
// (per status-bar-app-position-warning.md §4 Architecture 1)
//
// RULE 1: Root Group/VStack MUST use .frame(idealWidth: 420)
//   NSHostingController.sizingOptions = .preferredContentSize reads SwiftUI ideal size.
//   .frame(idealWidth: 420) pins preferredContentSize.width = 420 always, regardless
//   of which nav state is active. Width never changes → no NSPopover re-anchor → no jump.
//   Height varies freely with content → no empty space or clipping.
// ❌ NEVER use .frame(width: 420) — layout width ≠ ideal width, causes unstable width.
// ❌ NEVER add .frame(height:) or .frame(maxHeight:) to the root VStack.
// ❌ NEVER remove .frame(idealWidth: 420).
//
// RULE 2: ActionsListView uses plain VStack (NO ScrollView).
//   ScrollView reports infinite preferred height to SwiftUI → kills dynamic height.
//   Height cap via .frame(maxHeight: 480, alignment: .top) on ActionsListView is correct.
//   fixedSize(horizontal: false, vertical: true) lets it measure natural content height.
// ❌ NEVER wrap ActionsListView in ScrollView.
// ❌ NEVER remove fixedSize from ActionsListView.
//
// RULE 3: ALL rows use .padding(.horizontal, 12)
// RULE 4: Job row HStack Spacer() is LOAD-BEARING.
// RULE 5: RunnerStoreObservable.reload() uses withAnimation(nil).
// RULE 6: Detail views use .frame(idealWidth: 420, minHeight: X) — fixed height is
//   acceptable there because they have their own internal ScrollView.
//
// INLINE JOBS SPEC (#178):
//   Show ↳ job rows ONLY for jobs with status == "in_progress".
// ❌ NEVER show queued jobs inline.
//
// SYSTEMSTATSVIEWMODEL RULE (ref #375 #376 #377 — THE FIX FOR POSITION JUMPS):
//   SystemStatsViewModel fires @Published updates every ~1s via a Timer.
//   Each update triggers a SwiftUI layout pass → new preferredContentSize.height
//   → NSPopover re-anchors the window → visible left/position jump.
//   The popoverIsOpen guard in AppDelegate only blocks store.reload().
//   It does NOT block systemStats from pushing layout passes while the popover is shown.
//   FIX: PopoverMainView receives isPopoverOpen: Bool from AppDelegate.
//        .onChange(of: isPopoverOpen) stops systemStats when the popover opens
//        and restarts it when the popover closes.
// ❌ NEVER remove the .onChange(of: isPopoverOpen) block.
// ❌ NEVER call systemStats.start() inside .onAppear without the isPopoverOpen guard.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.

/// Root popover view. Shows system stats, runners, action groups, inline jobs, and scope settings.
struct PopoverMainView: View {
    @ObservedObject var store: RunnerStoreObservable
    let onSelectJob: (ActiveJob) -> Void
    let onSelectAction: (ActionGroup) -> Void
    let onSelectSettings: () -> Void

    // ⚠️ FIX: Receive popover open state from AppDelegate so we can gate systemStats.
    // AppDelegate passes `isPopoverOpen: popoverIsOpen` when constructing this view.
    // ❌ NEVER remove this property — it is the gate for systemStats.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    // UNDER ANY CIRCUMSTANCE.
    var isPopoverOpen: Bool = false

    @State private var isAuthenticated = (githubToken() != nil)
    @StateObject private var systemStats = SystemStatsViewModel()
    @State private var visibleCount: Int = 10

    var body: some View {
        // ⚠️ Architecture 1 root container:
        //   .frame(idealWidth: 420) pins preferredContentSize.width = 420 always.
        //   No height modifier here — height is fully driven by content.
        // ❌ NEVER use .frame(width: 420) here.
        // ❌ NEVER add .frame(height:) or .frame(maxHeight:) here.
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
            RunnersListView(runners: store.runners)
            // ⚠️ fixedSize(horizontal: false, vertical: true) lets SwiftUI measure
            //   the natural content height of the list so preferredContentSize.height
            //   is correct. maxHeight caps growth. alignment: .top prevents centering.
            // ❌ NEVER wrap in ScrollView.
            // ❌ NEVER remove fixedSize.
            ActionsListView(
                actions: store.actions,
                visibleCount: $visibleCount,
                onSelectAction: onSelectAction
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: 480, alignment: .top)
        }
        .frame(idealWidth: 420)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            // ⚠️ FIX: Do NOT start systemStats here unconditionally.
            // .onAppear fires when popover opens (isPopoverOpen already true at that point).
            // The .onChange(of: isPopoverOpen) block below handles start/stop correctly.
            // Starting here would immediately undo the stop from onChange.
            // systemStats is started when isPopoverOpen becomes false (popover closes)
            // so it is already running before the next open.
        }
        .onDisappear {
            // Always stop on disappear as a safety net (covers app quit / nav away).
            systemStats.stop()
        }
        // ⚠️ FIX: Gate systemStats on popover open state.
        //   When popover opens (isPopoverOpen = true): STOP the timer.
        //     → No @Published updates → no SwiftUI layout passes → no preferredContentSize
        //       changes → no NSPopover re-anchor → no position jump.
        //   When popover closes (isPopoverOpen = false): START the timer.
        //     → Stats update in the background while popover is hidden.
        //     → On next open, one fresh render is done before show() is called (in openPopover).
        // ❌ NEVER remove this .onChange block.
        // ❌ NEVER call systemStats.start() unconditionally in .onAppear.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
        // is major major major.
        .onChange(of: isPopoverOpen) { open in
            if open {
                systemStats.stop()
            } else {
                systemStats.start()
            }
        }
        .onChange(of: store.actions) { _ in
            if visibleCount > 10 { visibleCount = 10 }
        }
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

// ⚠️ NO ScrollView here — ScrollView swallows content height, preventing
// SwiftUI from reporting correct preferredContentSize.height to NSPopover.
// Height cap and fixedSize are applied by the caller (PopoverMainView). (ref #376 #377)
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
                            Text("Load 10 more actions\u{2026}")
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
            .padding(.bottom, 6)
        }
    }
}

// MARK: - ActionRowView

/// Single action group row.
/// ⚠️ Inline ↳ job rows shown ONLY for jobs with status == "in_progress".
/// ❌ NEVER change filter to conclusion==nil — queued jobs must not appear inline per spec #178.
private struct ActionRowView: View {
    let actionGroup: ActionGroup
    let onSelect: () -> Void

    private var inProgressJobs: [ActiveJob] {
        actionGroup.jobs.filter { $0.status == "in_progress" }
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

            if !inProgressJobs.isEmpty {
                InlineJobsView(jobs: inProgressJobs)
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
                color: .yellow,
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
        return "Starting\u{2026}"
    }
}

// MARK: - RunnersListView

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
                        Text("CPU: \u{2014} MEM: \u{2014}").font(.caption).foregroundColor(.secondary)
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
