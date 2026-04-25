import SwiftUI
import ServiceManagement

// ⚠️ REGRESSION GUARD — layout rules (ref issues #52 #54 #57)
//
// 1. NEVER add .frame(height:) anywhere in this file.
//    Height is owned exclusively by AppDelegate.computeMainHeight().
//    This view fills AppDelegate’s frame via .frame(maxWidth/maxHeight: .infinity).
//
// 2. The Spacer() inside each job row HStack is load-bearing.
//    Removing it causes text to left-align when job names change.
//
// 3. All rows use .padding(.horizontal, 12) — keep uniform across every row.
//    Mismatched padding causes visible column shifts between states.
//
// 4. NEVER use .fixedSize(horizontal: true, ...) on any container.
//    Dynamic width causes the popover anchor to drift left.
//
// 5. If you change ANY padding value here, update the pixel budget comment
//    in AppDelegate.swift (computeMainHeight) or sizing will be wrong.
struct PopoverMainView: View {
    @ObservedObject var store: RunnerStoreObservable
    let onSelectJob: (ActiveJob) -> Void

    @State private var newScope = ""
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var isAuthenticated = (githubToken() != nil)
    @State private var tick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            HStack {
                Text("RunnerBar v0.18")  // ⚠️ bump on every commit
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
            // ⚠️ header height ≈ 44px (12+~20+8) — must match AppDelegate.computeMainHeight budget

            Divider()

            Text("Active Jobs")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
            // ⚠️ jobs label ≈ 26px — must match AppDelegate.computeMainHeight budget

            if store.jobs.isEmpty {
                Text("No active jobs")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                // ⚠️ empty row ≈ 22px — must match AppDelegate.computeMainHeight budget
            } else {
                ForEach(store.jobs.prefix(3)) { job in
                    Button(action: { onSelectJob(job) }) {
                        HStack(spacing: 8) {
                            jobDot(for: job)
                            Text(job.name)
                                .font(.system(size: 12))
                                .foregroundColor(job.isDimmed ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.tail)
                            Spacer() // ⚠️ load-bearing — do NOT remove
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
                        .padding(.horizontal, 12).padding(.vertical, 3)
                        // ⚠️ each job row ≈ 26px (3+~20+3) — must match AppDelegate.computeMainHeight budget
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 6)
                // ⚠️ bottom pad = 6px — must match AppDelegate.computeMainHeight budget
            }

            Divider()

            if !store.runners.isEmpty {
                Text("Local runners")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
                // ⚠️ runners label ≈ 26px — must match AppDelegate.computeMainHeight budget
                ForEach(store.runners, id: \.id) { runner in
                    HStack(spacing: 8) {
                        Circle().fill(dotColor(for: runner)).frame(width: 8, height: 8)
                        Text(runner.name).font(.system(size: 13)).lineLimit(1)
                        Spacer()
                        Text(runner.displayStatus)
                            .font(.caption).foregroundColor(.secondary).lineLimit(1).fixedSize()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    // ⚠️ each runner row ≈ 32px (5+~22+5) — must match AppDelegate.computeMainHeight budget
                }
                Divider()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Scopes").font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8)
                ForEach(ScopeStore.shared.scopes, id: \.self) { scope in
                    HStack {
                        Text(scope).font(.system(size: 12))
                        Spacer()
                        Button(action: { ScopeStore.shared.remove(scope); store.reload() }) {
                            Image(systemName: "minus.circle").foregroundColor(.red)
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 2)
                }
                HStack {
                    TextField("owner/repo or org", text: $newScope)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                        .onSubmit { submitScope() }
                    Button(action: submitScope) { Image(systemName: "plus.circle") }
                        .buttonStyle(.plain)
                        .disabled(newScope.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
            }
            // ⚠️ scopes section ≈ 82px total — must match AppDelegate.computeMainHeight budget

            Divider()

            Toggle(isOn: $launchAtLogin) { Text("Launch at login").font(.system(size: 13)) }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .onChange(of: launchAtLogin) { _ in LoginItem.toggle() }
            // ⚠️ toggle row ≈ 38px — must match AppDelegate.computeMainHeight budget

            Divider()

            Button(action: { NSApplication.shared.terminate(nil) }) {
                HStack { Image(systemName: "xmark.square"); Text("Quit") }.font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
            .padding(.horizontal, 12).padding(.vertical, 8)
            // ⚠️ quit row ≈ 38px — must match AppDelegate.computeMainHeight budget
        }
        // ⚠️ REGRESSION GUARD: fills AppDelegate’s computed frame.
        // NEVER replace with .frame(height: X) or .fixedSize() — both cause sizing bugs.
        // NEVER set a fixed height here — that is AppDelegate’s job via computeMainHeight().
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onReceive(store.objectWillChange) { isAuthenticated = (githubToken() != nil) }
        .onAppear { Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick += 1 } }
    }

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
        case "cancelled": return "⊖ cancelled"; case "skipped": return "− skipped"
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

final class RunnerStoreObservable: ObservableObject {
    @Published var runners: [Runner] = []
    @Published var jobs: [ActiveJob] = []
    init() { runners = RunnerStore.shared.runners; jobs = RunnerStore.shared.jobs }
    func reload() { runners = RunnerStore.shared.runners; jobs = RunnerStore.shared.jobs; objectWillChange.send() }
}
