import SwiftUI

// ============================================================
// ⚠️⚠️⚠️  STOP. READ THIS ENTIRE COMMENT BEFORE TOUCHING THIS FILE.  ⚠️⚠️⚠️
// ============================================================
// VERSION: v2.1 (keep in sync with AppDelegate.swift)
//
// This view is rendered inside PopoverView's root Group as the
// .matrixGroup navigation state. It exists inside an NSPopover
// whose sizing is extremely fragile. Read PopoverView.swift SECTION 1
// and AppDelegate.swift SECTION 1 before making any changes.
//
// The frame and navigation rules here are IDENTICAL to JobStepsView.
// See JobStepsView.swift for the detailed explanation.
//
// ============================================================
// FRAME RULE (same as JobStepsView — do not change either without the other)
// ============================================================
//
// body MUST end with:
//   .frame(maxWidth: .infinity, minHeight: 480, maxHeight: 480)
//
// ✘ NOT: .frame(width: 340, height: 480)
// ✘ NOT: .frame(width: 340, minHeight: 480, maxHeight: 480)
// ✔ YES: .frame(maxWidth: .infinity, minHeight: 480, maxHeight: 480)
//
// Changing width:340 instead of maxWidth:.infinity causes the ideal
// width to be reported differently from the root Group's idealWidth:340,
// making preferredContentSize.width fluctuate across navigation states,
// triggering NSPopover to re-anchor its screen position => left jump.
//
// ============================================================
// NAVIGATION RULE (same as JobStepsView — extremely important)
// ============================================================
//
// Internal navigation between variantListView and JobStepsView MUST use
// Group + if/else. DO NOT use ZStack + .transition(.move(edge:)).
//
// ZStack with move transitions in NSPopover context:
//   => ZStack measures all children simultaneously (even invisible ones)
//   => Width collapses to zero during the transition
//   => .transition(.move(edge: .leading)) animates from the LEFT EDGE
//      OF THE ENTIRE SCREEN, not from within the popover
//   => Looks exactly like the left-jump bug
//   => This was tried. It was catastrophic. Do not try it again.
//
// ============================================================
// CAUSE 7 — WHY STEPS ARE PRE-LOADED HERE (v2.1)
// ============================================================
//
// JobStepsView now requires steps to be passed as an init parameter
// (pre-loaded before navigation). It no longer fetches its own data.
// This prevents @State changes after the view appears, which would
// change preferredContentSize => NSPopover re-anchors => left jump.
//
// When the user taps a job variant here, we:
//   1. Set isLoadingJob = true  (show a spinner row)
//   2. Fetch steps via the free function fetchJobSteps(jobID:scope:)
//   3. On completion, set selectedJob + selectedSteps  (navigate)
//
// The popover height does NOT change during the spinner because this
// view is already at .frame(minHeight:480, maxHeight:480). The spinner
// is content inside the fixed frame, not a size change.
//
// ⚠️ fetchJobSteps is a FREE FUNCTION in JobStep.swift — not a static method.
// ⚠️ Call as:  fetchJobSteps(jobID: job.id, scope: scope)
// ⚠️ NOT as:   JobStep.fetchJobSteps(...)  ← does not exist, will not compile
// ============================================================

struct MatrixGroupView: View {
    let baseName: String
    let jobs: [ActiveJob]
    let scope: String
    let onBack: () -> Void

    @State private var selectedJob: ActiveJob? = nil
    @State private var selectedSteps: [JobStep] = []
    @State private var isLoadingJob: ActiveJob? = nil
    @State private var tick = 0

    var body: some View {
        // ⚠️ Group + if/else for internal navigation.
        // DO NOT replace with ZStack + .transition(.move(edge:)).
        // See NAVIGATION RULE above.
        Group {
            if let job = selectedJob {
                // JobStepsView also has .frame(maxWidth:.infinity,...) on its body.
                // The two frames compose correctly — do not add another frame here.
                JobStepsView(
                    job: job,
                    steps: selectedSteps,
                    scope: scope,
                    onBack: {
                        selectedJob = nil
                        selectedSteps = []
                    }
                )
            } else {
                variantListView
            }
        }
        // ⚠️ THIS FRAME IS MANDATORY. See frame rule at top of file.
        // maxWidth:.infinity — DO NOT change to width:340
        // minHeight:480 — DO NOT remove
        // maxHeight:480 — DO NOT remove
        .frame(maxWidth: .infinity, minHeight: 480, maxHeight: 480)
    }

    // MARK: - Variant list

    private var variantListView: some View {
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
                    Button(action: { loadAndNavigate(to: job) }) {
                        HStack(spacing: 8) {
                            if isLoadingJob?.id == job.id {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 7, height: 7)
                            } else {
                                Circle()
                                    .fill(dotColor(for: job))
                                    .frame(width: 7, height: 7)
                            }

                            Text(job.matrixVariant ?? job.name)
                                .font(.system(size: 12))
                                .foregroundColor(job.isDimmed ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            Spacer()

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
                    .disabled(isLoadingJob != nil)
                }
                .padding(.bottom, 6)

            } // end VStack
        } // end ScrollView
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick += 1 }
        }
    }

    // MARK: - Pre-load steps then navigate

    private func loadAndNavigate(to job: ActiveJob) {
        guard isLoadingJob == nil else { return }
        isLoadingJob = job
        Task {
            // ⚠️ fetchJobSteps is a FREE FUNCTION — not JobStep.fetchJobSteps
            let steps = fetchJobSteps(jobID: job.id, scope: scope)
            await MainActor.run {
                selectedSteps = steps
                selectedJob = job
                isLoadingJob = nil
            }
        }
    }

    // MARK: - Helpers
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
