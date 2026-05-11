import AppKit
import SwiftUI
// swiftlint:disable identifier_name vertical_whitespace_opening_braces superfluous_disable_command

// ════════════════════════════════════════════════════════════════════════════════
// ⚠️⚠️⚠️  POPOVER SIDE-JUMP REGRESSION GUARD — READ THIS BEFORE ANY EDIT  ⚠️⚠️⚠️
// ════════════════════════════════════════════════════════════════════════════════
//
// SYMPTOM:  Popover jumps sideways (shifts left/right) when navigate() is called.
// ROOT CAUSE: AppDelegate sizes the popover window using SwiftUI's fittingSize.
//             fittingSize is computed by offering the view an UNCONSTRAINED size.
//             If the view expands to fill infinite height (maxHeight: .infinity),
//             SwiftUI returns a non-deterministic fittingSize.width, which causes
//             AppKit to re-position the popover anchor every time the root view swaps.
//
// ════════════════════════════════════════════════════════════════════════════════
// THE ONE FRAME RULE (applies to THIS file and EVERY detail/settings view):
//
//   .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
//
//   • idealWidth: 480  — MUST match AppDelegate.fixedWidth (currently 480).
//                        If you change fixedWidth in AppDelegate, change this too.
//   • maxWidth: .infinity — lets the view fill the popover width.
//   • NO maxHeight — letting SwiftUI compute natural height from content is what
//                    allows the popover to resize correctly on navigate().
//   • NO .frame(height:) anywhere on the root VStack.
//   • NO .fixedSize(horizontal: false, vertical: true) on multi-line title texts
//     that are direct children of the root VStack — corrupts fittingSize.
//
// ════════════════════════════════════════════════════════════════════════════════
// BANNED modifiers on the ROOT VStack or any DIRECT CHILD of it:
//
//   ❌ .frame(maxHeight: .infinity)         — corrupts fittingSize.width
//   ❌ .frame(height: <any constant>)       — prevents popover from resizing
//   ❌ .fixedSize(horizontal: false, vertical: true)  — forces unconstrained height
//   ❌ .fixedSize()                         — same problem
//   ❌ navigate() called directly           — use onBack / onSelectJob callbacks
//
// SAFE modifiers (inside HStack/ScrollView children, not root level):
//
//   ✔ .fixedSize() on individual Text labels inside HStack — fine, scoped
//   ✔ .frame(width:) on fixed-width labels — fine
//   ✔ .lineLimit(N) on Text — fine
//   ✔ .frame(maxWidth: .infinity, alignment: .leading) inside ScrollView — fine
//
// SCROLLVIEW maxHeight CAP — REQUIRED (ref #370):
//   The ScrollView wrapping the jobs list MUST have a .frame(maxHeight:) cap.
//   Without it, with sizingOptions=.preferredContentSize, SwiftUI reports the
//   full unbounded content height as preferredContentSize.height on navigate().
//   NSPopover re-anchors on any preferredContentSize change → side-jump.
//   The cap is computed from NSScreen.main so it adapts to any screen size.
//   ✅ ALWAYS keep .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
//   ❌ NEVER remove the maxHeight cap from the ScrollView.
//   ❌ NEVER use a fixed constant — must adapt to screen size.
//
// ════════════════════════════════════════════════════════════════════════════════
// HISTORY:
//   Broken by: adding .frame(maxHeight: .infinity) to root (multiple times)
//   Fixed by:  replacing with .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
//   Bug ref:   issue #294, commits 318da0b, fd1c960
//   #22 note:  idealWidth was 420, bumped to 480 to match AppDelegate.fixedWidth after
//              fixedWidth was widened in commit #22. NEVER let these diverge again.
//   #370 fix:  ScrollView maxHeight cap added to prevent side-jump on navigate.
// ════════════════════════════════════════════════════════════════════════════════

/// Navigation level 2a (Actions path): shows the flat job list for a commit/PR group.
///
/// Drill-down chain:
///   PopoverMainView (action row tap)
///   → ActionDetailView            ← this view
///   → JobDetailView (step list)   ← existing, unchanged
///   → StepLogView (log)           ← existing, unchanged
struct ActionDetailView: View {
    let group: ActionGroup
    let onBack: () -> Void
    /// Called when user taps a job row. AppDelegate wires this to detailViewFromAction(job:group:).
    let onSelectJob: (ActiveJob) -> Void

    /// Drives the live elapsed timer every second.
    @State private var tick = 0
    /// Held so we can invalidate on disappear and prevent timer accumulation
    /// when the user navigates away and back (AppDelegate swaps rootView each time).
    @State private var tickTimer: Timer?

    var body: some View {
        // ⚠️ ROOT VStack — frame contract enforced at the BOTTOM of this body.
        // Do NOT add .frame(maxHeight:), .frame(height:), or .fixedSize() here.
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ────────────────────────────────────────────────────────────
            // MUST remain OUTSIDE ScrollView. Do not move into ScrollView.
            // Adding .fixedSize() or .frame(height:) to this HStack will
            // corrupt the parent fittingSize — see regression guard above.
            HStack(spacing: 6) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.caption)
                        Text("Actions").font(.caption)
                    }
                    .foregroundColor(.secondary)
                    // ✔ .fixedSize() here is SAFE — scoped to this small label HStack.
                    .fixedSize()
                }
                .buttonStyle(.plain)
                Spacer()  // ⚠️ load-bearing — pushes elapsed to right edge
                ReRunButton(
                    action: { completion in
                        let scope = group.repo
                        let runIDs = group.runs.map { $0.id }
                        DispatchQueue.global(qos: .userInitiated).async {
                            let ok = runIDs.allSatisfy { runID in
                                ghPost("repos/\(scope)/actions/runs/\(runID)/rerun-failed-jobs")
                            }
                            completion(ok)
                        }
                    },
                    isDisabled: group.groupStatus == .inProgress
                )
                // ⚠️ CancelButton: when isDisabled=true it is INVISIBLE (opacity 0).
                // This is intentional — do not change to a faded state.
                // See CancelButton.swift regression guard.
                CancelButton(
                    action: { completion in
                        let scope = group.repo
                        let runIDs = group.runs.map { $0.id }
                        DispatchQueue.global(qos: .userInitiated).async {
                            let ok = runIDs.allSatisfy { runID in
                                cancelRun(runID: runID, scope: scope)
                            }
                            completion(ok)
                        }
                    },
                    isDisabled: group.groupStatus != .inProgress
                )
                LogCopyButton(
                    fetch: { completion in
                        let g = group
                        DispatchQueue.global(qos: .userInitiated).async {
                            completion(fetchActionLogs(group: g))
                        }
                    },
                    isDisabled: false
                )
                Text(elapsedLive(tick: tick))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            // ── Group title block ─────────────────────────────────────────────────
            // .fixedSize(horizontal:false,vertical:true) is BANNED on group.title Text.
            // Use lineLimit + truncationMode instead. See regression guard above.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.label)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                    Text(group.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        // ⚠️ DO NOT ADD .fixedSize(horizontal: false, vertical: true) here.
                        // It was removed intentionally. See regression guard at top of file.
                        .truncationMode(.tail)
                }
                if let branch = group.headBranch {
                    Text(branch)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("\(group.jobsDone)/\(group.jobsTotal) jobs concluded")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            // ── Jobs list: MUST be inside ScrollView ─────────────────────────────
            // NEVER move the header above outside into here.
            // ⚠️ maxHeight cap is REQUIRED — see regression guard above (ref #370).
            // Without it, preferredContentSize.height = full content height on navigate
            // → NSPopover re-anchors → side-jump.
            // ❌ NEVER remove .frame(maxHeight:) from this ScrollView.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    if group.jobs.isEmpty {
                        Text("No jobs available")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(group.jobs) { job in
                            Button(action: { onSelectJob(job) }, label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(jobDotColor(for: job))
                                        .frame(width: 7, height: 7)
                                    Text(job.name)
                                        .font(.system(size: 12))
                                        .foregroundColor(job.isDimmed ? .secondary : .primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer()  // ⚠️ load-bearing
                                    if let conclusion = job.conclusion {
                                        Text(conclusionLabel(conclusion))
                                            .font(.caption)
                                            .foregroundColor(conclusionColor(conclusion))
                                            .frame(width: 76, alignment: .trailing)
                                    } else {
                                        Text(jobStatusLabel(for: job))
                                            .font(.caption)
                                            .foregroundColor(jobStatusColor(for: job))
                                            .frame(width: 76, alignment: .trailing)
                                    }
                                    Text(job.elapsed)
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.secondary)
                                        .frame(width: 40, alignment: .trailing)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            })
                            .buttonStyle(.plain)
                        }
                    }
                }
                // ✔ .frame(maxWidth: .infinity) inside ScrollView is SAFE.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // ⚠️ REQUIRED — caps preferredContentSize.height. Prevents side-jump on navigate.
            // Matches SettingsView and PopoverMainView pattern (issue #370).
            // ❌ NEVER remove this modifier.
            .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
        }
        // ════════════════════════════════════════════════════════════════════════
        // ⚠️ THE ONE FRAME RULE — see regression guard at top of this file.
        // idealWidth MUST match AppDelegate.fixedWidth (480).
        // DO NOT change to .frame(maxWidth: .infinity, maxHeight: .infinity)
        // DO NOT reduce idealWidth back to 420 — fixedWidth is 480, not 420
        // DO NOT add .frame(height:) or .fixedSize() here
        // ════════════════════════════════════════════════════════════════════════
        .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
        .onAppear {
            tickTimer?.invalidate()
            tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick += 1 }
        }
        .onDisappear {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    private func elapsedLive(tick _: Int) -> String { group.elapsed }

    // MARK: - Job row helpers

    private func jobDotColor(for job: ActiveJob) -> Color {
        if job.isDimmed { return .secondary }
        return job.status == "in_progress" ? .yellow : .gray
    }

    private func jobStatusLabel(for job: ActiveJob) -> String {
        switch job.status {
        case "in_progress": return "In Progress"
        case "queued":      return "Queued"
        default:            return "Pending"
        }
    }

    private func jobStatusColor(for job: ActiveJob) -> Color {
        job.status == "in_progress" ? .yellow : .secondary
    }

    private func conclusionLabel(_ c: String) -> String {
        switch c {
        case "success":   return "\u{2713} success"
        case "failure":   return "\u{2717} failure"
        case "cancelled": return "\u{2297} cancelled"
        case "skipped":   return "\u{2212} skipped"
        default:          return c
        }
    }

    private func conclusionColor(_ c: String) -> Color {
        switch c {
        case "success": return .green
        case "failure": return .red
        default:        return .secondary
        }
    }
}
// swiftlint:enable identifier_name vertical_whitespace_opening_braces superfluous_disable_command
