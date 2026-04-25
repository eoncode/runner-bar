import SwiftUI
import ServiceManagement

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
                Text("RunnerBar v0.9")
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
                                .foregroundColor(job.isDimmed ? conclusionColor(for: job) : jobStatusColor(for: job))
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

            Divider()

            Toggle(isOn: $launchAtLogin) { Text("Launch at login").font(.system(size: 13)) }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .onChange(of: launchAtLogin) { _ in LoginItem.toggle() }

            Divider()

            Button(action: { NSApplication.shared.terminate(nil) }) {
                HStack { Image(systemName: "xmark.square"); Text("Quit") }.font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
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
