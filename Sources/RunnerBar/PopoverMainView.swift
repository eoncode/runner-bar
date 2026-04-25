import SwiftUI
import ServiceManagement

// ⚠️ REGRESSION GUARD — frame + padding rules (ref #52 #54 #57)
//
// RULE 1: Root VStack MUST use .frame(idealWidth: 340)
//   AppDelegate reads hc.view.fittingSize in openPopover() to size the popover.
//   fittingSize reads SwiftUI's IDEAL size. Without idealWidth set, fittingSize
//   returns width=0 and AppDelegate falls back to fixedWidth.
//   ❌ NEVER remove .frame(idealWidth: 340) — fittingSize.width becomes 0
//   ❌ NEVER use .frame(width: 340) — sets layout width but NOT ideal width
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

    @State private var newScope = ""
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var isAuthenticated = (githubToken() != nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header
            HStack {
                Text("RunnerBar v0.27")  // ⚠️ bump on every commit
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
        // ⚠️ RULE 1: idealWidth=340 so fittingSize returns correct width.
        // fittingSize.height = VStack intrinsic height (used by openPopover()).
        // ❌ NEVER remove idealWidth — fittingSize.width collapses to 0.
        // ❌ NEVER add .frame(height:) — fights fittingSize height.
        .frame(idealWidth: 340, maxWidth: .infinity, alignment: .top)
        .onReceive(store.objectWillChange) { isAuthenticated = (githubToken() != nil) }
    }

    // MARK: — Helpers

    @ViewBuilder
    private func jobDot(for job: ActiveJob) -> some View {
        Circle().fill(job.isDimmed ? Color.secondary : (job.status == "in_progress" ? Color.yellow : Color.gray))
            .frame(width: 7, height: 7)
    }
    private func jobStatusLabel(for job: ActiveJob) -> String {
        switch job.status { case "in_progress": return "In Progress"; case "queued": return "Queued"; default: return "Done" }
    }
    private func jobStatusColor(for job: ActiveJob) -> Color { job.status == "in_progress" ? .yellow : .secondary }
    private func conclusionLabel(for job: ActiveJob) -> String {
        switch job.conclusion {
        case "success": return "✓ success"; case "failure": return "✗ failure"
        case "cancelled": return "⊗ cancelled"; case "skipped": return "− skipped"
        default: return job.conclusion ?? "done"
        }
    }
    private func conclusionColor(for job: ActiveJob) -> Color {
        switch job.conclusion { case "success": return .green; case "failure": return .red; default: return .secondary }
    }
    private func dotColor(for runner: Runner) -> Color {
        runner.status != "online" ? .gray : (runner.busy ? .yellow : .green)
    }
    private func signInWithGitHub() {
        NSAppleScript(source: "tell application \"Terminal\" to do script \"gh auth login\"")?.executeAndReturnError(nil)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }
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
    init() { reload() }
    func reload() {
        // ❌ NEVER add objectWillChange.send() here — @Published handles it
        withAnimation(nil) {
            runners = RunnerStore.shared.runners
            jobs    = RunnerStore.shared.jobs
        }
    }
}
