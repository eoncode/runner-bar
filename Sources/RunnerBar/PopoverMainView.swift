import ServiceManagement
import SwiftUI

// ⚠️ REGRESSION GUARD — frame + padding rules (ref #52 #54 #57)
//
// RULE 1: Root VStack MUST use .frame(idealWidth: 420)
//   AppDelegate reads hc.view.fittingSize in openPopover() to size the popover.
//   fittingSize reads SwiftUI's IDEAL size. Without idealWidth set, fittingSize
//   returns width=0 and AppDelegate falls back to fixedWidth.
//   ❌ NEVER remove .frame(idealWidth: 420) — fittingSize.width becomes 0
//   ❌ NEVER use .frame(width: 420) — sets layout width but NOT ideal width
//   ❌ NEVER use .frame(maxWidth: .infinity) alone — no ideal width = fittingSize.width=0
//   ❌ NEVER add .frame(height:) to root VStack — fights fittingSize height reading
//
// RULE 2: ALL rows use .padding(.horizontal, 12) — uniform across header/jobs/runners/scopes.
//   Mismatched padding causes visible left-alignment shift between states.
//   ❌ NEVER change one row's horizontal padding without changing ALL rows.
//
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
//   Removing it causes job name text to not fill row width.
//   ❌ NEVER remove the Spacer() inside the job row HStack.
//
// RULE 4: NEVER use .fixedSize() on any container.
//   Fights the frame architecture.
//
// RULE 5: RunnerStoreObservable.reload() uses withAnimation(nil).
//   NEVER add objectWillChange.send() to reload().
struct PopoverMainView: View {
    @ObservedObject var store: RunnerStoreObservable
    let onSelectJob: (ActiveJob) -> Void
    let onSelectAction: (ActionGroup) -> Void

    @State private var newScope = ""
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var isAuthenticated = (githubToken() != nil)
    @StateObject private var systemStats = SystemStatsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header
            HStack {
                Text("RunnerBar v0.34")  // ⚠️ bump on every commit
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
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)  // ⚠️ RULE 2

            Divider()

            // ── Rate limit warning (visible only when GitHub API quota is exhausted)
            if store.isRateLimited {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow).font(.caption)
                    Text("GitHub rate limit reached — pausing polls")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)  // ⚠️ RULE 2
                Divider()
            }

            // ── System
            Text("System")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)  // ⚠️ RULE 2
            SystemStatsView(stats: systemStats.stats)

            Divider()

            // ── Actions
            Text("Actions")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)  // ⚠️ RULE 2

            if store.actions.isEmpty {
                Text("No recent actions")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            } else {
                ForEach(store.actions.prefix(5)) { group in
                    Button(action: { onSelectAction(group) }) {
                        HStack(spacing: 8) {
                            actionDot(for: group)
                            Text(group.label)
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .frame(width: 52, alignment: .leading)
                            Text(group.title)
                                .font(.system(size: 12))
                                .foregroundColor(group.isDimmed ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.tail)
                            Spacer()  // ⚠️ RULE 3: load-bearing — do NOT remove
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
                            Image(systemName: "chevron.right")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 3)  // ⚠️ RULE 2
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 6)
            }

            Divider()

            // ── Active Jobs
            Text("Active Jobs")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)  // ⚠️ RULE 2

            if store.jobs.isEmpty {
                Text("No active jobs")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 4)  // ⚠️ RULE 2
            } else {
                ForEach(store.jobs.prefix(3)) { job in
                    Button(action: { onSelectJob(job) }) {
                        HStack(spacing: 8) {
                            jobDot(for: job)
                            Text(job.name)
                                .font(.system(size: 12))
                                .foregroundColor(job.isDimmed ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.tail)
                            Spacer()  // ⚠️ RULE 3: load-bearing — do NOT remove
                            Text(job.isDimmed ? conclusionLabel(for: job) : jobStatusLabel(for: job))
                                .font(.caption)
                                .foregroundColor(job.isDimmed ? conclusionColor(for: job) : jobStatusColor(for: job))
                                .frame(width: 76, alignment: .trailing)
                            Text(job.elapsed)
                                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                                .frame(width: 40, alignment: .trailing)
                            Image(systemName: "chevron.right")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 3)  // ⚠️ RULE 2
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
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)  // ⚠️ RULE 2
                ForEach(store.runners, id: \.id) { runner in
                    HStack(spacing: 8) {
                        Circle().fill(dotColor(for: runner)).frame(width: 8, height: 8)
                        Text(runner.name).font(.system(size: 13)).lineLimit(1)
                        Spacer()
                        Text(runner.displayStatus)
                            .font(.caption).foregroundColor(.secondary).lineLimit(1).fixedSize()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)  // ⚠️ RULE 2
                }
                Divider()
            }

            // ── Scopes
            VStack(alignment: .leading, spacing: 4) {
                Text("Scopes").font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8)  // ⚠️ RULE 2
                ForEach(ScopeStore.shared.scopes, id: \.self) { scope in
                    HStack {
                        Text(scope).font(.system(size: 12))
                        Spacer()
                        Button(action: { ScopeStore.shared.remove(scope); store.reload() }) {
                            Image(systemName: "minus.circle").foregroundColor(.red)
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 2)  // ⚠️ RULE 2
                }
                HStack {
                    TextField("owner/repo or org", text: $newScope)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                        .onSubmit { submitScope() }
                    Button(action: submitScope) { Image(systemName: "plus.circle") }
                        .buttonStyle(.plain)
                        .disabled(newScope.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)  // ⚠️ RULE 2
            }

            Divider()

            Toggle(isOn: $launchAtLogin) { Text("Launch at login").font(.system(size: 13)) }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 12).padding(.vertical, 8)  // ⚠️ RULE 2
                .onChange(of: launchAtLogin) { _ in LoginItem.toggle() }

            Divider()

            Button(action: { NSApplication.shared.terminate(nil) }) {
                HStack { Image(systemName: "xmark.square"); Text("Quit") }.font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
            .padding(.horizontal, 12).padding(.vertical, 8)  // ⚠️ RULE 2
        }
        // ⚠️ RULE 1: idealWidth=420 so fittingSize returns correct width.
        // Widened from 340 → 420 to prevent System stats row truncation.
        // fittingSize.height = VStack intrinsic height (used by openPopover()).
        // ❌ NEVER remove idealWidth — fittingSize.width collapses to 0.
        // ❌ NEVER add .frame(height:) — fights fittingSize height.
        .frame(idealWidth: 420, maxWidth: .infinity, alignment: .top)
        .onReceive(store.objectWillChange) { isAuthenticated = (githubToken() != nil) }
    }

    // MARK: — Helpers

    /// Returns a colored dot view reflecting the job's current state.
    /// Dimmed jobs (recently finished, fading out) use a secondary/gray dot.
    /// In-progress jobs use yellow; all other live states use gray.
    @ViewBuilder
    private func jobDot(for job: ActiveJob) -> some View {
        Circle().fill(job.isDimmed ? Color.secondary : (job.status == "in_progress" ? Color.yellow : Color.gray))
            .frame(width: 7, height: 7)
    }

    /// Returns a human-readable status label for a live (non-dimmed) job.
    /// Maps `in_progress` → "In Progress", `queued` → "Queued", anything else → "Done".
    private func jobStatusLabel(for job: ActiveJob) -> String {
        switch job.status { case "in_progress": return "In Progress"; case "queued": return "Queued"; default: return "Done" }
    }

    /// Returns the accent color for a live job's status label.
    /// In-progress jobs are yellow; queued/other states use secondary (dimmed).
    private func jobStatusColor(for job: ActiveJob) -> Color { job.status == "in_progress" ? .yellow : .secondary }

    /// Returns an icon + text label for a completed (dimmed) job's conclusion.
    /// Covers success, failure, cancelled, and skipped; falls back to the raw
    /// conclusion string or "done" if the value is unrecognised or nil.
    private func conclusionLabel(for job: ActiveJob) -> String {
        switch job.conclusion {
        case "success": return "✓ success"; case "failure": return "✗ failure"
        case "cancelled": return "⊗ cancelled"; case "skipped": return "− skipped"
        default: return job.conclusion ?? "done"
        }
    }

    /// Returns the accent color for a completed job's conclusion label.
    /// Success → green, failure → red, all other conclusions → secondary.
    private func conclusionColor(for job: ActiveJob) -> Color {
        switch job.conclusion { case "success": return .green; case "failure": return .red; default: return .secondary }
    }

    // MARK: — Action group row helpers

    /// Status dot for an action group row.
    @ViewBuilder
    private func actionDot(for group: ActionGroup) -> some View {
        let color: Color = {
            if group.isDimmed { return .secondary }
            switch group.groupStatus {
            case .inProgress: return .yellow
            case .queued:     return .gray
            case .completed:
                switch group.conclusion {
                case "success": return .green
                case "failure": return .red
                default:        return .secondary
                }
            }
        }()
        Circle().fill(color).frame(width: 7, height: 7)
    }

    /// Returns the status dot color for a self-hosted runner row.
    /// Offline runners are gray; online+busy runners are yellow; online+idle are green.
    private func dotColor(for runner: Runner) -> Color {
        runner.status != "online" ? .gray : (runner.busy ? .yellow : .green)
    }

    /// Opens Terminal and runs `gh auth login` to authenticate the user.
    /// Uses NSAppleScript to script Terminal because there is no direct API to
    /// launch an interactive CLI auth flow from a sandboxed menu bar process.
    /// Terminal is also brought to front so the user sees the prompt immediately.
    private func signInWithGitHub() {
        NSAppleScript(source: "tell application \"Terminal\" to do script \"gh auth login\"")?.executeAndReturnError(nil)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }

    /// Validates and persists a new scope entered by the user, then refreshes the store.
    /// Trims whitespace, guards against empty input, adds to `ScopeStore`, restarts
    /// `RunnerStore` polling for the new scope, reloads the observable, and clears the field.
    private func submitScope() {
        let t = newScope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        ScopeStore.shared.add(t); RunnerStore.shared.start(); store.reload(); newScope = ""
    }
}

// ⚠️ RULE 5: reload() uses withAnimation(nil). NEVER add objectWillChange.send().
final class RunnerStoreObservable: ObservableObject {
    @Published var runners: [Runner] = []
    @Published var jobs: [ActiveJob] = []
    @Published var actions: [ActionGroup] = []
    @Published var isRateLimited: Bool = false
    /// Initialises the observable and performs an eager reload so the view has
    /// data immediately on first render without waiting for a polling cycle.
    init() { reload() }
    func reload() {
        // ❌ NEVER add objectWillChange.send() here — @Published handles it
        withAnimation(nil) {
            runners       = RunnerStore.shared.runners
            jobs          = RunnerStore.shared.jobs
            actions       = RunnerStore.shared.actions
            isRateLimited = RunnerStore.shared.isRateLimited
        }
    }
}
