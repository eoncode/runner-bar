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

// swiftlint:disable type_body_length
/// Root popover view. Shows system stats, action groups, active jobs, runners, and scope settings.
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
    /// Local runner store — drives Phase 6 runners sub-section.
    @ObservedObject private var localRunners = LocalRunnerStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header: stats + optional auth badge + gear + close (Phase 2 / #299)
            HStack(spacing: 6) {
                SystemStatsView(stats: systemStats.stats).statsContent
                Spacer()
                // Show orange dot next to gear when not authenticated
                if !isAuthenticated {
                    Button(action: signInWithGitHub) {
                        Circle().fill(Color.orange).frame(width: 7, height: 7)
                    }
                    .buttonStyle(.plain)
                    .help("Not authenticated — tap to set up a GitHub token")
                }
                Button(action: onSelectSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings")
                // fix #3 (#311): hide popover instead of terminating the app
                Button(action: { NSApplication.shared.hide(nil) }, label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                })
                .buttonStyle(.plain)
                .help("Hide RunnerBar")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
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

            // ── Actions (no section label per spec #178)
            if store.actions.isEmpty {
                Text("No recent actions")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            } else {
                // Phase 5 (#305): ScrollView + visibleCount pagination
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        // Phase 3 (#302): redesigned action row
                        // Layout: [pie] SHA  title·····  startedAgo  elapsed  jobs  status ›
                        ForEach(store.actions.prefix(visibleCount)) { actionGroup in
                            Button(action: { onSelectAction(actionGroup) }, label: {
                                HStack(spacing: 6) {
                                    // Pie progress dot
                                    PieProgressView(
                                        progress: actionGroup.jobsTotal > 0
                                            ? Double(actionGroup.jobsDone) / Double(actionGroup.jobsTotal)
                                            : (actionGroup.groupStatus == .completed ? 1.0 : 0.0),
                                        color: actionDotColor(for: actionGroup)
                                    )
                                    // SHA / PR label
                                    Text(actionGroup.label)
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .frame(width: 46, alignment: .leading)
                                    // Commit / PR title
                                    Text(actionGroup.title)
                                        .font(.system(size: 12))
                                        .foregroundColor(actionGroup.isDimmed ? .secondary : .primary)
                                        .lineLimit(1).truncationMode(.tail)
                                    Spacer()
                                    // Started-ago timestamp
                                    Text(actionGroup.startedAgo)
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.secondary)
                                        .frame(width: 44, alignment: .trailing)
                                    // Elapsed MM:SS
                                    Text(actionGroup.elapsed)
                                        .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                                        .frame(width: 36, alignment: .trailing)
                                    // Job progress fraction
                                    Text(actionGroup.jobProgress)
                                        .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                                        .frame(width: 28, alignment: .trailing)
                                    // Status text — uppercase per spec #178 #302 #285 (fix #1)
                                    Text(actionStatusLabel(for: actionGroup))
                                        .font(.caption)
                                        .foregroundColor(actionStatusColor(for: actionGroup))
                                        .frame(width: 60, alignment: .trailing)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2).foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 3)
                            })
                            .buttonStyle(.plain)
                            // Phase 4 (#304): inline ↳ job rows for in-progress groups
                            if actionGroup.groupStatus == .inProgress || actionGroup.groupStatus == .queued {
                                ForEach(actionGroup.jobs.filter {
                                    $0.status == "in_progress" || $0.status == "queued"
                                }.prefix(3)) { job in
                                    Button(action: { onSelectJob(job) }, label: {
                                        HStack(spacing: 6) {
                                            // indent
                                            Text("↳")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .padding(.leading, 14)
                                            // fix #4 (#311): real step completion fraction
                                            let stepProgress: Double = {
                                                let total = job.steps.count
                                                guard total > 0 else {
                                                    return job.status == "in_progress" ? 0.5 : 0.0
                                                }
                                                let done = job.steps.filter { $0.conclusion != nil }.count
                                                return Double(done) / Double(total)
                                            }()
                                            PieProgressView(
                                                progress: stepProgress,
                                                color: jobDotColor(for: job),
                                                size: 7
                                            )
                                            Text(job.name)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1).truncationMode(.tail)
                                            Spacer()
                                            // fix #2 (#311): uppercase per spec
                                            Text(job.status == "in_progress" ? "IN PROGRESS" : "QUEUED")
                                                .font(.caption)
                                                .foregroundColor(job.status == "in_progress" ? .yellow : .blue)
                                                .frame(width: 60, alignment: .trailing)
                                            Text(job.elapsed)
                                                .font(.caption.monospacedDigit())
                                                .foregroundColor(.secondary)
                                                .frame(width: 36, alignment: .trailing)
                                            Image(systemName: "chevron.right")
                                                .font(.caption2).foregroundColor(.secondary)
                                        }
                                        .padding(.horizontal, 12).padding(.vertical, 2)
                                    })
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        // fix #6 (#311): static label — dynamic count can be wrong when store paginates
                        if store.actions.count > visibleCount {
                            Button(action: { visibleCount += 10 }, label: {
                                Text("Load 10 more actions…")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            })
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                        }
                    }
                }
                .frame(maxHeight: 400)
                .padding(.bottom, 6)
            }

            // ── Phase 6 (#307): Runners — only shown when ≥1 runner is active (no section label per spec)
            let activeRunners = localRunners.runners.filter { $0.isRunning }
            if !activeRunners.isEmpty {
                Divider()
                // fix #8 (#311): runner rows are tappable with > chevron
                ForEach(activeRunners) { runner in
                    Button(action: { /* onSelectRunner(runner) — no-op until runner detail view exists */ }, label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(runnerDotColor(for: runner))
                                .frame(width: 7, height: 7)
                            Text(runner.runnerName)
                                .font(.system(size: 12))
                                .foregroundColor(.primary)
                                .lineLimit(1).truncationMode(.tail)
                            Spacer()
                            Text(runner.statusDescription)
                                .font(.caption)
                                .foregroundColor(runnerDotColor(for: runner))
                            Image(systemName: "chevron.right")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 3)
                    })
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 6)
            }
        }
        .frame(idealWidth: 420, maxWidth: .infinity, alignment: .top)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            systemStats.start()
            Task { await localRunners.refresh() }
        }
        // fix #11 (#311): stop stats timer when popover is dismissed
        .onDisappear {
            systemStats.stop()
        }
    }

    // MARK: - Helpers

    /// Dot color for an action group based on its status.
    @ViewBuilder
    private func actionDot(for group: ActionGroup) -> some View {
        Circle()
            .fill(actionDotColor(for: group))
            .frame(width: 8, height: 8)
    }

    /// Dot color for a job based on its status.
    @ViewBuilder
    private func jobDot(for job: ActiveJob) -> some View {
        Circle()
            .fill(jobDotColor(for: job))
            .frame(width: 8, height: 8)
    }

    /// Human-readable status label for an action group.
    /// Returns uppercase strings per spec (#178 #302 #285). fix #1 (#311)
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

    /// Foreground color for an action group's status label.
    private func actionStatusColor(for group: ActionGroup) -> Color {
        switch group.groupStatus {
        case .inProgress: return .yellow
        case .queued:     return .blue
        case .completed:
            if group.isDimmed { return .secondary }
            return group.conclusion == "success" ? .green : .red
        }
    }

    /// Color for an action group's status dot.
    private func actionDotColor(for group: ActionGroup) -> Color {
        switch group.groupStatus {
        case .inProgress: return .yellow
        case .queued: return .blue
        case .completed:
            if group.isDimmed { return .gray }
            return group.runs.allSatisfy({ $0.conclusion == "success" }) ? .green : .red
        }
    }

    /// Dot color for a local runner based on its status.
    private func runnerDotColor(for runner: RunnerModel) -> Color {
        switch runner.statusColor {
        case .running:  return .green
        case .busy:     return .yellow
        case .idle:     return .secondary
        case .offline:  return .red
        }
    }

    /// Color for a job's status dot.
    private func jobDotColor(for job: ActiveJob) -> Color {
        switch job.status {
        case "in_progress": return .yellow
        case "queued": return .blue
        default: return job.conclusion == "success" ? .green : (job.isDimmed ? .gray : .red)
        }
    }

    /// Human-readable status label for a live job.
    private func jobStatusLabel(for job: ActiveJob) -> String {
        switch job.status {
        case "in_progress": return "IN PROGRESS"
        case "queued": return "QUEUED"
        default: return job.status.uppercased()
        }
    }

    /// Foreground color for a live job's status label.
    private func jobStatusColor(for job: ActiveJob) -> Color {
        switch job.status {
        case "in_progress": return .yellow
        case "queued": return .blue
        default: return .secondary
        }
    }

    /// Human-readable conclusion label for a completed/dimmed job.
    private func conclusionLabel(for job: ActiveJob) -> String {
        switch job.conclusion {
        case "success":   return "SUCCESS"
        case "failure":   return "FAILED"
        case "cancelled": return "CANCELED"
        case "skipped":   return "SKIPPED"
        default: return job.conclusion?.uppercased() ?? "DONE"
        }
    }

    /// Foreground color for a completed job's conclusion label.
    private func conclusionColor(for job: ActiveJob) -> Color {
        switch job.conclusion {
        case "success": return .green
        case "failure": return .red
        case "cancelled": return .orange
        default: return .secondary
        }
    }

    /// Opens the GitHub PAT setup docs in the default browser.
    /// NSAppleScript/Terminal removed — device-flow requires a user_code the app never generates.
    /// Auth.swift resolves token via: gh auth token → GH_TOKEN → GITHUB_TOKEN (ref #221 #246).
    private func signInWithGitHub() {
        let urlString = "https://docs.github.com/en/authentication/" +
            "keeping-your-account-and-data-secure/managing-your-personal-access-tokens"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
// swiftlint:enable type_body_length
