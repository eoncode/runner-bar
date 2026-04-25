import AppKit
import SwiftUI
import ServiceManagement

// MARK: - Navigation state

private enum NavState: Equatable {
    case jobList
    case jobSteps(job: ActiveJob, scope: String)
    case matrixGroup(baseName: String, jobs: [ActiveJob], scope: String)

    static func == (lhs: NavState, rhs: NavState) -> Bool {
        switch (lhs, rhs) {
        case (.jobList, .jobList): return true
        case (.jobSteps(let a, _), .jobSteps(let b, _)): return a.id == b.id
        case (.matrixGroup(let a, _, _), .matrixGroup(let b, _, _)): return a == b
        default: return false
        }
    }
}

// MARK: - Root view

struct PopoverView: View {
    @ObservedObject var store: RunnerStoreObservable
    @State private var newScope = ""
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var isAuthenticated = (githubToken() != nil)
    @State private var tick = 0
    @State private var navState: NavState = .jobList

    var body: some View {
        ZStack {
            if case .jobList = navState {
                jobListView
                    .transition(.move(edge: .leading))
            }
            if case .jobSteps(let job, let scope) = navState {
                JobStepsView(
                    job: job,
                    scope: scope,
                    onBack: { withAnimation(.easeInOut(duration: 0.25)) { navState = .jobList } }
                )
                .transition(.move(edge: .trailing))
            }
            if case .matrixGroup(let baseName, let jobs, let scope) = navState {
                MatrixGroupView(
                    baseName: baseName,
                    jobs: jobs,
                    scope: scope,
                    onBack: { withAnimation(.easeInOut(duration: 0.25)) { navState = .jobList } }
                )
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: navState)
        .onReceive(store.objectWillChange) {
            isAuthenticated = (githubToken() != nil)
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick += 1 }
        }
    }

    // MARK: - Job list view

    private var jobListView: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header
            HStack {
                Text("RunnerBar v0.8")
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

            // ── Active Jobs
            Text("Active Jobs")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)

            if store.jobs.isEmpty {
                Text("No active jobs")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .padding(.bottom, 2)
            } else {
                let groups = groupJobs(Array(store.jobs.prefix(3)))
                ForEach(groups) { group in
                    groupRow(for: group)
                }
                .padding(.bottom, 6)
            }

            Divider()

            // ── Local runners
            Text("Local runners")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)

            if store.runners.isEmpty {
                Text(isAuthenticated ? "No runners found" : "Authenticate to see runners")
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .padding(.bottom, 2)
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

            Divider()

            // ── Scope management
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

            // ── Launch at login (macOS 13 compatible onChange)
            Toggle(isOn: $launchAtLogin) {
                Text("Launch at login").font(.system(size: 13))
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .onChange(of: launchAtLogin) { _ in LoginItem.toggle() }

            Divider()

            // ── Quit
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
        .frame(minWidth: 320)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Group row builder

    @ViewBuilder
    private func groupRow(for group: JobGroup) -> some View {
        // Find which scope this group's jobs belong to
        let jobScope: String = {
            switch group {
            case .single(let job):
                return ScopeStore.shared.scopes.first(where: { _ in true }) ?? ""
            case .matrix(_, let jobs):
                return ScopeStore.shared.scopes.first(where: { _ in true }) ?? ""
            }
        }()

        Button(action: {
            withAnimation(.easeInOut(duration: 0.25)) {
                switch group {
                case .single(let job):
                    navState = .jobSteps(job: job, scope: jobScope)
                case .matrix(let baseName, let jobs):
                    navState = .matrixGroup(baseName: baseName, jobs: jobs, scope: jobScope)
                }
            }
        }) {
            HStack(spacing: 8) {
                groupDot(for: group)

                Text(group.displayName)
                    .font(.system(size: 12))
                    .foregroundColor(group.isDimmed ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if group.isDimmed {
                    Text(conclusionLabel(conclusion: group.conclusion))
                        .font(.caption)
                        .foregroundColor(conclusionColor(conclusion: group.conclusion))
                        .frame(width: 76, alignment: .trailing)
                } else {
                    Text(statusLabel(status: group.status))
                        .font(.caption)
                        .foregroundColor(statusColor(status: group.status))
                        .frame(width: 76, alignment: .trailing)
                }

                Text(group.isDimmed ? group.elapsed : liveElapsed(group: group))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .trailing)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Elapsed

    private func liveElapsed(group: JobGroup) -> String {
        _ = tick
        return group.elapsed
    }

    // MARK: - Dot helpers

    @ViewBuilder
    private func groupDot(for group: JobGroup) -> some View {
        if case .matrix = group {
            ZStack {
                Circle().fill(groupDotColor(for: group)).frame(width: 6, height: 6).offset(x: -2)
                Circle().fill(groupDotColor(for: group).opacity(0.6)).frame(width: 6, height: 6).offset(x: 2)
            }
            .frame(width: 7, height: 7)
        } else {
            Circle()
                .fill(groupDotColor(for: group))
                .frame(width: 7, height: 7)
        }
    }

    private func groupDotColor(for group: JobGroup) -> Color {
        if group.isDimmed {
            return group.conclusion == "failure" ? .red : .secondary
        }
        switch group.status {
        case "in_progress": return .yellow
        case "queued":      return .gray
        default:            return .secondary
        }
    }

    // MARK: - Label helpers

    private func statusLabel(status: String) -> String {
        switch status {
        case "in_progress": return "In Progress"
        case "queued":      return "Queued"
        default:            return "Done"
        }
    }

    private func statusColor(status: String) -> Color {
        status == "in_progress" ? .yellow : .secondary
    }

    private func conclusionLabel(conclusion: String?) -> String {
        switch conclusion {
        case "success":   return "✓ success"
        case "failure":   return "✗ failure"
        case "cancelled": return "⊖ cancelled"
        case "skipped":   return "− skipped"
        default:          return conclusion ?? "done"
        }
    }

    private func conclusionColor(conclusion: String?) -> Color {
        switch conclusion {
        case "success": return .green
        case "failure": return .red
        default:        return .secondary
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
