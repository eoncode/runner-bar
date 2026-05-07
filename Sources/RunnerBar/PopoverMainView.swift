import ServiceManagement
import SwiftUI

/// The root view for the menu bar popover.
struct PopoverMainView: View {
    @ObservedObject var store: RunnerStoreObservable

    /// Callback when a live job row is tapped.
    let onSelectJob: (ActiveJob) -> Void
    /// Callback when an action group row is tapped.
    let onSelectAction: (ActionGroup) -> Void

    @State private var newScope = ""
    @State private var isAuthenticated = (githubToken() != nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    runnersSection
                    Divider()
                    actionsSection
                    Divider()
                    jobsSection
                    Divider()
                    scopesSection
                    Divider()
                    settingsSection
                }
            }
            Divider()
            quitButton
        }
        .frame(idealWidth: 340, maxWidth: .infinity, alignment: .top)
        .onReceive(store.objectWillChange) { _ in isAuthenticated = (githubToken() != nil) }
    }

    private var header: some View {
        HStack {
            Text("RunnerBar").font(.system(size: 14, weight: .bold))
            Spacer()
            if !isAuthenticated {
                Button(action: signInWithGitHub) {
                    Text("Sign in").font(.caption).foregroundColor(.blue)
                }.buttonStyle(.plain)
            }
            statusIndicator
        }
        .padding(12)
    }

    private var runnersSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Runners").font(.caption).foregroundColor(.secondary).padding(.horizontal, 12)
            if store.runners.isEmpty {
                Text("No runners configured").font(.caption).padding(12)
            } else {
                ForEach(store.runners) { runner in
                    HStack {
                        Circle().fill(runnerColor(for: runner)).frame(width: 8, height: 8)
                        Text(runner.name).font(.system(size: 12))
                        Spacer()
                        Text(runner.status).font(.caption2).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 2)
                }
            }
        }.padding(.vertical, 8)
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Actions").font(.caption).foregroundColor(.secondary).padding(.horizontal, 12)
            if store.actions.isEmpty {
                Text("No active actions").font(.caption).padding(12)
            } else {
                ForEach(store.actions) { group in
                    Button(action: { onSelectAction(group) }, label: {
                        HStack {
                            Circle().fill(groupColor(for: group)).frame(width: 8, height: 8)
                            Text(group.label).font(.system(size: 12, weight: .medium))
                            Text(group.title).font(.system(size: 12)).lineLimit(1).foregroundColor(.secondary)
                            Spacer()
                            Text(group.elapsed).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 3)
                    }).buttonStyle(.plain)
                }
            }
        }.padding(.vertical, 8)
    }

    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Active Jobs").font(.caption).foregroundColor(.secondary).padding(.horizontal, 12)
            if store.jobs.isEmpty {
                Text("No active jobs").font(.caption).padding(12)
            } else {
                ForEach(store.jobs) { job in
                    Button(action: { onSelectJob(job) }, label: {
                        HStack {
                            Circle().fill(jobColor(for: job)).frame(width: 8, height: 8)
                            Text(job.name).font(.system(size: 12))
                            Spacer()
                            Text(job.elapsed).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 3)
                    }).buttonStyle(.plain)
                }
            }
        }.padding(.vertical, 8)
    }

    private var scopesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Scopes").font(.caption).foregroundColor(.secondary).padding(.horizontal, 12)
            ForEach(ScopeStore.shared.scopes, id: \.self) { scope in
                HStack {
                    Text(scope).font(.system(size: 12))
                    Spacer()
                    Button(action: { ScopeStore.shared.remove(scope); store.reload() }, label: {
                        Image(systemName: "minus.circle").foregroundColor(.red)
                    }).buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 2)
            }
            HStack {
                TextField("Add scope...", text: ).textFieldStyle(.plain).font(.system(size: 12))
                Button(action: submitScope) { Image(systemName: "plus.circle") }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.top, 4)
        }.padding(.vertical, 8)
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Launch at Login", isOn: Binding(
                get: { LoginItem.isEnabled },
                set: { LoginItem.isEnabled = $0 }
            ))
            .font(.caption)
            .padding(.horizontal, 12)
        }.padding(.vertical, 8)
    }

    private var quitButton: some View {
        Button(action: { NSApplication.shared.terminate(nil) }, label: {
            HStack { Image(systemName: "xmark.square"); Text("Quit") }.font(.system(size: 13))
        })
        .buttonStyle(.plain)
        .padding(12)
    }

    private var statusIndicator: some View {
        Circle().fill(RunnerStore.shared.aggregateStatus == .allOnline ? Color.green :
            .orange).frame(width: 8, height: 8)
    }

    private func runnerColor(for runner: Runner) -> Color {
        runner.status == "online" ? .green : .red
    }

    private func groupColor(for group: ActionGroup) -> Color {
        group.groupStatus == .inProgress ? .yellow : .gray
    }

    private func jobColor(for job: ActiveJob) -> Color {
        job.status == "in_progress" ? .yellow : .gray
    }

    private func submitScope() {
        let token = newScope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        ScopeStore.shared.add(token)
        RunnerStore.shared.start()
        store.reload()
        newScope = ""
    }

    private func signInWithGitHub() {
        let script = "tell application \"Terminal\" to do script \"gh auth login\""
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }
}
