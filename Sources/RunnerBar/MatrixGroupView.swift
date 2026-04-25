import SwiftUI

// ============================================================
// ⚠️⚠️⚠️  STOP. READ THIS ENTIRE COMMENT BEFORE TOUCHING THIS FILE.  ⚠️⚠️⚠️
// ============================================================
// VERSION: v2.2 (keep in sync with AppDelegate.swift)
//
// This view is rendered inside PopoverView's root Group as the
// .matrixGroup navigation state. It exists inside an NSPopover
// whose sizing is brutally fragile. The left-jump bug was introduced
// 30+ times in a single day on this project.
//
// Read AppDelegate.swift SECTION 1 and PopoverView.swift SECTION 1
// before making ANY change to this file.
//
// ============================================================
// SECTION 1 — FRAME CONTRACT
// ============================================================
//
// The body Group MUST end with:
//   .frame(maxWidth: .infinity, minHeight: 480, maxHeight: 480)
//
// WHY maxWidth: .infinity and NOT width: 340:
//   PopoverView's root Group has .frame(idealWidth: 340).
//   NSHostingController reads SwiftUI's IDEAL size (not layout size)
//   to set preferredContentSize.
//
//   .frame(width: 340) on this view sets a LAYOUT constraint of 340pt.
//   It does NOT guarantee preferredContentSize.width = 340.
//   When navigating here from jobList (which has no width:340 child),
//   the ideal width is reported differently => width changes =>
//   NSPopover re-anchors its full screen position => left jump.
//
//   .frame(maxWidth: .infinity) fills the space established by the
//   parent's idealWidth:340 without fighting it.
//
//   ✘ DO NOT change to: .frame(width: 340, height: 480)
//   ✘ DO NOT change to: .frame(width: 340, minHeight: 480, maxHeight: 480)
//   ✘ DO NOT change to: .frame(maxWidth: 340, ...)
//   ✔ KEEP AS:          .frame(maxWidth: .infinity, minHeight: 480, maxHeight: 480)
//
// WHY minHeight: 480, maxHeight: 480:
//   Pins this view to exactly 480pt so the popover does not shrink/expand
//   when navigating between matrixGroup and jobList (which is capped at
//   480pt via maxHeight). Mismatched heights = re-anchor = left jump.
//   DO NOT remove minHeight.
//
// ============================================================
// SECTION 2 — NAVIGATION CONTRACT
// ============================================================
//
// This view has TWO levels of internal navigation:
//   Level 1: PopoverView root => .matrixGroup (this view)
//   Level 2: This view => variantListView vs JobStepsView
//
// Both levels MUST use Group + if/else. DO NOT use ZStack + transitions.
//
// WHY ZStack + .transition(.move(edge:)) is forbidden:
//   In NSPopover context, ZStack measures ALL children simultaneously,
//   even invisible ones. During a .move transition the stack temporarily
//   collapses to zero width. The .move animation plays from the LEFT
//   EDGE OF THE SCREEN, not from within the popover. This looks exactly
//   like the left-jump bug. It was tried. It was catastrophic.
//   Do not try it again.
//
// ============================================================
// SECTION 3 — WHY STEPS ARE PRE-LOADED HERE (CAUSE 7)
// ============================================================
//
// JobStepsView requires steps to be passed as an init parameter.
// It no longer fetches its own data (changed in v2.0 to fix CAUSE 7).
//
// CAUSE 7 recap:
//   In v1.7-v1.9, JobStepsView called loadSteps() in .onAppear.
//   The async result arrived ~2 seconds later, writing @State (isLoading,
//   steps). Those @State writes triggered SwiftUI re-renders while the
//   popover was open. The re-renders changed preferredContentSize.
//   NSPopover re-anchored => left jump ~2 seconds after tapping.
//
// THE FIX:
//   Steps are fetched HERE (in loadAndNavigate) BEFORE navigation.
//   We show a ProgressView spinner on the tapped row while fetching.
//   Once steps are ready, selectedJob + selectedSteps are set atomically
//   on the main actor. JobStepsView appears with data already populated.
//   No async load in JobStepsView = no @State change after appear =
//   no re-render = no preferredContentSize change = no jump.
//
// ⚠️ DO NOT change loadAndNavigate to navigate immediately and load
//    inside JobStepsView. That is the pattern that caused CAUSE 7.
// ⚠️ DO NOT pass an empty [] steps array and fetch inside JobStepsView.
//    The fetch must complete BEFORE navState changes.
//
// ============================================================
// SECTION 4 — FREE FUNCTION, NOT A STATIC METHOD
// ============================================================
//
// fetchJobSteps is a FREE FUNCTION defined at the top level in JobStep.swift.
// It is NOT a static method on the JobStep struct.
//
//   ✔ CORRECT:   fetchJobSteps(jobID: job.id, scope: scope)
//   ✘ INCORRECT: JobStep.fetchJobSteps(jobID: job.id, scope: scope)  ← compile error
//
// ============================================================
// SECTION 5 — ROW ALIGNMENT CONTRACT
// ============================================================
//
// Every job row in variantListView uses these fixed-width columns:
//   [dot/spinner: 16pt container] [name: flexible] [status: 76pt] [elapsed: 40pt] [chevron]
//
// The dot container is 16pt wide (not 7pt) so that the ProgressView
// spinner (which has a larger intrinsic size than a 7pt Circle) doesn't
// push the row taller and misalign all other rows.
//
// ⚠️ DO NOT reduce the dot container to 7pt.
// ⚠️ DO NOT change status column width from 76pt.
// ⚠️ DO NOT change elapsed column width from 40pt.
//
// ============================================================
// SECTION 6 — PRE-COMMIT CHECKLIST FOR THIS FILE
// ============================================================
//
// Before pushing any change, verify ALL of the following:
//   [ ] body Group still ends with .frame(maxWidth:.infinity, minHeight:480, maxHeight:480)
//   [ ] No .frame(width:340) anywhere in this file
//   [ ] Internal navigation uses Group + if/else, not ZStack + transitions
//   [ ] loadAndNavigate() still fetches steps BEFORE setting selectedJob
//   [ ] fetchJobSteps called as free function, not JobStep.fetchJobSteps
//   [ ] Dot container still .frame(width:16, height:16)
//   [ ] Version bumped if logic changed
//
// ============================================================

struct MatrixGroupView: View {
    let baseName: String
    let jobs: [ActiveJob]
    let scope: String
    let onBack: () -> Void

    // ⚠️ selectedJob and selectedSteps are ALWAYS set atomically together
    // inside loadAndNavigate(). DO NOT set selectedJob without also having
    // selectedSteps ready. JobStepsView requires non-empty steps to render
    // correctly without any @State changes after appear.
    @State private var selectedJob: ActiveJob? = nil
    @State private var selectedSteps: [JobStep] = []

    // isLoadingJob tracks which row is showing the spinner.
    // It is nil when no fetch is in flight.
    // DO NOT use it to gate the navigation — use selectedJob for that.
    @State private var isLoadingJob: ActiveJob? = nil

    // tick drives liveElapsed() text updates. Increments every second.
    // Text-only updates do NOT change the view's ideal size. Safe.
    @State private var tick = 0

    var body: some View {
        // ⚠️ Group + if/else. DO NOT replace with ZStack + transitions.
        // See SECTION 2 for why ZStack is forbidden here.
        Group {
            if let job = selectedJob {
                // JobStepsView has .frame(maxWidth:.infinity,...) on its own body.
                // The two frames compose correctly — do NOT add another frame here.
                // selectedSteps was pre-loaded by loadAndNavigate before we got here.
                JobStepsView(
                    job: job,
                    steps: selectedSteps,
                    scope: scope,
                    onBack: {
                        // Clear both together — they must always be in sync.
                        selectedJob = nil
                        selectedSteps = []
                    }
                )
            } else {
                variantListView
            }
        }
        // ⚠️⚠️⚠️  THIS FRAME IS MANDATORY. SEE SECTION 1.  ⚠️⚠️⚠️
        // maxWidth:.infinity — DO NOT change to width:340
        // minHeight:480     — DO NOT remove
        // maxHeight:480     — DO NOT remove
        .frame(maxWidth: .infinity, minHeight: 480, maxHeight: 480)
    }

    // MARK: - Variant list

    private var variantListView: some View {
        // ⚠️ ScrollView is correct here (unlike jobListView which must NOT use ScrollView).
        // This ScrollView is inside the .frame(maxHeight:480) clamp, so it does NOT
        // expose infinite preferred height to NSHostingController. Safe.
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {

                // Header
                HStack(spacing: 6) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)

                    Text(baseName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Text("\(jobs.count) variants")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Divider()

                ForEach(jobs) { job in
                    variantRow(for: job)
                }
                .padding(.bottom, 6)

            } // end VStack
        } // end ScrollView
        .onAppear {
            // tick drives liveElapsed() only. Does NOT change steps or structure.
            // Safe to run while popover is open. See SECTION 5.
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick += 1 }
        }
    }

    // MARK: - Variant row
    //
    // ⚠️ ROW ALIGNMENT CONTRACT: see SECTION 5 for column widths.
    // All rows use identical fixed-width columns.
    // DO NOT change column widths without updating SECTION 5.

    @ViewBuilder
    private func variantRow(for job: ActiveJob) -> some View {
        Button(action: { loadAndNavigate(to: job) }) {
            // ⚠️ HStack alignment: .center keeps all columns on the same baseline.
            // The dot container is 16pt tall (even though the circle is 7pt)
            // so .center prevents the spinner row from being taller than others.
            HStack(alignment: .center, spacing: 8) {

                // Dot column: fixed 16pt container.
                // Shows ProgressView when this job is being fetched,
                // Circle dot otherwise.
                // ⚠️ DO NOT reduce to 7pt — spinner is larger than 7pt
                // and would cause this row to be taller => misalignment.
                Group {
                    if isLoadingJob?.id == job.id {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Circle()
                            .fill(dotColor(for: job))
                            .frame(width: 7, height: 7)
                    }
                }
                .frame(width: 16, height: 16)

                Text(job.matrixVariant ?? job.name)
                    .font(.system(size: 12))
                    .foregroundColor(job.isDimmed ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                // Status/conclusion column: fixed 76pt, right-aligned.
                if job.isDimmed {
                    Text(conclusionLabel(for: job))
                        .font(.caption)
                        .foregroundColor(conclusionColor(for: job))
                        .frame(width: 76, alignment: .trailing)
                } else {
                    Text(statusLabel(for: job))
                        .font(.caption)
                        .foregroundColor(statusColor(for: job))
                        .frame(width: 76, alignment: .trailing)
                }

                // Elapsed column: fixed 40pt, monospaced digits.
                Text(liveElapsed(for: job))
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
        .opacity(job.isDimmed ? 0.7 : 1.0)
        // Disable all rows while any fetch is in flight to prevent
        // concurrent loadAndNavigate calls.
        .disabled(isLoadingJob != nil)
    }

    // MARK: - Pre-load steps then navigate
    //
    // ⚠️⚠️⚠️  THIS IS THE CAUSE 7 FIX. DO NOT CHANGE THE FETCH-THEN-NAVIGATE ORDER.  ⚠️⚠️⚠️
    //
    // Pattern: fetch steps => THEN set selectedJob + selectedSteps.
    // DO NOT flip to: set selectedJob => THEN fetch steps inside JobStepsView.
    //
    // The wrong order (navigate-then-fetch) causes:
    //   JobStepsView.onAppear starts async fetch.
    //   ~2 seconds later: @State changes (isLoading, steps) fire.
    //   @State changes => re-render => preferredContentSize change =>
    //   NSPopover re-anchors => left jump.
    //
    // The correct order (fetch-then-navigate):
    //   isLoadingJob = job  (spinner appears on row, popover stays on this view)
    //   fetchJobSteps runs on Task (background)
    //   On completion: selectedSteps = steps, selectedJob = job (atomic on main)
    //   JobStepsView appears with data ready, no async needed, no @State change.
    //
    // ⚠️ fetchJobSteps is a FREE FUNCTION — not JobStep.fetchJobSteps.
    //    See SECTION 4.

    private func loadAndNavigate(to job: ActiveJob) {
        // Guard prevents a second concurrent fetch if the user taps twice.
        guard isLoadingJob == nil else { return }
        isLoadingJob = job
        Task {
            // ⚠️ fetchJobSteps = free function in JobStep.swift. NOT JobStep.fetchJobSteps.
            let steps = fetchJobSteps(jobID: job.id, scope: scope)
            await MainActor.run {
                // Set both atomically. JobStepsView renders immediately.
                selectedSteps = steps
                selectedJob = job
                isLoadingJob = nil
            }
        }
    }

    // MARK: - Helpers

    // tick keeps liveElapsed current without touching steps or structure.
    private func liveElapsed(for job: ActiveJob) -> String { _ = tick; return job.elapsed }

    private func dotColor(for job: ActiveJob) -> Color {
        if job.isDimmed { return job.conclusion == "failure" ? .red : .secondary }
        switch job.status {
        case "in_progress": return .yellow
        case "queued":      return .gray
        default:            return .secondary
        }
    }
    private func statusLabel(for job: ActiveJob) -> String {
        job.status == "in_progress" ? "In Progress" : "Queued"
    }
    private func statusColor(for job: ActiveJob) -> Color {
        job.status == "in_progress" ? .yellow : .secondary
    }
    private func conclusionLabel(for job: ActiveJob) -> String {
        switch job.conclusion {
        case "success":   return "✓ success"
        case "failure":   return "✗ failure"
        case "cancelled": return "⊖ cancelled"
        case "skipped":   return "− skipped"
        default:          return job.conclusion ?? "done"
        }
    }
    private func conclusionColor(for job: ActiveJob) -> Color {
        switch job.conclusion {
        case "success": return .green
        case "failure": return .red
        default:        return .secondary
        }
    }
}
