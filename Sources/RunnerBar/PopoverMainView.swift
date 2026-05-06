import ServiceManagement
import SwiftUI

// ⚠️ REGRESSION GUARD — frame + padding rules (ref #52 #54 #57)
//
// RULE 1: Root VStack MUST use .frame(idealWidth: 420)
// AppDelegate reads hc.view.fittingSize in openPopover() to size the popover.
// ❌ NEVER remove .frame(idealWidth: 420)
// ❌ NEVER use .frame(width: 420)
// ❌ NEVER use .frame(maxWidth: .infinity) alone
// ❌ NEVER add .frame(height:) to root VStack
//
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: NEVER use .fixedSize() on any container.
// RULE 5: RunnerStoreObservable.reload() uses withAnimation(nil).

/// Root popover view. Shows system stats, action groups, active jobs, runners, and scope settings.
// swiftlint:disable:next type_body_length
struct PopoverMainView: View {
    /// The observable that bridges RunnerStore state into SwiftUI.
    @ObservedObject var store: RunnerStoreObservable
    /// Called when the user taps a job row to drill into job detail.
    let onSelectJob: (ActiveJob) -> Void
    /// Called when the user taps an action group row to drill into action detail.
    let onSelectAction: (ActionGroup) -> Void

    @State private var newScope = ""
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var isAuthenticated = (githubToken() != nil)
    @StateObject private var systemStats = SystemStatsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header
            HStack {
                Text("RunnerBar v0.34") // ⚠️ bump on every commit
                    .font(.headline).foregroundColor(.secondary)
                Spacer()
                if isAuthenticated {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text("Authenticated").font(.caption).foregroundColor(.secondary)
                    }
                } else {
                    Button(action: signInWithGitHub) {
                        HStack(spacing: 4) {
                            Circle().fill(Color.orange).frame(width: 8, height: 8)
                            Text("Sign in with GitHub").font(.caption).foregroundColor(.orange)
                        }
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
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

            // ── System
            Text("System")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
            SystemStatsView(stats: systemStats.stats)
            Divider()

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
            Divider()

            // ── Runners
            if !store.runners.isEmpty {
                Text("Local runners")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
                ForEach(store.runners, id: \.id) { runner in
                    HStack(spacing: 8) {
                        Circle().fill(dotColor(for: runner)).frame(width: 8, height: 8)
                        Text(runner.name).font(.system(size: 13)).lineLimit(1)
                        Spacer()
                        Text(runner.displayStatus)
                            .font(.caption).foregroundColor(.secondary).lineLimit(1).fixedSize()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                }
                Divider()
            }

            // ── Scopes
            VStack(alignment: .leading, spacing: 4) {
                Text("Scopes").font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8)
                ForEach(ScopeStore.shared.scopes, id: \.self) { scopeStr in
                    HStack {
                        Text(scopeStr).font(.system(size: 12))
                        Spacer()
                        Button(action: { ScopeStore.shared.remove(scopeStr); store.reload() }, label: {
                            Image(systemName: "minus.circle").foregroundColor(.red)
                        }).buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 2)
                }
                HStack {
                    TextField("owner/repo or org", text: $newScope)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                        .onSubmit { submitScope() }
                    Button(action: submitScope) {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .disabled(newScope.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
            }
            Divider()
            Toggle(isOn: $launchAtLogin) {
                Text("Launch at login").font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .onChange(of: launchAtLogin) { _, newValue in
                LoginItem.setEnabled(newValue)
            }
            Button(action: { NSApplication.shared.terminate(nil) }, label: {
                Text("Quit RunnerBar").font(.system(size: 12)).foregroundColor(.secondary)
            })
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .frame(idealWidth: 420)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            systemStats.start()
        }
    }

    // MARK: - Helpers

    /// Submits a new scope from the text field.
    private func submitScope() {
        let trimmed = newScope.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        ScopeStore.shared.add(trimmed)
        store.reload()
        newScope = ""
    }

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

    /// Runner status dot color.
    private func dotColor(for runner: Runner) -> Color {
        runner.status != "online" ? .gray : (runner.busy ? .yellow : .green)
    }

    /// Opens Terminal and runs `gh auth login`.
    private func signInWithGitHub() {
        let script = "tell application \"Terminal\" to do script \"gh auth login\""
        NSAppleScript(source: script)?.executeAndReturnError(nil)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }

    /// Validates and persists a new scope, then refreshes the store.
    private func validateAndAddScope(_ scope: String) {
        guard scope.contains("/") || !scope.isEmpty else { return }
        ScopeStore.shared.add(scope)
        store.reload()
    }
}
