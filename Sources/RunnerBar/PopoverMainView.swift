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
                    Button(action: { onSelectAction(actionGroup) }) {
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
                    }
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
                    Button(action: { onSelectJob(job) }) {
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
                    }
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
                        Button(action: { ScopeStore.shared.remove(scopeStr); store.reload() }) {
                            Image(systemName: "minus.circle").foregroundColor(.red)
                        }.buttonStyle(.plain)
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
                Text("Launch at login").font(.system(size: 13))
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .onChange(of: launchAtLogin) { _ in LoginItem.toggle() }
            Divider()
            Button(action: { NSApplication.shared.terminate(nil) }) {
                HStack {
                    Image(systemName: "xmark.square"); Text("Quit")
                }.font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(idealWidth: 420, maxWidth: .infinity, alignment: .top)
        .onReceive(store.objectWillChange) { isAuthenticated = (githubToken() != nil) }
    }

    // MARK: - Helpers

    /// Returns a colored dot reflecting the job's current state.
    @ViewBuilder private func jobDot(for job: ActiveJob) -> some View {
        let dotFill: Color = {
            if job.isDimmed { return .secondary }
            return job.status == "in_progress" ? .yellow : .gray
        }()
        Circle().fill(dotFill).frame(width: 7, height: 7)
    }

    /// Returns a human-readable status label for a live job.
    private func jobStatusLabel(for job: ActiveJob) -> String {
        switch job.status {
        case "in_progress": return "In Progress"
        case "queued": return "Queued"
        default: return "Done"
        }
    }

    /// Returns the accent color for a live job's status label.
    private func jobStatusColor(for job: ActiveJob) -> Color {
        job.status == "in_progress" ? .yellow : .secondary
    }

    /// Returns an icon + text label for a completed job's conclusion.
    private func conclusionLabel(for job: ActiveJob) -> String {
        switch job.conclusion {
        case "success": return "✓ success"
        case "failure": return "✗ failure"
        case "cancelled": return "⊗ cancelled"
        case "skipped": return "− skipped"
        default: return job.conclusion ?? "done"
        }
    }

    /// Returns the accent color for a completed job's conclusion label.
    private func conclusionColor(for job: ActiveJob) -> Color {
        switch job.conclusion {
        case "success": return .green
        case "failure": return .red
        default: return .secondary
        }
    }

    // MARK: - Action group row helpers

    /// Status dot for an action group row.
    @ViewBuilder private func actionDot(for group: ActionGroup) -> some View {
        let dotFill: Color = {
            if group.isDimmed { return .secondary }
            switch group.groupStatus {
            case .inProgress: return .yellow
            case .queued: return .gray
            case .completed:
                switch group.conclusion {
                case "success": return .green
                case "failure": return .red
                default: return .secondary
                }
            default: return .secondary
            }
        }()
        Circle().fill(dotFill).frame(width: 7, height: 7)
    }

    /// Returns the status dot color for a runner row.
    private func dotColor(for runner: Runner) -> Color {
        runner.status != "online" ? .gray : (runner.busy ? .yellow : .green)
    }

    /// Opens Terminal and runs `gh auth login`.
    private func signInWithGitHub() {
        NSAppleScript(source: "tell application \"Terminal\" to do script \"gh auth login\"")?.executeAndReturnError(nil)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }

    /// Validates and persists a new scope, then refreshes the store.
    private func submitScope() {
        let trimmed = newScope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ScopeStore.shared.add(trimmed)
        RunnerStore.shared.start()
        store.reload()
        newScope = ""
    }
}

/// Observable bridge from `RunnerStore` singletons into SwiftUI `@ObservedObject`.
// ⚠️ RULE 5: reload() uses withAnimation(nil). NEVER add objectWillChange.send().
final class RunnerStoreObservable: ObservableObject {
    /// Mirrored runner list, published for SwiftUI diffing.
    @Published var runners: [Runner] = []
    /// Mirrored job list, published for SwiftUI diffing.
    @Published var jobs: [ActiveJob] = []
    /// Mirrored action group list, published for SwiftUI diffing.
    @Published var actions: [ActionGroup] = []
    /// Mirrored rate-limit flag, published for SwiftUI diffing.
    @Published var isRateLimited: Bool = false

    /// Initialises the observable with an eager reload so the view has data on first render.
    init() { reload() }

    /// Mirrors current RunnerStore state into @Published properties without an extra animation.
    func reload() {
        // ❌ NEVER add objectWillChange.send() here — @Published handles it
        withAnimation(nil) {
            runners = RunnerStore.shared.runners
            jobs = RunnerStore.shared.jobs
            actions = RunnerStore.shared.actions
            isRateLimited = RunnerStore.shared.isRateLimited
        }
    }
}
