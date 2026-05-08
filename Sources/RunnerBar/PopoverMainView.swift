import SwiftUI

// ⚠️ REGRESSION GUARD — frame + padding rules (ref #52 #54 #57)
//
// RULE 1: Root VStack MUST use .frame(idealWidth: 420, maxWidth: .infinity, alignment: .top)
//         AppDelegate reads hc.view.fittingSize in openPopover() to size the popover.
//         ❌ NEVER remove .frame(idealWidth: 420)
//         ❌ NEVER use .frame(width: 420)
//         ❌ NEVER remove maxWidth: .infinity
//         ❌ NEVER add .frame(height:) to root VStack
//
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: NEVER use .fixedSize() on any container.
// RULE 5: RunnerStoreObservable.reload() uses withAnimation(nil).

/// Root popover view — unified scrollable Actions list per issue #294.
struct PopoverMainView: View {
    @ObservedObject var store: RunnerStoreObservable
    let onSelectJob: (ActiveJob) -> Void
    let onSelectAction: (ActionGroup) -> Void
    let onSelectSettings: () -> Void

    @State private var isAuthenticated = (githubToken() != nil)
    @StateObject private var systemStats = SystemStatsViewModel()
    @State private var visibleCount: Int = 10
    @State private var expandedGroupIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            Divider()
            if store.isRateLimited { rateLimitBanner; Divider() }
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

    private var headerRow: some View {
        HStack(spacing: 6) {
            systemStatsBadge
            Spacer()
            if isAuthenticated {
                Circle().fill(Color.green).frame(width: 7, height: 7)
            } else {
                Button(
                    action: signInWithGitHub,
                    label: { Circle().fill(Color.orange).frame(width: 7, height: 7) }
                )
                .buttonStyle(.plain)
                .help("Sign in with GitHub")
            }
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

    // MARK: - Local runner row

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
                    ActionRowView(
                        group: group,
                        isExpanded: expandedGroupIDs.contains(group.id),
                        onSelect: { onSelectAction(group) },
                        onToggleExpand: { toggleExpand(group.id) }
                    )
                    if expandedGroupIDs.contains(group.id) {
                        InlineJobRowsView(
                            group: group,
                            onSelectJob: onSelectJob
                        )
                    }
                }
                if store.actions.count > visibleCount {
                    Button(
                        action: { visibleCount += 10 },
                        label: {
                            Text("Load \(min(10, store.actions.count - visibleCount)) more actions…")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    )
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Quit

    private var quitButton: some View {
        Button(
            action: { NSApplication.shared.terminate(nil) },
            label: {
                Text("Quit RunnerBar")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
        )
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

// MARK: - ActionRowView

/// Extracted to satisfy SwiftLint file_length (<400 lines) and
/// multiple_closures_with_trailing_closure rules.
private struct ActionRowView: View {
    let group: ActionGroup
    let isExpanded: Bool
    let onSelect: () -> Void
    let onToggleExpand: () -> Void

    var body: some View {
        Button(action: onSelect, label: { rowContent })
            .buttonStyle(.plain)
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
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
            if group.groupStatus == .inProgress && !group.jobs.isEmpty {
                Button(action: onToggleExpand, label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundColor(.secondary)
                })
                .buttonStyle(.plain)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 3)
    }

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

private struct InlineJobRowsView: View {
    let group: ActionGroup
    let onSelectJob: (ActiveJob) -> Void

    private var activeJobs: [ActiveJob] {
        group.jobs.filter { $0.status == "in_progress" || $0.status == "queued" }
    }

    var body: some View {
        ForEach(activeJobs.prefix(4)) { job in
            Button(action: { onSelectJob(job) }, label: { jobRow(job) })
                .buttonStyle(.plain)
        }
    }

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

    private func jobDotColor(for job: ActiveJob) -> Color {
        switch job.status {
        case "in_progress": return .yellow
        case "queued": return .blue
        default: return job.conclusion == "success" ? .green : (job.isDimmed ? .gray : .red)
        }
    }
}
