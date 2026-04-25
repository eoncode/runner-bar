import AppKit
import SwiftUI
import ServiceManagement

// ============================================================
// ⚠️  WARNING — POPOVER SIZING CONTRACT — READ BEFORE EDITING
// ============================================================
// VERSION: v1.7 (keep in sync with AppDelegate.swift)
//
// TWO SYMPTOMS that keep recurring:
//   A) LEFT JUMP  — popover flies to far left of screen on open/nav
//   B) EMPTY SPACE — large void below content
//
// THE CONTRACT (all must be true simultaneously):
//   1. Root Group must have .frame(idealWidth: 340) — NOT .frame(width:)
//      idealWidth controls NSHostingController.preferredContentSize.width.
//      .frame(width:) does NOT. They are NOT equivalent here.
//      Changing idealWidth → width WILL cause left-jump.
//
//   2. jobListView must use:
//        .fixedSize(horizontal: false, vertical: true)
//        .frame(maxHeight: 480, alignment: .top)
//      NOT a fixed .frame(height: 480) — that causes empty space.
//      NOT wrapped in ScrollView — infinite preferred height.
//
//   3. AppDelegate must keep hc.sizingOptions = .preferredContentSize.
//      Never set popover.contentSize manually.
//
//   4. ALL child nav states (jobSteps, matrixGroup, stepLog) must use
//        .frame(maxWidth: .infinity, minHeight: 480, maxHeight: 480)
//      NEVER .frame(width: 340, ...) — fixed width fights idealWidth:340
//      and causes preferredContentSize.width to drift => left jump.
//
//   5. popoverIsOpen flag in AppDelegate MUST be set true BEFORE reload().
//      See AppDelegate.swift CAUSE 4 comment.
//
// WHY idealWidth AND NOT width:
//   NSHostingController with sizingOptions=.preferredContentSize reads the
//   SwiftUI view's IDEAL size to set preferredContentSize.
//   .frame(idealWidth: 340) sets ideal width = 340 for all nav states.
//   .frame(width: 340) sets a layout constraint but breaks ideal size
//   reporting on child views => preferredContentSize.width changes => jump.
//
// This regression has been introduced 30+ times in one day.
// See GitHub issues #53 and #54 before touching any of this.
// ============================================================

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
        Group {
            switch navState {
            case .jobList:
                jobListView
                    // ⚠️ fixedSize(vertical:true) measures natural content height.
                    // DO NOT remove — without it height defaults to 480 => empty space.
                    // DO NOT wrap jobListView in ScrollView — infinite preferred height.
                    .fixedSize(horizontal: false, vertical: true)
                    // ⚠️ maxHeight caps at 480pt. DO NOT change to .frame(height:480)
                    // — that's fixed not max, causes empty space when content is short.
                    .frame(maxHeight: 480, alignment: .top)
            case .jobSteps(let job, let scope):
                JobStepsView(
                    job: job,
                    scope: scope,
                    onBack: { navState = .jobList }
                )
            case .matrixGroup(let baseName, let jobs, let scope):
                MatrixGroupView(
                    baseName: baseName,
                    jobs: jobs,
                    scope: scope,
                    onBack: { navState = .jobList }
                )
            }
        }
        // ⚠️ THIS MUST BE idealWidth — NOT width, NOT width+height, NOT minWidth.
        // idealWidth = 340 => NSHostingController.preferredContentSize.width = 340 always.
        // This is what prevents the left-jump. .frame(width: 340) does NOT do this.
        // DO NOT change this line. See contract at top of file.
        .frame(idealWidth: 340)
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

            // -- Header — RunnerBar v1.7
            HStack {
                Text("RunnerBar v1.7")
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

            // -- Active Jobs
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

            // -- Local runners
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

            // -- Scope management
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

            // -- Launch at login
            Toggle(isOn: $launchAtLogin) {
                Text("Launch at login").font(.system(size: 13))
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .onChange(of: launchAtLogin) { _ in LoginItem.toggle() }

            Divider()

            // -- Quit
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

        } // VStack
    }

    // MARK: - Group row builder

    @ViewBuilder
    private func groupRow(for group: JobGroup) -> some View {
        let jobScope = ScopeStore.shared.scopes.first ?? ""

        Button(action: {
            switch group {
            case .single(let job):
                navState = .jobSteps(job: job, scope: jobScope)
            case .matrix(let baseName, let jobs):
                navState = .matrixGroup(baseName: baseName, jobs: jobs, scope: jobScope)
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
