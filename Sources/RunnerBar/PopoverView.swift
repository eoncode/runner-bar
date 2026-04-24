import AppKit
import SwiftUI
import ServiceManagement

struct PopoverView: View {
    @ObservedObject var store: RunnerStoreObservable
    @State private var newScope = ""
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var isAuthenticated = (githubToken() != nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ───────────────────────────────────────────────
            HStack {
                Text("RunnerBar v0.2")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
                if isAuthenticated {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text("Authenticated")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Button(action: signInWithGitHub) {
                        HStack(spacing: 4) {
                            Circle().fill(Color.orange).frame(width: 8, height: 8)
                            Text("Sign in with GitHub")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // ── Runner list ──────────────────────────────────────────
            if store.runners.isEmpty {
                Text(isAuthenticated ? "No runners found" : "Authenticate to see runners")
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ForEach(store.runners, id: \.id) { runner in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(dotColor(for: runner))
                            .frame(width: 8, height: 8)
                        Text(runner.name)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Spacer()
                        Text(runner.displayStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                }
            }

            // ── Active Jobs ──────────────────────────────────────────
            if !store.jobs.isEmpty {
                Divider()

                Text("Active Jobs")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 2)

                ForEach(store.jobs.prefix(5)) { job in
                    HStack(spacing: 8) {
                        jobDot(for: job)
                        Text(job.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Text(jobStatusLabel(for: job))
                            .font(.caption)
                            .foregroundColor(jobStatusColor(for: job))
                            .frame(width: 76, alignment: .trailing)
                        Text(job.elapsed)
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                }
                .padding(.bottom, 6)
            }

            Divider()

            // ── Scope management ─────────────────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                Text("Scopes")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                ForEach(ScopeStore.shared.scopes, id: \.self) { scope in
                    HStack {
                        Text(scope).font(.system(size: 12))
                        Spacer()
                        Button(action: {
                            ScopeStore.shared.remove(scope)
                            store.reload()
                        }) {
                            Image(systemName: "minus.circle")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                }

                HStack {
                    TextField("owner/repo or org", text: $newScope)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit { submitScope() }
                    Button(action: submitScope) {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .disabled(newScope.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            Divider()

            // ── Launch at login ──────────────────────────────────────
            Toggle(isOn: $launchAtLogin) {
                Text("Launch at login").font(.system(size: 13))
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .onChange(of: launchAtLogin) { _ in LoginItem.toggle() }

            Divider()

            // ── Quit ─────────────────────────────────────────────────
            Button(action: { NSApplication.shared.terminate(nil) }) {
                HStack {
                    Image(systemName: "xmark.square")
                    Text("Quit")
                }
                .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .fixedSize(horizontal: true, vertical: true)
        .onReceive(store.objectWillChange) {
            isAuthenticated = (githubToken() != nil)
        }
    }

    // MARK: - Job helpers

    @ViewBuilder
    private func jobDot(for job: ActiveJob) -> some View {
        Circle()
            .fill(jobDotColor(for: job))
            .frame(width: 7, height: 7)
    }

    private func jobDotColor(for job: ActiveJob) -> Color {
        switch job.status {
        case "in_progress": return .yellow
        case "queued":      return .gray
        default:            return job.conclusion == "success" ? .green : .red
        }
    }

    private func jobStatusLabel(for job: ActiveJob) -> String {
        switch job.status {
        case "in_progress": return "In Progress"
        case "queued":      return "Queued"
        default:            return job.conclusion?.capitalized ?? "Done"
        }
    }

    private func jobStatusColor(for job: ActiveJob) -> Color {
        switch job.status {
        case "in_progress": return .yellow
        case "queued":      return .secondary
        default:            return job.conclusion == "success" ? .green : .red
        }
    }

    // MARK: - Runner helpers

    private func dotColor(for runner: Runner) -> Color {
        if runner.status != "online" { return .gray }
        return runner.busy ? .yellow : .green
    }

    // MARK: - Actions

    private func signInWithGitHub() {
        let script = "tell application \"Terminal\" to do script \"gh auth login\""
        NSAppleScript(source: script)?.executeAndReturnError(nil)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }

    private func submitScope() {
        let trimmed = newScope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ScopeStore.shared.add(trimmed)
        RunnerStore.shared.start()
        store.reload()
        newScope = ""
    }
}

// MARK: - Observable

final class RunnerStoreObservable: ObservableObject {
    @Published var runners: [Runner] = []
    @Published var jobs: [ActiveJob] = []

    init() {
        runners = RunnerStore.shared.runners
        jobs    = RunnerStore.shared.jobs
    }

    func reload() {
        runners = RunnerStore.shared.runners
        jobs    = RunnerStore.shared.jobs
        objectWillChange.send()
    }
}
