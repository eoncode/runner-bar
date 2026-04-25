import AppKit
import SwiftUI

// ⚠️ REGRESSION GUARD — frame rules (ref #52 #54 #57)
//
// ARCHITECTURE:
//   AppDelegate reads hc.view.fittingSize in openPopover() to size the popover.
//   fittingSize reads SwiftUI's IDEAL size. Both PopoverMainView AND JobDetailView
//   MUST declare .frame(idealWidth: 340) so fittingSize returns the correct width.
//   Without idealWidth, fittingSize.width = 0 and layout collapses.
//
// ROOT CAUSE OF VERTICAL CENTERING (v0.24–v0.27 regression):
//   openPopover() sets the frame size from fittingSize of the CURRENT view
//   (always PopoverMainView, which is ~260–320px tall).
//   When navigate() swaps to JobDetailView (which is taller, ~500px),
//   the view frame stays at the smaller main-view height.
//   JobDetailView had .frame(maxWidth:.infinity, maxHeight:.infinity, alignment:.top)
//   but no idealWidth — so its OWN fittingSize was never read.
//   RESULT: content was squished/vertically centered in a too-small frame.
//
// THE FIX:
//   .frame(idealWidth: 340, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
//   idealWidth: 340 — matches PopoverMainView, fittingSize contract
//   maxHeight: .infinity + alignment: .top — fills frame and pins to top
//   Spacer(minLength: 8) at VStack bottom — absorbs remaining space if any
//
// RULES:
//   ✔ .frame(idealWidth: 340, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
//   ❌ NEVER use .frame(width: 340) — sets layout width, NOT ideal width
//   ❌ NEVER use .frame(maxWidth:.infinity) alone — no idealWidth = fittingSize.width = 0
//   ❌ NEVER use .fixedSize() — collapses to intrinsic size, breaks fill
//   ❌ NEVER add .frame(height:) — fights fittingSize height reading
//   ❌ NEVER remove Spacer() from header HStack — load-bearing (RULE 3)
//   ❌ NEVER remove Spacer(minLength: 8) at VStack bottom — absorbs slack height
struct JobDetailView: View {
    let job: ActiveJob
    let onBack: () -> Void
    @State private var tick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Back button + elapsed
            // ⚠️ Spacer() here is load-bearing — do NOT remove
            HStack(spacing: 6) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.caption)
                        Text("Jobs")
                            .font(.caption)
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

            // ── Job name
            Text(job.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Divider()

            // ── Steps list
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

            Spacer(minLength: 8)  // ⚠️ load-bearing — absorbs remaining height
        }
        // ⚠️ CRITICAL: idealWidth:340 MUST match PopoverMainView's idealWidth.
        //   AppDelegate reads fittingSize in openPopover() to size the popover.
        //   fittingSize.height = VStack intrinsic content height (this view's steps).
        //   fittingSize.width  = 340 (from idealWidth).
        //   maxHeight:.infinity + alignment:.top pins content to top of the frame.
        //   Spacer(minLength:8) at VStack bottom absorbs any remaining slack.
        //
        //   ❌ NEVER remove idealWidth:340 — fittingSize.width collapses to 0
        //   ❌ NEVER use .frame(width:340) — does NOT set ideal width
        //   ❌ NEVER use .fixedSize() — collapses to intrinsic size
        //   ❌ NEVER add .frame(height:) — fights fittingSize height reading
        .frame(idealWidth: 340, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
