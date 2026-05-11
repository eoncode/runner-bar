import SwiftUI

// ⚠️ REGRESSION GUARD — frame + layout rules (ref #52 #54 #57 #296 #376 #377)
//
// ARCHITECTURE IN USE: Architecture 2 — Dynamic Size (AppDelegate-owned)
// (per status-bar-app-position-warning.md §4 Architecture 2)
//
// RULE 1: Root VStack MUST use .fixedSize(horizontal: false, vertical: true)
//   This tells SwiftUI/AppKit to use the VStack’s natural content height.
//   AppDelegate calls sizeThatFits(width:420, height:.greatestFiniteMagnitude) which
//   returns the correct dynamic height. Without fixedSize, the view expands to fill
//   the current popover frame and sizeThatFits returns the frame height — never changes.
// ❌ NEVER remove .fixedSize(horizontal: false, vertical: true) from the root VStack.
// ❌ NEVER use .frame(maxHeight: .infinity) on the root — defeats fixedSize measurement.
//
// RULE 2: ActionsListView uses plain VStack (NO ScrollView).
//   ScrollView reports infinite preferred height → kills dynamic sizing.
//   Height cap via .frame(maxHeight: 480, alignment: .top) on ActionsListView is correct.
// ❌ NEVER wrap ActionsListView in ScrollView.
//
// RULE 3: ALL rows use .padding(.horizontal, 12)
// RULE 4: Job row HStack Spacer() is LOAD-BEARING.
// RULE 5: RunnerStoreObservable.reload() uses withAnimation(nil).
//
// SYSTEMSTATSVIEWMODEL RULE (ref #375 #376 #377 — CPU GUARD):
//   PopoverMainView receives isPopoverOpen: Bool from AppDelegate.
//   .onChange(of: isPopoverOpen) stops systemStats when open, restarts when closed.
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

    // ⚠️ CPU GUARD: gate systemStats on popover open state.
    // ❌ NEVER remove this property.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    // UNDER ANY CIRCUMSTANCE.
    var isPopoverOpen: Bool = false

    @State private var isAuthenticated = (githubToken() != nil)
    @StateObject private var systemStats = SystemStatsViewModel()
    @State private var visibleCount: Int = 10

    var body: some View {
        // ⚠️ .fixedSize(horizontal: false, vertical: true) on this VStack is REQUIRED.
        //   It lets sizeThatFits(width:420, height:.infinity) return the natural content height.
        //   Without it, the VStack fills the popover frame and the measured height never changes.
        // ❌ NEVER remove .fixedSize from this VStack.
        // ❌ NEVER add .frame(maxHeight: .infinity) to this VStack.
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
            ActionsListView(
                actions: store.actions,
                visibleCount: $visibleCount,
                onSelectAction: onSelectAction
            )
            .frame(maxHeight: 480, alignment: .top)
        }
        // ⚠️ CRITICAL: fixedSize allows AppKit to measure natural content height.
        // ❌ NEVER remove this modifier.
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 420)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
        }
        .onDisappear {
            systemStats.stop()
        }
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

// ⚠️ NO ScrollView here — ScrollView swallows content height, breaking sizeThatFits. (ref #376 #377)
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
