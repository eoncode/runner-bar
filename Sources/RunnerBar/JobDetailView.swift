import AppKit
import SwiftUI

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
//   • NO .fixedSize(horizontal: false, vertical: true) on any direct child of the
//     root VStack — this forces an infinite-height layout pass and corrupts fittingSize.
//
// ════════════════════════════════════════════════════════════════════════════════
// BANNED modifiers on the ROOT VStack or any DIRECT CHILD of it:
//
//   ❌ .frame(maxHeight: .infinity)         — corrupts fittingSize.width
//   ❌ .frame(height: <any constant>)       — prevents popover from resizing
//   ❌ .fixedSize(horizontal: false, vertical: true)  — forces unconstrained height
//   ❌ .fixedSize()                         — same problem
//   ❌ navigate() called directly           — use onBack / onSelectStep callbacks
//
// SAFE modifiers (inside HStack/ScrollView children, not root level):
//
//   ✔ .fixedSize() on individual Text labels inside HStack — fine, scoped
//   ✔ .frame(width:) on fixed-width labels — fine
//   ✔ .lineLimit(N) on Text — fine
//   ✔ .frame(maxWidth: .infinity, alignment: .leading) inside ScrollView — fine
//
// SCROLLVIEW maxHeight CAP — REQUIRED (ref #370):
//   The ScrollView wrapping the steps list MUST have a .frame(maxHeight:) cap.
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

/// Navigation level 2 (Jobs path): step list for a single `ActiveJob`.
///
/// Drill-down chain: PopoverMainView → JobDetailView → StepLogView.
struct JobDetailView: View {
    /// The job whose steps are displayed.
    let job: ActiveJob
    /// Called when the user taps the back button.
    let onBack: () -> Void
    /// Called when the user taps a step row.
    let onSelectStep: (JobStep) -> Void

    /// Drives the live elapsed timer in the header.
    @State private var tick = 0
    /// Retained so it can be invalidated on disappear to prevent a timer leak.
    @State private var tickTimer: Timer?

    var body: some View {
        // ⚠️ ROOT VStack — frame contract enforced at the BOTTOM of this body.
        // Do NOT add .frame(maxHeight:), .frame(height:), or .fixedSize() here.
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ──────────────────────────────────────────────────────────────
            HStack(spacing: 6) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.caption)
                        Text("Jobs").font(.caption)
                    }
                    .foregroundColor(.secondary)
                    .fixedSize()
                }
                .buttonStyle(.plain)
                Spacer()
                ReRunButton(
                    action: { completion in
                        let jobID = job.id
                        let scopeStr = scopeFromHtmlUrl(job.htmlUrl) ?? ""
                        if scopeStr.isEmpty {
                            log("ReRunButton › could not derive scope from htmlUrl: \(String(describing: job.htmlUrl))")
                        }
                        DispatchQueue.global(qos: .userInitiated).async {
                            let isOk = scopeStr.contains("/")
                                && ghPost("repos/\(scopeStr)/actions/jobs/\(jobID)/rerun")
                            completion(isOk)
                        }
                    },
                    isDisabled: job.status == "in_progress" || job.status == "queued"
                )
                CancelButton(
                    action: { completion in
                        let scopeStr = scopeFromHtmlUrl(job.htmlUrl) ?? ""
                        let runID = runIDFromHtmlUrl(job.htmlUrl)
                        guard scopeStr.contains("/"), let runID else {
                            log("CancelButton › could not derive scope/runID from htmlUrl: \(String(describing: job.htmlUrl))")
                            completion(false)
                            return
                        }
                        DispatchQueue.global(qos: .userInitiated).async {
                            completion(cancelRun(runID: runID, scope: scopeStr))
                        }
                    },
                    isDisabled: job.status != "in_progress" && job.status != "queued"
                )
                LogCopyButton(
                    fetch: { completion in
                        let jobID = job.id
                        let scopeStr = scopeFromHtmlUrl(job.htmlUrl) ?? ""
                        DispatchQueue.global(qos: .userInitiated).async {
                            completion(fetchJobLog(jobID: jobID, scope: scopeStr))
                        }
                    },
                    isDisabled: false
                )
                Text(job.isDimmed ? job.elapsed : elapsedLive(tick: tick))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            // ── Job title ──────────────────────────────────────────────────────────────
            Text(job.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                // ⚠️ DO NOT ADD .fixedSize(horizontal: false, vertical: true) here.
                .padding(.horizontal, 12)
                .padding(.bottom, job.startedAt != nil ? 3 : 8)

            // ── Job timing bar ──────────────────────────────────────────────────
            if let start = job.startedAt {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(wallTime(start))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    if let end = job.completedAt {
                        Text(wallTime(end))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    } else {
                        Text("running")
                            .font(.caption)
                            .foregroundColor(.yellow)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            Divider()

            // ── Steps list ──────────────────────────────────────────────────────────────
            // ⚠️ maxHeight cap is REQUIRED — see regression guard above (ref #370).
            // ❌ NEVER remove .frame(maxHeight:) from this ScrollView.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    if job.steps.isEmpty {
                        Text("No step data available")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(job.steps) { step in
                            Button(action: { onSelectStep(step) }, label: {
                                stepRow(step)
                            })
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // ⚠️ REQUIRED — caps preferredContentSize.height. Prevents side-jump.
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
            tickTimer = Timer.scheduledTimer(
                withTimeInterval: 1,
                repeats: true,
                block: { _ in tick += 1 }
            )
        }
        .onDisappear {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    // MARK: - Step row

    /// Single-height step row.
    /// Layout: [icon] [name …truncated] [HH:mm:ss → HH:mm:ss] [elapsed] [›]
    /// The name takes all available space (truncates in the middle if needed).
    /// Timestamps are right-aligned to the name, left-aligned to elapsed.
    /// Only rendered when step.startedAt is non-nil; queued steps show no timestamps.
    @ViewBuilder
    private func stepRow(_ step: JobStep) -> some View {
        HStack(spacing: 8) {
            // Icon
            Text(step.conclusionIcon)
                .font(.system(size: 11))
                .foregroundColor(stepColor(step))
                .frame(width: 14, alignment: .center)

            // Step name — truncates to give room to timestamps + elapsed
            Text(step.name)
                .font(.system(size: 12))
                .foregroundColor(step.status == "queued" ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            // Timestamps — shown only when the step has started
            if let start = step.startedAt {
                HStack(spacing: 3) {
                    Text(wallTime(start))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                    Text("→")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let end = step.completedAt {
                        Text(wallTime(end))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    } else {
                        Text("running")
                            .font(.caption)
                            .foregroundColor(.yellow)
                    }
                }
                .fixedSize()  // ✔ SAFE: scoped to this inner HStack, not root
            }

            // Elapsed duration
            Text(step.elapsed)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .fixedSize()  // ✔ SAFE: scoped
                .frame(width: 40, alignment: .trailing)

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    // MARK: - Helpers

    private func elapsedLive(tick _: Int) -> String { job.elapsed }

    private func stepColor(_ step: JobStep) -> Color {
        switch step.conclusion {
        case "success": return .green
        case "failure": return .red
        default: return step.status == "in_progress" ? .yellow : .secondary
        }
    }
}

// MARK: - Wallclock formatter

private let _wallTimeFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

private func wallTime(_ date: Date) -> String {
    _wallTimeFmt.string(from: date)
}
