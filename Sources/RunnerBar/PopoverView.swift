import AppKit
import SwiftUI
import ServiceManagement

// ============================================================
// ⚠️⚠️⚠️  STOP. READ THIS ENTIRE COMMENT BEFORE TOUCHING THIS FILE.  ⚠️⚠️⚠️
// ============================================================
// VERSION: v1.9 (keep in sync with AppDelegate.swift)
//
// This file defines the root SwiftUI view inside an NSPopover.
// The sizing relationship between SwiftUI and NSPopover is extremely
// fragile. The left-jump bug was introduced and re-introduced 30+
// times in a single day before all 6 root causes were identified.
//
// READ AppDelegate.swift SECTION 1 for the full explanation of WHY
// NSPopover behaves this way. This comment covers the SwiftUI side.
//
// ============================================================
// SECTION 1: THE FRAME CONTRACT (all rules must hold simultaneously)
// ============================================================
//
// RULE 1: The root Group MUST use .frame(idealWidth: 340)
//
//   NSHostingController with sizingOptions=.preferredContentSize reads
//   the SwiftUI layout engine's IDEAL size (not min, not max, not the
//   resolved layout size) to compute preferredContentSize.
//
//   .frame(idealWidth: 340)  => ideal width = 340  ✔ CORRECT
//   .frame(width: 340)       => layout width = 340, ideal width = BROKEN
//
//   .frame(width: 340) does NOT set the ideal width. It sets a layout
//   constraint. In the context of NSHostingController.preferredContentSize,
//   .frame(width:) causes the ideal width to be reported as something
//   other than 340 in certain navigation states, causing the width to
//   fluctuate => NSPopover re-anchors => left jump.
//
//   DO NOT CHANGE .frame(idealWidth: 340) TO .frame(width: 340).
//   They look equivalent. They are NOT.
//
// RULE 2: The root Group MUST be the outermost container
//
//   The .frame(idealWidth: 340) modifier must be on the direct parent
//   of the switch statement. If you wrap the Group in a VStack, ZStack,
//   or any other container, the ideal width propagation changes and
//   preferredContentSize.width may no longer be reliably 340.
//
// RULE 3: The jobList nav state MUST use fixedSize + maxHeight, NOT height
//
//   .fixedSize(horizontal: false, vertical: true) tells SwiftUI to use
//   the view's natural (ideal) vertical size rather than expanding to fill.
//   Without it, the view expands to fill the available height (480pt)
//   even when content is short => large empty space below content.
//
//   .frame(maxHeight: 480) caps the height at 480pt for long lists.
//   .frame(height: 480) sets EXACTLY 480pt even for short lists => empty space.
//   .frame(maxHeight: 480) is correct. .frame(height: 480) is wrong.
//
//   DO NOT wrap jobListView in a ScrollView.
//   ScrollView reports infinite preferred height => preferredContentSize
//   height explodes => popover becomes huge => re-anchor => left jump.
//
// RULE 4: ALL child nav views MUST use maxWidth, NOT width
//
//   JobStepsView, MatrixGroupView, StepLogView all appear inside the
//   root Group's switch statement. They MUST use:
//     .frame(maxWidth: .infinity, minHeight: 480, maxHeight: 480)
//
//   They must NEVER use:
//     .frame(width: 340, ...)  ← overrides ideal width => left jump
//     .frame(width: 340, height: 480)  ← same problem
//
//   maxWidth: .infinity expands to fill the space that the parent Group's
//   idealWidth: 340 has established. This keeps the ideal width at 340
//   across all navigation states.
//
//   The child view files (JobStepsView.swift, MatrixGroupView.swift,
//   StepLogView.swift) apply .frame(maxWidth: .infinity, ...) on their
//   own body. The PopoverView switch does NOT need to add frames to them.
//
// ============================================================
// SECTION 2: NAVIGATION CONTRACT
// ============================================================
//
// Navigation is implemented as a @State NavState enum + Group + switch.
// This is NOT arbitrary. Each alternative was tried and broke things:
//
//   ✘ NavigationStack / NavigationView
//       => Has its own sizing logic that fights NSHostingController.
//          Width jumps on push/pop.
//
//   ✘ ZStack with .opacity or .transition
//       => ZStack measures the MAX of all children's sizes simultaneously.
//          Even invisible children affect preferredContentSize.
//
//   ✘ ZStack with .transition(.move(edge: .leading))
//       => In NSPopover context, ZStack collapses to zero width during
//          the transition. The move animation plays from the LEFT EDGE
//          OF THE SCREEN, not from within the popover. Looks identical
//          to the left-jump bug.
//
//   ✔ Group + switch (current approach)
//       => Group has zero layout overhead. It measures exactly one child
//          at a time (the active switch branch). No phantom size from
//          inactive branches. Clean navigation with no transition artifacts.
//
// DO NOT add .transition() to any case in the switch statement.
// Transitions change the view's reported size during the animation.
// Even .transition(.identity) can affect the layout pass timing.
//
// ============================================================
// SECTION 3: WHAT WILL HAPPEN IF YOU BREAK THESE RULES
// ============================================================
//
// Symptom A — Popover flies to far left on open:
//   Caused by: preferredContentSize.width is wrong on first render.
//   Most likely: .frame(width:340) instead of .frame(idealWidth:340).
//
// Symptom B — Popover jumps left when navigating to steps/matrix view:
//   Caused by: child view reports a different ideal width than 340.
//   Most likely: .frame(width:340) in a child view fighting the parent.
//
// Symptom C — Popover jumps left every ~10 seconds while open:
//   Caused by: observable.reload() called while popover is open.
//   See AppDelegate.swift CAUSE 2.
//
// Symptom D — Popover opens and immediately closes on every click:
//   Caused by: objectWillChange publish pending at the moment show() runs.
//   Either reload() in popoverDidClose (CAUSE 3), or onChange-triggered
//   reload racing with togglePopover (CAUSE 6), or show() not deferred.
//
// Symptom E — Large empty space below content when no jobs are running:
//   Caused by: .frame(height:480) instead of .fixedSize+.frame(maxHeight:480).
//   Or: jobListView wrapped in ScrollView.
//
// Symptom F — Popover jumps left only on the very first open:
//   Caused by: popoverIsOpen set after reload() in togglePopover.
//   See AppDelegate.swift CAUSE 4.
//
// Symptom G — Popover jumps left on second open (first open was fine):
//   Previously caused by CAUSE 5 (triple publish). Fixed in v1.8.
//   If this recurs, check that reload() has exactly ONE @Published
//   assignment (the StoreState struct) and no extra .send() calls.
//
// ============================================================

// MARK: - Navigation state

// ⚠️ This enum drives ALL navigation in the popover.
// Do NOT add associated values that contain large data structures —
// NavState.== must remain cheap. Do NOT add more cases without reading
// SECTION 2 of this file about navigation constraints.
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
        // ⚠️ RULE: This outer container MUST be a Group.
        // See SECTION 2: NavigationStack, ZStack, etc. all break sizing.
        // Group has zero layout overhead and measures exactly one child.
        Group {
            switch navState {

            case .jobList:
                jobListView
                    // ⚠️ RULE: .fixedSize(vertical:true) MUST be here.
                    // Makes SwiftUI use natural content height instead of
                    // expanding to fill. Without this => large empty space.
                    // See SECTION 1 RULE 3.
                    .fixedSize(horizontal: false, vertical: true)
                    // ⚠️ RULE: .frame(maxHeight:) NOT .frame(height:).
                    // maxHeight caps long content at 480pt.
                    // height:480 forces short content to 480pt => empty space.
                    // See SECTION 1 RULE 3.
                    .frame(maxHeight: 480, alignment: .top)

            case .jobSteps(let job, let scope):
                // JobStepsView applies its own .frame(maxWidth:.infinity, ...)
                // on its body. Do NOT add .frame(width:340) here.
                // See SECTION 1 RULE 4.
                JobStepsView(
                    job: job,
                    scope: scope,
                    onBack: { navState = .jobList }
                )

            case .matrixGroup(let baseName, let jobs, let scope):
                // MatrixGroupView applies its own .frame(maxWidth:.infinity, ...)
                // on its body. Do NOT add .frame(width:340) here.
                // See SECTION 1 RULE 4.
                MatrixGroupView(
                    baseName: baseName,
                    jobs: jobs,
                    scope: scope,
                    onBack: { navState = .jobList }
                )
            }
        }
        // ⚠️⚠️⚠️  THIS IS THE MOST IMPORTANT LINE IN THIS FILE.  ⚠️⚠️⚠️
        //
        // .frame(idealWidth: 340) sets the SwiftUI IDEAL width to 340pt.
        // NSHostingController.preferredContentSize reads the ideal size.
        // This keeps preferredContentSize.width = 340 across ALL nav states.
        // That stable width is what prevents the left-jump.
        //
        // CHANGING THIS TO .frame(width: 340) WILL BREAK EVERYTHING.
        // They look the same. They are not the same.
        // .frame(width: 340) = layout constraint (does NOT set ideal width)
        // .frame(idealWidth: 340) = ideal size hint (DOES set ideal width)
        //
        // DO NOT ADD minWidth, maxWidth, height, or any other parameter here.
        // DO NOT MOVE THIS MODIFIER to any child view.
        // DO NOT REMOVE THIS MODIFIER.
        .frame(idealWidth: 340)
        .onReceive(store.objectWillChange) {
            // ⚠️ store.objectWillChange now fires exactly ONCE per reload()
            // because StoreState is a single @Published property.
            // Previously runners + jobs were two @Published properties =>
            // two fires per reload() => two githubToken() calls => two re-renders.
            isAuthenticated = (githubToken() != nil)
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick += 1 }
        }
    }

    // MARK: - Job list view
    //
    // ⚠️ This view is used ONLY in the .jobList nav state.
    // It is wrapped in .fixedSize + .frame(maxHeight:) in the switch above.
    // DO NOT add those modifiers here as well — double application causes
    // incorrect height calculation.
    private var jobListView: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header — RunnerBar v1.9
            HStack {
                Text("RunnerBar v1.9")
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

            // ⚠️ store.state.jobs — access via the single StoreState struct.
            // Do NOT use store.jobs or store.runners directly; they no longer exist.
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

        } // end VStack (jobListView)
        // ⚠️ DO NOT add .fixedSize or .frame modifiers here.
        // Those are applied in the switch statement above to control
        // how the Group measures this view. Adding them here too
        // creates double application and breaks height calculation.
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
    private func liveElapsed(group: JobGroup) -> String { _ = tick; return group.elapsed }

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

    // MARK: - Label helpers
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

// ============================================================
// ⚠️⚠️⚠️  RunnerStoreObservable — READ BEFORE TOUCHING  ⚠️⚠️⚠️
// ============================================================
// VERSION HISTORY:
//   v1.7: runners + jobs as two separate @Published properties
//   v1.8: removed explicit objectWillChange.send(), added withAnimation(nil)
//         PROBLEM: withAnimation(nil) does NOT coalesce @Published (Combine)
//         fires. Still 2x publishes per reload() because two @Published props.
//   v1.9: Merged runners + jobs into ONE @Published StoreState struct.
//         ONE property = ONE assignment = ONE Combine publish = ONE re-render.
//         This is the correct and final fix for the multi-publish problem.
//
// WHY ONE @Published STRUCT INSTEAD OF TWO @Published PROPERTIES:
//   @Published fires objectWillChange via the Combine pipeline, NOT via
//   SwiftUI's animation/transaction system. withAnimation(nil) only batches
//   @State changes inside a SwiftUI view body. It has NO effect on @Published
//   Combine publishers. Two @Published properties = two separate Combine
//   events per reload() = two SwiftUI re-renders = two preferredContentSize
//   recalculations. Each recalculation can trigger NSPopover re-anchor.
//
// ⚠️ DO NOT split StoreState back into separate @Published properties.
//    This was tried in v1.7 and caused CAUSE 5/5b. It looks cleaner.
//    It is not. One struct = one publish = one render. Keep it.
//
// ⚠️ DO NOT add objectWillChange.send() after the state assignment.
//    @Published fires it automatically. Extra .send() = extra re-render.
//    This was CAUSE 5 in v1.7.
//
// ⚠️ ONLY call reload() from:
//    - togglePopover (after popoverIsOpen = true, before show())
//    - onChange handler (only when !popoverIsOpen)
//    - submitScope / scope removal (user-triggered, acceptable)
//    NEVER from popoverDidClose. See AppDelegate CAUSE 3.
// ============================================================

/// Snapshot of RunnerStore state for SwiftUI rendering.
/// This is a VALUE TYPE (struct) — assignment is atomic from SwiftUI/Combine's
/// perspective: one assignment triggers exactly one objectWillChange publish.
struct StoreState {
    var runners: [Runner]   = []
    var jobs: [ActiveJob]   = []
}

final class RunnerStoreObservable: ObservableObject {
    // ⚠️ ONE @Published property. ONE Combine publish per reload().
    // Do NOT add more @Published properties to this class.
    // If you need new data, add fields to StoreState instead.
    @Published var state: StoreState = StoreState()

    init() {
        // init() runs once at app launch before any Combine subscribers exist.
        // Direct struct mutation here is equivalent to a single @Published fire.
        state = StoreState(
            runners: RunnerStore.shared.runners,
            jobs:    RunnerStore.shared.jobs
        )
    }

    func reload() {
        // ⚠️⚠️⚠️  THIS ASSIGNMENT MUST REMAIN A SINGLE LINE / SINGLE VALUE.  ⚠️⚠️⚠️
        //
        // Assigning a new StoreState struct fires objectWillChange EXACTLY ONCE
        // via @Published. This is atomic from Combine's perspective.
        //
        // HISTORY OF BUGS FROM SPLITTING THIS:
        //   runners = ... (publish 1) + jobs = ... (publish 2) => 2 re-renders
        //   runners = ... (pub 1) + jobs = ... (pub 2) + .send() (pub 3) => 3 re-renders
        //   Each extra re-render = extra preferredContentSize change = left jump.
        //
        // DO NOT refactor this into two separate assignments.
        // DO NOT add objectWillChange.send() after this.
        // DO NOT add withAnimation(nil) { } around this — not needed, struct is atomic.
        state = StoreState(
            runners: RunnerStore.shared.runners,
            jobs:    RunnerStore.shared.jobs
        )
    }
}
