import SwiftUI

// ============================================================
// ⚠️⚠️⚠️  STOP. READ THIS ENTIRE COMMENT BEFORE TOUCHING THIS FILE.  ⚠️⚠️⚠️
// ============================================================
// VERSION: v2.2 (keep in sync with AppDelegate.swift)
//
// This view is the deepest nav state: PopoverView → JobStepsView → StepLogView.
// It exists inside an NSPopover whose sizing is brutally fragile.
// The same left-jump bug was introduced 30+ times in a single day on this project.
// Read AppDelegate.swift SECTION 1 and PopoverView.swift SECTION 1 before
// making ANY change to this file.
//
// ============================================================
// SECTION 1 — FRAME CONTRACT (the one rule that matters most)
// ============================================================
//
// The body VStack MUST end with:
//   .frame(maxWidth: .infinity, minHeight: 480, maxHeight: 480)
//
// WHY maxWidth: .infinity and NOT width: 340:
//   PopoverView root Group has .frame(idealWidth: 340).
//   NSHostingController reads SwiftUI's IDEAL size (not layout size)
//   to set preferredContentSize. idealWidth:340 on the root Group
//   locks preferredContentSize.width = 340 across ALL nav states.
//
//   .frame(width: 340) on ANY child view overrides the ideal width
//   contract. When navigating to a child with width:340, the ideal
//   width is reported differently => preferredContentSize.width changes
//   => NSPopover re-anchors its full screen position => left jump.
//
//   .frame(maxWidth: .infinity) fills the space the parent has already
//   established via idealWidth:340. It does NOT fight the ideal width.
//
//   ✘ DO NOT change to: .frame(width: 340, height: 480)
//   ✘ DO NOT change to: .frame(width: 340, minHeight: 480, maxHeight: 480)
//   ✘ DO NOT change to: .frame(maxWidth: 340, ...)
//   ✔ KEEP AS:          .frame(maxWidth: .infinity, minHeight: 480, maxHeight: 480)
//
// WHY minHeight: 480, maxHeight: 480:
//   Pins this nav state to exactly 480pt so the popover does not
//   shrink/expand when navigating here from JobStepsView (also 480pt).
//   Removing minHeight => popover may shrink => re-anchor => left jump.
//
// ============================================================
// SECTION 2 — ASYNC LOADING IS ALLOWED HERE (but read the rules)
// ============================================================
//
// Unlike JobStepsView (which must NOT load async — see CAUSE 7),
// StepLogView IS allowed to load its log async via loadLog() in onAppear.
//
// WHY this is safe here but not in JobStepsView:
//   The outer .frame(minHeight:480, maxHeight:480) pins the view size
//   to exactly 480pt regardless of content. Whether isLoading=true
//   (spinner) or isLoading=false (log lines), the view is always 480pt.
//   The @State changes (isLoading, lines) trigger SwiftUI re-renders
//   but those re-renders report the same ideal size (480pt) because
//   the frame clamps it. No size change => no re-anchor => no jump.
//
// CONTRAST with JobStepsView (CAUSE 7):
//   In v1.7-v1.9, JobStepsView loaded steps async. Even though its
//   frame was also 480pt, the @State changes caused SwiftUI to
//   recalculate preferredContentSize differently (content structure
//   change: spinner VStack → step list VStack). NSPopover re-anchored.
//   Steps were moved to pre-load in PopoverView to fix this.
//   Logs are fetched here because the log content structure is stable
//   (always a ScrollView with LazyVStack), just the data changes.
//
// RULE: Do NOT change @State lines or isLoading from OUTSIDE this view
//   (e.g., do not pass them as bindings or modify them from a parent).
//   The only writes must be from loadLog() running on the main queue.
//
// ============================================================
// SECTION 3 — NAVIGATION CONTRACT
// ============================================================
//
// This view is navigated to from JobStepsView using Group + if/else:
//   if let step = selectedStep { StepLogView(...) } else { stepsListView }
//
// DO NOT change that to ZStack + .transition(.move(edge:)).
//   In NSPopover context, ZStack + move transition animates from the
//   LEFT EDGE OF THE SCREEN, looks identical to the left-jump bug,
//   and collapses the width to zero during animation.
//   This was tried. It was catastrophic. Do not try it again.
//
// ============================================================
// SECTION 4 — PRE-COMMIT CHECKLIST FOR THIS FILE
// ============================================================
//
// Before pushing any change to this file, verify:
//   [ ] body VStack still ends with .frame(maxWidth:.infinity, minHeight:480, maxHeight:480)
//   [ ] No .frame(width:340) anywhere in this file
//   [ ] No navigation added using ZStack + transitions
//   [ ] loadLog() still runs on DispatchQueue.global then dispatches to main
//   [ ] @State lines and isLoading are only written from loadLog()
//   [ ] Version string bumped if logic changed
//
// ============================================================

struct StepLogView: View {
    let job: ActiveJob
    let step: JobStep
    let scope: String
    let onBack: () -> Void

    // ⚠️ These @State properties are written ONLY from loadLog().
    // Writing them from outside this view (binding, parent, etc.) is
    // forbidden — any @State change while the popover is open risks
    // triggering a re-render that changes preferredContentSize.
    // The fixed .frame(minHeight:480,maxHeight:480) makes this safe
    // for loadLog() specifically. See SECTION 2.
    @State private var lines: [String] = []
    @State private var isLoading = true
    @State private var truncated = false
    @State private var errorMessage: String? = nil

    private let maxLines = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header
            HStack(spacing: 6) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(step.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(job.name)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // ── Log content
            // All branches (loading / error / empty / lines) must be the same
            // visual height. The outer frame clamps them all to 480pt but
            // using .frame(maxHeight: .infinity) inside ensures they expand
            // to fill rather than collapsing — which keeps the outer ideal
            // size stable regardless of which branch is active.
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView().padding(.vertical, 16)
                    Spacer()
                }
                .frame(maxHeight: .infinity)
            } else if let err = errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 24)
            } else if lines.isEmpty {
                Text("No log output available")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxHeight: .infinity)
            } else {
                if truncated {
                    Text("(showing last \(maxLines) lines)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                }
                // ⚠️ ScrollView + LazyVStack is correct here.
                // Unlike jobListView (which must NOT use ScrollView),
                // this ScrollView is INSIDE the .frame(maxHeight:480) clamp,
                // so it does not expose infinite preferred height to
                // NSHostingController. Safe to use here.
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.primary.opacity(0.85))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }
        }
        // ⚠️⚠️⚠️  THIS FRAME IS MANDATORY. SEE SECTION 1.  ⚠️⚠️⚠️
        //
        // maxWidth: .infinity — DO NOT change to width:340
        //   width:340 on a child view overrides the root Group's idealWidth:340
        //   contract and causes preferredContentSize.width to change on
        //   navigation => NSPopover re-anchors => left jump.
        //
        // minHeight: 480 — DO NOT remove
        //   Without minHeight, navigating here shrinks the popover height
        //   => preferredContentSize.height changes => re-anchor => left jump.
        //
        // maxHeight: 480 — DO NOT remove
        //   Prevents the log content from expanding beyond 480pt.
        .frame(maxWidth: .infinity, minHeight: 480, maxHeight: 480)
        .onAppear { loadLog() }
    }

    // MARK: - Data
    //
    // ⚠️ loadLog() is the ONLY place @State lines, isLoading, truncated,
    // and errorMessage are written. See SECTION 2 for why this is safe.
    // DO NOT add a second load path or a refresh timer that writes lines.
    // Writing lines = @State change = re-render = possible size recalc.

    private func loadLog() {
        isLoading = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let (logLines, wasTruncated) = fetchStepLog(
                jobID: job.id,
                stepNumber: step.id,
                scope: scope,
                maxLines: maxLines
            )
            DispatchQueue.main.async {
                // Detect Azure BlobNotFound or any XML error response
                if logLines.count == 1,
                   let first = logLines.first,
                   first.contains("BlobNotFound") || first.hasPrefix("<?xml") || first.contains("<Error>") {
                    errorMessage = "Log unavailable\nGitHub has expired this step's log."
                    lines = []
                } else {
                    lines = logLines
                    truncated = wasTruncated
                }
                isLoading = false
            }
        }
    }
}
