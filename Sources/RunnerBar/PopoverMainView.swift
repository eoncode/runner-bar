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
                Button(action: { NSApplication.shared.terminate(nil) }, label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                })
                .buttonStyle(.plain)
                .help("Quit RunnerBar")
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

            // ── Actions
            Text("Actions")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
            if store.actions.isEmpty {
                Text("No recent actions")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            } else {
                ForEach(store.actions.prefix(5)) { actionGroup in
                    Button(action: { onSelectAction(actionGroup) }, label: {
                        HStack(spacing: 8) {
                            actionDot(for: actionGroup)
                            Text(actionGroup.label)
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .frame(width: 52, alignment: .leading)
                            Text(actionGroup.title)
                                .font(.system(size: 12))
                                .foregroundColor(actionGroup.isDimmed ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.tail)
                            Spacer()
                            if actionGroup.groupStatus == .inProgress
                                || actionGroup.groupStatus == .queued {
                                Text(actionGroup.currentJobName)
                                    .font(.caption).foregroundColor(.secondary)
                                    .lineLimit(1).truncationMode(.tail)
                                    .frame(minWidth: 0, maxWidth: 80, alignment: .trailing)
                            }
                            Text(actionGroup.jobProgress)
                                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                                .frame(width: 30, alignment: .trailing)
                            Text(actionGroup.elapsed)
                                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                                .frame(width: 40, alignment: .trailing)
                            Image(systemName: "chevron.right")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 3)
                    })
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 6)
            }
            Divider()

            // ── Active Jobs
            Text("Active Jobs")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
            if store.jobs.isEmpty {
                Text("No active jobs")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            } else {
                ForEach(store.jobs.prefix(3)) { job in
                    Button(action: { onSelectJob(job) }, label: {
                        HStack(spacing: 8) {
                            jobDot(for: job)
                            Text(job.name)
                                .font(.system(size: 12))
                                .foregroundColor(job.isDimmed ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.tail)
                            Spacer()
                            Text(job.isDimmed ? conclusionLabel(for: job) : jobStatusLabel(for: job))
                                .font(.caption)
                                .foregroundColor(
                                    job.isDimmed ? conclusionColor(for: job) : jobStatusColor(for: job)
                                )
                                .frame(width: 76, alignment: .trailing)
                            Text(job.elapsed)
                                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                                .frame(width: 40, alignment: .trailing)
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
        case "in_progress": return "Running"
        case "queued": return "Queued"
        default: return job.status.capitalized
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
        case "success": return "Success"
        case "failure": return "Failed"
        case "cancelled": return "Cancelled"
        case "skipped": return "Skipped"
        default: return job.conclusion?.capitalized ?? "Done"
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
