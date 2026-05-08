import SwiftUI

// ⚠️ REGRESSION GUARD — frame + padding rules (ref #52 #54 #57)
//
// RULE 1: Root VStack MUST use .frame(idealWidth: 420, maxWidth: .infinity, alignment: .top)
//         AppDelegate reads hc.view.fittingSize in openPopover() to size the popover.
//         ❌ NEVER remove .frame(idealWidth: 420)
//         ❌ NEVER use .frame(width: 420)
//         ❌ NEVER remove maxWidth: .infinity (VStack must stretch to full popover width)
//         ❌ NEVER add .frame(height:) to root VStack
//
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: NEVER use .fixedSize() on any container.
// RULE 5: RunnerStoreObservable.reload() uses withAnimation(nil).

// swiftlint:disable type_body_length
/// Root popover view — unified scrollable Actions list per issue #294.
///
/// Layout (top → bottom):
///   Header row  — CPU · MEM · DISK stats + ⚙ settings + × close
///   Runner row  — conditionally visible when any local runner is active
///   Divider
///   Scrollable actions list
///     each action row optionally expands ↳ in-progress jobs inline
///   "Load 10 more actions…" pagination stub (when > 10 groups)
///   Divider
///   Quit button
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
    /// How many action groups are currently visible (pagination).
    @State private var visibleCount: Int = 10
    /// Track which action groups have their inline jobs expanded.
    @State private var expandedGroupIDs: Set<String> = []

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            Divider()

            if store.isRateLimited {
                rateLimitBanner
                Divider()
            }

            localRunnerRow

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    actionsSection
                }
            }

            Divider()
            quitButton
        }
        .frame(idealWidth: 420, maxWidth: .infinity, alignment: .top)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            systemStats.start()
        }
    }

    // MARK: - Header

    /// Single header row: inline system stats left, ⚙ + × right.
    private var headerRow: some View {
        HStack(spacing: 6) {
            // Inline system stats — CPU · MEM · DISK
            systemStatsBadge
            Spacer()
            // Auth indicator
            if isAuthenticated {
                Circle().fill(Color.green).frame(width: 7, height: 7)
            } else {
                Button(action: signInWithGitHub) {
                    Circle().fill(Color.orange).frame(width: 7, height: 7)
                }
                .buttonStyle(.plain)
                .help("Sign in with GitHub")
            }
            // Settings
            Button(action: onSelectSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
            // Close
            Button(action: { NSApplication.shared.hide(nil) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
    }

    /// Compact inline stats badge: CPU · MEM · DISK values only (no bars).
    private var systemStatsBadge: some View {
        HStack(spacing: 8) {
            statChip(
                label: "CPU",
                value: String(format: "%.1f%%", systemStats.stats.cpuPct),
                pct: systemStats.stats.cpuPct
            )
            statChip(
                label: "MEM",
                value: String(
                    format: "%.1f/%.1fGB",
                    systemStats.stats.memUsedGB,
                    systemStats.stats.memTotalGB
                ),
                pct: systemStats.stats.memTotalGB > 0
                    ? (systemStats.stats.memUsedGB / systemStats.stats.memTotalGB) * 100 : 0
            )
            statChip(
                label: "DISK",
                value: String(
                    format: "%d/%dGB",
                    Int(systemStats.stats.diskUsedGB.rounded()),
                    Int(systemStats.stats.diskTotalGB.rounded())
                ),
                pct: systemStats.stats.diskTotalGB > 0
                    ? (systemStats.stats.diskUsedGB / systemStats.stats.diskTotalGB) * 100 : 0
            )
        }
    }

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

    // MARK: - Rate limit banner

    private var rateLimitBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow).font(.caption)
            Text("GitHub rate limit reached — pausing polls")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    // MARK: - Local runner row (Phase 6 stub — conditional)

    /// Shows only when at least one runner is online/busy. Hidden when all idle or no runners.
    @ViewBuilder
    private var localRunnerRow: some View {
        let activeRunners = store.runners.filter { $0.status == "online" }
        if !activeRunners.isEmpty {
            Divider()
            ForEach(activeRunners.prefix(3)) { runner in
                HStack(spacing: 8) {
                    Circle()
                        .fill(runner.busy ? Color.yellow : Color.green)
                        .frame(width: 8, height: 8)
                    Text(runner.name)
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer()
                    if let metrics = runner.metrics {
                        Text(String(format: "CPU: %.1f%%  MEM: %.1f%%",
                                    metrics.cpu, metrics.mem))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 3)
            }
            Divider()
        }
    }

    // MARK: - Actions section

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.actions.isEmpty {
                Text("No recent actions")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                let visible = Array(store.actions.prefix(visibleCount))
                ForEach(visible) { group in
                    actionRow(for: group)
                    // Inline ↳ job expansion for in-progress groups
                    if expandedGroupIDs.contains(group.id) {
                        inlineJobRows(for: group)
                    }
                }
                // Pagination
                if store.actions.count > visibleCount {
                    Button(action: { visibleCount += 10 }) {
                        Text("Load \(min(10, store.actions.count - visibleCount)) more actions…")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Action row

    private func actionRow(for group: ActionGroup) -> some View {
        Button(action: { onSelectAction(group) }) {
            HStack(spacing: 8) {
                actionDot(for: group)
                // Label (#PR or sha)
                Text(group.label)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(width: 52, alignment: .leading)
                // Title
                Text(group.title)
                    .font(.system(size: 12))
                    .foregroundColor(group.isDimmed ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer()
                // Current job name (in-progress / queued only)
                if group.groupStatus == .inProgress || group.groupStatus == .queued {
                    Text(group.currentJobName)
                        .font(.caption).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(minWidth: 0, maxWidth: 80, alignment: .trailing)
                }
                // Progress fraction
                Text(group.jobProgress)
                    .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    .frame(width: 30, alignment: .trailing)
                // Elapsed
                Text(group.elapsed)
                    .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    .frame(width: 40, alignment: .trailing)
                // Status label
                statusLabel(for: group)
                // Expand/collapse toggle for in-progress groups
                if group.groupStatus == .inProgress && !group.jobs.isEmpty {
                    Button(action: { toggleExpand(group.id) }) {
                        Image(systemName:
                            expandedGroupIDs.contains(group.id)
                                ? "chevron.down" : "chevron.right"
                        )
                        .font(.caption2).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Inline ↳ job rows

    private func inlineJobRows(for group: ActionGroup) -> some View {
        let activeJobs = group.jobs.filter {
            $0.status == "in_progress" || $0.status == "queued"
        }
        return ForEach(activeJobs.prefix(4)) { job in
            Button(action: { onSelectJob(job) }) {
                HStack(spacing: 6) {
                    // Indent indicator
                    Text("↳")
                        .font(.caption).foregroundColor(.secondary)
                        .frame(width: 16, alignment: .trailing)
                    jobDot(for: job)
                    Text(job.name)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer()
                    // Current step name
                    if let step = job.steps.first(where: { $0.status == "in_progress" }) {
                        Text(step.name)
                            .font(.caption2).foregroundColor(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                            .frame(minWidth: 0, maxWidth: 120, alignment: .trailing)
                    }
                    // Step progress
                    let doneSteps = job.steps.filter { $0.conclusion != nil }.count
                    let totalSteps = job.steps.count
                    if totalSteps > 0 {
                        Text("\(doneSteps)/\(totalSteps)")
                            .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                            .frame(width: 28, alignment: .trailing)
                    }
                    // Elapsed
                    Text(job.elapsed)
                        .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
                .padding(.leading, 24).padding(.trailing, 12).padding(.vertical, 2)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Quit

    private var quitButton: some View {
        Button(action: { NSApplication.shared.terminate(nil) }) {
            Text("Quit RunnerBar")
                .font(.system(size: 12)).foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: - Helpers

    private func toggleExpand(_ id: String) {
        if expandedGroupIDs.contains(id) {
            expandedGroupIDs.remove(id)
        } else {
            expandedGroupIDs.insert(id)
        }
    }

    @ViewBuilder
    private func actionDot(for group: ActionGroup) -> some View {
        Circle()
            .fill(actionDotColor(for: group))
            .frame(width: 8, height: 8)
    }

    @ViewBuilder
    private func jobDot(for job: ActiveJob) -> some View {
        Circle()
            .fill(jobDotColor(for: job))
            .frame(width: 7, height: 7)
    }

    @ViewBuilder
    private func statusLabel(for group: ActionGroup) -> some View {
        switch group.groupStatus {
        case .inProgress:
            Text("IN PROGRESS")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.yellow)
        case .queued:
            Text("QUEUED")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.blue)
        case .completed:
            let success = group.runs.allSatisfy { $0.conclusion == "success" }
            Text(success ? "SUCCESS" : "FAILED")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(success ? .green : .red)
        }
    }

    private func actionDotColor(for group: ActionGroup) -> Color {
        switch group.groupStatus {
        case .inProgress: return .yellow
        case .queued: return .blue
        case .completed:
            if group.isDimmed { return .gray }
            return group.runs.allSatisfy({ $0.conclusion == "success" }) ? .green : .red
        }
    }

    private func jobDotColor(for job: ActiveJob) -> Color {
        switch job.status {
        case "in_progress": return .yellow
        case "queued": return .blue
        default: return job.conclusion == "success" ? .green : (job.isDimmed ? .gray : .red)
        }
    }

    /// Usage color mirrors SystemStatsView thresholds: red >85%, yellow >60%, green ≤60%.
    private func usageColor(pct: Double) -> Color {
        if pct > 85 { return .red }
        if pct > 60 { return .yellow }
        return .green
    }

    private func signInWithGitHub() {
        let urlString = "https://docs.github.com/en/authentication/" +
            "keeping-your-account-and-data-secure/managing-your-personal-access-tokens"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
// swiftlint:enable type_body_length
