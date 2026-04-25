import AppKit
import SwiftUI
import ServiceManagement

// ============================================================
// ⚠️⚠️⚠️  STOP. READ THIS ENTIRE COMMENT BEFORE TOUCHING THIS FILE.  ⚠️⚠️⚠️
// ============================================================
// VERSION: v2.4 (keep in sync with AppDelegate.swift)
//
// ============================================================
// FRAME CONTRACT
// ============================================================
//
// Root Group: .frame(idealWidth: 340)
//   — idealWidth drives preferredContentSize.width = 340 always.
//   — NO idealHeight / minHeight / maxHeight on root.
//   — Height comes entirely from the active nav state child.
//
// .jobList branch: .fixedSize(horizontal:false, vertical:true)
//                  .frame(maxHeight: 480, alignment: .top)
//   — fixedSize: SwiftUI measures natural content height.
//   — maxHeight: caps at 480pt for very long lists.
//   — This produces a compact, content-sized popover height.
//
// .jobSteps / .matrixGroup branches: each view applies
//   .frame(maxWidth:.infinity, minHeight:480, maxHeight:480) internally.
//   — Height = 480pt always for these views.
//
// HEIGHT CHANGE DURING NAVIGATION:
//   jobList (e.g. 320pt) → jobSteps (480pt): height INCREASES.
//   An increase moves the popover UP (not left). No "left jump".
//   The popover closes when the user taps Back (onBack calls close).
//   On reopen, navState is always .jobList => compact height again.
//   Height NEVER decreases while the popover is visible.
//
// ============================================================
// NAVIGATION CONTRACT
// ============================================================
//
//   ✘ NavigationStack / NavigationView
//   ✘ ZStack + .transition(.move)
//   ✔ Group + switch  (current)
//
//   onBack MUST call the injected closePopover closure, NOT set
//   navState=.jobList directly. Setting navState while open would
//   decrease height => re-anchor => potential jump.
//
// ============================================================

private enum NavState: Equatable {
    case jobList
    case jobSteps(job: ActiveJob, steps: [JobStep], scope: String)
    case matrixGroup(baseName: String, jobs: [ActiveJob], scope: String)

    static func == (lhs: NavState, rhs: NavState) -> Bool {
        switch (lhs, rhs) {
        case (.jobList, .jobList): return true
        case (.jobSteps(let a, _, _), .jobSteps(let b, _, _)): return a.id == b.id
        case (.matrixGroup(let a, _, _), .matrixGroup(let b, _, _)): return a == b
        default: return false
        }
    }
}

struct PopoverView: View {
    @ObservedObject var store: RunnerStoreObservable
    @State private var newScope = ""
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var isAuthenticated = (githubToken() != nil)
    @State private var tick = 0
    @State private var navState: NavState = .jobList

    // Called by AppDelegate.popoverWillShow to reset nav before first render.
    // ⚠️ CAUSE 8 FIX. DO NOT REMOVE.
    mutating func resetNavState() {
        navState = .jobList
    }

    var body: some View {
        Group {
            switch navState {
            case .jobList:
                jobListView
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: 480, alignment: .top)

            case .jobSteps(let job, let steps, let scope):
                // ⚠️ onBack closes the popover (via NSApp event) instead of
                // setting navState=.jobList. Closing prevents a height
                // decrease while visible => no re-anchor => no jump.
                JobStepsView(
                    job: job,
                    steps: steps,
                    scope: scope,
                    onBack: { closePopover() }
                )

            case .matrixGroup(let baseName, let jobs, let scope):
                MatrixGroupView(
                    baseName: baseName,
                    jobs: jobs,
                    scope: scope,
                    onBack: { closePopover() }
                )
            }
        }
        // ⚠️ idealWidth:340 ONLY on root. Height = child. DO NOT add minHeight here.
        .frame(idealWidth: 340)
        .onReceive(store.objectWillChange) {
            isAuthenticated = (githubToken() != nil)
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick += 1 }
        }
    }

    // Close the popover gracefully. User can reopen to see jobList.
    private func closePopover() {
        NSApplication.shared.keyWindow?.close()
    }

    // MARK: - Job list view
    private var jobListView: some View {
        VStack(alignment: .leading, spacing: 0) {

            HStack {
                Text("RunnerBar v2.0")
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

            Text("Active Jobs")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)

            if store.state.jobs.isEmpty {
                Text("No active jobs")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .padding(.bottom, 2)
            } else {
                let groups = groupJobs(Array(store.state.jobs.prefix(3)))
                ForEach(groups) { group in
                    groupRow(for: group)
                }
                .padding(.bottom, 6)
            }

            Divider()

            Text("Local runners")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)

            if store.state.runners.isEmpty {
                Text(isAuthenticated ? "No runners found" : "Authenticate to see runners")
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .padding(.bottom, 2)
            } else {
                ForEach(store.state.runners, id: \.id) { runner in
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

            Toggle(isOn: $launchAtLogin) {
                Text("Launch at login").font(.system(size: 13))
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .onChange(of: launchAtLogin) { _ in LoginItem.toggle() }

            Divider()

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

        } // end VStack
    }

    // MARK: - Group row
    @ViewBuilder
    private func groupRow(for group: JobGroup) -> some View {
        let jobScope = ScopeStore.shared.scopes.first ?? ""
        Button(action: {
            switch group {
            case .single(let job): loadStepsAndNavigate(job: job, scope: jobScope)
            case .matrix(let baseName, let jobs): navState = .matrixGroup(baseName: baseName, jobs: jobs, scope: jobScope)
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

    private func loadStepsAndNavigate(job: ActiveJob, scope: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let steps = fetchJobSteps(jobID: job.id, scope: scope)
            DispatchQueue.main.async { navState = .jobSteps(job: job, steps: steps, scope: scope) }
        }
    }

    // MARK: - Helpers
    private func liveElapsed(group: JobGroup) -> String { _ = tick; return group.elapsed }

    @ViewBuilder
    private func groupDot(for group: JobGroup) -> some View {
        if case .matrix = group {
            ZStack {
                Circle().fill(groupDotColor(for: group)).frame(width: 6, height: 6).offset(x: -2)
                Circle().fill(groupDotColor(for: group).opacity(0.6)).frame(width: 6, height: 6).offset(x: 2)
            }
            .frame(width: 7, height: 7)
        } else {
            Circle().fill(groupDotColor(for: group)).frame(width: 7, height: 7)
        }
    }

    private func groupDotColor(for group: JobGroup) -> Color {
        if group.isDimmed { return group.conclusion == "failure" ? .red : .secondary }
        switch group.status {
        case "in_progress": return .yellow
        case "queued":      return .gray
        default:            return .secondary
        }
    }

    private func statusLabel(status: String) -> String {
        switch status {
        case "in_progress": return "In Progress"
        case "queued":      return "Queued"
        default:            return "Done"
        }
    }
    private func statusColor(status: String) -> Color { status == "in_progress" ? .yellow : .secondary }

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

    private func dotColor(for runner: Runner) -> Color {
        runner.status == "online" ? (runner.busy ? .yellow : .green) : .gray
    }

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

// MARK: - Store

struct StoreState {
    var runners: [Runner] = []
    var jobs: [ActiveJob] = []
}

final class RunnerStoreObservable: ObservableObject {
    @Published var state: StoreState = StoreState()

    init() {
        state = StoreState(
            runners: RunnerStore.shared.runners,
            jobs:    RunnerStore.shared.jobs
        )
    }

    func reload() {
        state = StoreState(
            runners: RunnerStore.shared.runners,
            jobs:    RunnerStore.shared.jobs
        )
    }
}
