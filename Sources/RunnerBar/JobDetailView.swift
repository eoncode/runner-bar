import AppKit
import SwiftUI

// ⚠️ REGRESSION GUARD — READ BEFORE TOUCHING (ref #52 #54 #57)
//
// ── WHY EVERY PREVIOUS ATTEMPT FAILED (v0.22–v0.28) ────────────────────────
//   AppDelegate.openPopover() reads fittingSize of hc.rootView ONCE, while
//   the popover is CLOSED. At that moment rootView is ALWAYS mainView().
//   It is NEVER JobDetailView at open time.
//   So fittingSize always reflects mainView height (~260-320px).
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
//   All four re-introduced either the left-jump or a broken main view.
//
// ── THE CORRECT FIX (v0.29) ─────────────────────────────────────────────────
//   Don’t fight the frame — work within it.
//   Header (back button + job name) stays fixed at the top, always visible.
//   Steps list is wrapped in a ScrollView — scrolls within the available frame.
//   The view ALWAYS fits whatever frame AppDelegate gives it, regardless of
//   step count. Zero changes to AppDelegate, navigate(), onChange, sizingOptions.
//
// ── RULES ─────────────────────────────────────────────────────────────────────
//   ✔ Steps list MUST stay inside ScrollView — may be taller than available frame
//   ✔ Header (HStack + Text + Divider) MUST stay outside ScrollView — always visible
//   ✔ Root: .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
//   ❌ NEVER put header inside ScrollView — back button becomes inaccessible if clipped
//   ❌ NEVER remove ScrollView — centering bug returns for jobs with many steps
//   ❌ NEVER add idealWidth to root frame — only meaningful under preferredContentSize,
//        which is FORBIDDEN (#52 #54). idealWidth here has zero effect on the current
//        fittingSize architecture (fittingSize is read from mainView(), not here).
//   ❌ NEVER add .frame(height:) to root — fights AppDelegate’s fixed frame
//   ❌ NEVER add .fixedSize() to root — collapses view, breaks layout
//   ❌ NEVER resize in navigate() — popover is open = left-jump (#52 #54)
struct JobDetailView: View {
    let job: ActiveJob
    let onBack: () -> Void
    @State private var tick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header: OUTSIDE ScrollView — always visible at top
            // ⚠️ Spacer() is load-bearing — do NOT remove
            HStack(spacing: 6) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.caption)
                        Text("Jobs").font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()  // ⚠️ load-bearing — do NOT remove
                Text(job.isDimmed ? job.elapsed : elapsedLive(tick: tick))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            Text(job.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Divider()

            // ── Steps: INSIDE ScrollView
            // ⚠️ ScrollView is REQUIRED. See regression guard above.
            // The frame height is fixed by AppDelegate at mainView() fittingSize.
            // navigate() cannot resize (left-jump rule). ScrollView absorbs overflow.
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
                            Button(action: { openLog(step: step) }) {
                                HStack(spacing: 8) {
                                    Text(step.conclusionIcon)
                                        .font(.system(size: 11))
                                        .foregroundColor(stepColor(step))
                                        .frame(width: 14, alignment: .center)
                                    Text(step.name)
                                        .font(.system(size: 12))
                                        .foregroundColor(step.status == "queued" ? .secondary : .primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()  // load-bearing — do NOT remove
                                    Text(step.elapsed)
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.secondary)
                                        .frame(width: 40, alignment: .trailing)
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // ⚠️ Fill the fixed frame AppDelegate provides. Pin to top.
        // maxHeight: .infinity is correct here — the ScrollView above
        // ensures content never overflows regardless of step count.
        // ❌ NEVER add idealWidth — fittingSize is read from mainView(), not here
        // ❌ NEVER add .frame(height:) — fights AppDelegate’s fixed frame
        // ❌ NEVER add .fixedSize() — collapses the view
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick += 1 }
        }
    }

    private func openLog(step: JobStep) {
        let base = job.htmlUrl ?? "https://github.com"
        let urlString = "\(base)#step:\(step.id)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func elapsedLive(tick _: Int) -> String { job.elapsed }

    private func stepColor(_ step: JobStep) -> Color {
        switch step.conclusion {
        case "success":  return .green
        case "failure":  return .red
        default:         return step.status == "in_progress" ? .yellow : .secondary
        }
    }
}
