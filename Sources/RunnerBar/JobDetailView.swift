import AppKit
import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════════
// ⚠️ REGRESSION GUARD — READ BEFORE TOUCHING (ref #52 #54 #57)
// ═══════════════════════════════════════════════════════════════════════════════
//
// ── WHY EVERY PREVIOUS ATTEMPT FAILED (v0.22–v0.28) ──────────────────────
//   AppDelegate.openPopover() reads fittingSize of hc.rootView ONCE while
//   the popover is CLOSED. At that moment rootView is ALWAYS mainView().
//   It is NEVER JobDetailView at open time.
//   So fittingSize always reflects mainView height (~260–320px).
//   navigate() then swaps to JobDetailView inside that fixed frame.
//   If JobDetailView has 15 steps (~500px of content), it overflows the
//   ~300px frame and SwiftUI centres it — that is the centering bug.
//
//   Every attempted fix tried to make the frame taller:
//     a) resize in navigate()          — FORBIDDEN: popover open = left-jump (#52 #54)
//     b) resize in onChange            — FORBIDDEN: popover may be open = left-jump
//     c) preferredContentSize          — FORBIDDEN: re-anchors on every rootView swap
//     d) max(mainHeight, detailHeight) — breaks main view (too tall, empty space)
//     e) idealWidth tricks             — fittingSize is read from mainView, not here
//   All approaches re-introduced either the left-jump or a broken main view.
//
// ── THE CORRECT FIX (v0.29+) ──────────────────────────────────────────────
//   Don’t fight the frame — work within it.
//   Header (back button + job name) stays fixed at the top, always visible.
//   Steps list is wrapped in a ScrollView — scrolls within the available frame.
//   The view ALWAYS fits whatever frame AppDelegate gives it, regardless of
//   step count. Zero changes to AppDelegate, navigate(), onChange, sizingOptions.
//
// ── FRAME CONTRACT ────────────────────────────────────────────────────────────
//   This view receives a FIXED frame from AppDelegate — the same frame that
//   was sized to mainView()’s fittingSize at open time. That frame does not
//   change while the popover is open. This view must ALWAYS fill that frame
//   without overflowing it. ScrollView is the mechanism that makes this work.
//
// ── LAYOUT RULES ──────────────────────────────────────────────────────────────
//   ✔ Root: .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
//       This fills the fixed popover frame and pins content to the top.
//       maxHeight:.infinity does NOT expand the frame — it fills the existing one.
//   ✔ Steps list MUST be inside ScrollView — may be taller than the available frame
//   ✔ Header (HStack + job name Text + Divider) MUST be OUTSIDE ScrollView
//       If header goes inside ScrollView, the back button scrolls out of view and
//       becomes inaccessible when the list is long.
//   ❌ NEVER put header inside ScrollView — back button becomes inaccessible
//   ❌ NEVER remove ScrollView — the centering bug returns for jobs with many steps
//   ❌ NEVER add .idealWidth to root frame — fittingSize is read from mainView(),
//        not from this view. idealWidth here has zero effect on the popover size.
//   ❌ NEVER add .frame(height:) to root — fights AppDelegate’s fixed frame
//   ❌ NEVER add .fixedSize() to root — collapses the view
//   ❌ NEVER call navigate() directly from here — use the onBack/onSelectStep callbacks
//   ❌ NEVER resize in navigate() — popover is open when navigate() fires → left-jump
struct JobDetailView: View {
    let job: ActiveJob
    let onBack: () -> Void

    // onSelectStep: called when user taps a step row.
    // AppDelegate wires this to navigate(to: logView(job:step:)).
    // It is a callback rather than a direct navigate() call so that
    // JobDetailView has no dependency on AppDelegate and remains testable.
    let onSelectStep: (JobStep) -> Void

    // tick drives the live elapsed timer in the header.
    // It increments every second via a Timer in onAppear.
    @State private var tick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header: OUTSIDE ScrollView — always visible at top
            //
            // This HStack must stay outside the ScrollView so the back button
            // remains accessible even when the step list is very long.
            // The Spacer() between the back button and the elapsed timer is
            // load-bearing: it pushes the timer to the right edge. Without it
            // both items collapse to the left and the timer overlaps the button.
            HStack(spacing: 6) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.caption)
                        Text("Jobs").font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()  // ⚠️ load-bearing — do NOT remove (see above)
                LogCopyButton(
                    fetch: { completion in
                        let jobID = job.id
                        let scope = scopeFromHtmlUrl(job.htmlUrl) ?? ""
                        DispatchQueue.global(qos: .userInitiated).async {
                            completion(fetchJobLog(jobID: jobID, scope: scope))
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

            // Job name below the nav bar.
            // lineLimit(2) + fixedSize(horizontal:false, vertical:true) allows
            // the name to wrap to a second line without collapsing horizontally.
            Text(job.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Divider()  // visual separator between header and scrollable step list

            // ── Steps list: INSIDE ScrollView
            //
            // ⚠️ ScrollView is REQUIRED. See regression guard above.
            // The frame height is fixed by AppDelegate at mainView() fittingSize.
            // navigate() cannot resize (left-jump rule). ScrollView absorbs overflow.
            //
            // VStack inside the ScrollView: lays out step rows top-to-bottom.
            // .frame(maxWidth: .infinity, alignment: .leading) on the VStack ensures
            // each row stretches to the full width even when step names are short.
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
                            // Tapping a step row calls onSelectStep(step).
                            // AppDelegate translates this into navigate(to: logView(job:step:)).
                            Button(action: { onSelectStep(step) }) {
                                HStack(spacing: 8) {
                                    // Status/conclusion icon — always 14pt wide for alignment.
                                    Text(step.conclusionIcon)
                                        .font(.system(size: 11))
                                        .foregroundColor(stepColor(step))
                                        .frame(width: 14, alignment: .center)

                                    // Step name — truncates in the middle if too long,
                                    // so both the start and end of the name stay readable.
                                    Text(step.name)
                                        .font(.system(size: 12))
                                        .foregroundColor(step.status == "queued" ? .secondary : .primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    Spacer()  // ⚠️ load-bearing: pushes elapsed + chevron to right edge

                                    // Elapsed time, fixed at 40pt so all rows align vertically.
                                    Text(step.elapsed)
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.secondary)
                                        .frame(width: 40, alignment: .trailing)

                                    // Drill-down indicator — chevron.right signals in-app navigation.
                                    // (was arrow.up.right.square which implied opening a browser)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 3)
                                // contentShape(Rectangle()) makes the entire row — including
                                // the Spacer gap — tappable, not just the text/icon areas.
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Root frame contract (see FRAME CONTRACT above).
        // maxWidth/maxHeight:.infinity fills the fixed popover frame.
        // alignment:.top pins the header to the top of that frame.
        // ScrollView above ensures step content never overflows.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            // Live elapsed timer: increments tick every second.
            // elapsedLive(tick:) reads job.elapsed which uses Date() when job is running.
            // The tick parameter is consumed to suppress the @State-isolation warning;
            // the actual re-read of Date() happens inside job.elapsed.
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick += 1 }
        }
    }

    // Returns job.elapsed, re-evaluated every tick so the header updates live.
    // The tick parameter is intentionally unused (suppresses mutation warning).
    private func elapsedLive(tick _: Int) -> String { job.elapsed }

    // Color-codes the step icon based on conclusion/status.
    // in_progress steps are yellow (no conclusion yet).
    // queued/pending steps are secondary (dimmed).
    private func stepColor(_ step: JobStep) -> Color {
        switch step.conclusion {
        case "success":  return .green
        case "failure":  return .red
        default:         return step.status == "in_progress" ? .yellow : .secondary
        }
    }
}
