import AppKit
import SwiftUI

// ⚠️ REGRESSION GUARD — frame rules (ref #52 #54 #57)
//
// ARCHITECTURE:
//   AppDelegate reads hc.view.fittingSize in openPopover() to size the popover.
//   fittingSize reads SwiftUI's IDEAL size.
//   This view MUST declare .frame(idealWidth: 340) so fittingSize.width = 340.
//   fittingSize.height = VStack intrinsic content height (all steps + header).
//   AppDelegate uses that height to size the popover exactly to content.
//
// ROOT CAUSE OF VERTICAL CENTERING (fixed in v0.28):
//   .frame(maxHeight: .infinity) was present on the root frame.
//   This told SwiftUI the ideal height is "infinite" → fittingSize returned a
//   huge value → AppDelegate made the popover very tall → content appeared
//   centred in a too-tall popover (or clipped if frame was from main view).
//   FIX: removed maxHeight — fittingSize.height now = actual content height.
//
// RULES:
//   ✔ .frame(idealWidth: 340, maxWidth: .infinity, alignment: .top)
//   ❌ NEVER add maxHeight: .infinity — causes vertical centering regression
//   ❌ NEVER use .frame(width: 340) — sets layout width, NOT ideal width
//   ❌ NEVER use .fixedSize() — collapses to intrinsic width
//   ❌ NEVER add .frame(height:) — fixed height fights fittingSize
//   ❌ NEVER remove Spacer() from header HStack — load-bearing
//   ❌ NEVER remove Spacer(minLength: 8) at VStack bottom — bottom padding
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

            Spacer(minLength: 8)  // ⚠️ bottom padding — do NOT remove
        }
        // ⚠️ CRITICAL FRAME CONTRACT:
        //   idealWidth: 340 — fittingSize.width = 340 (must match PopoverMainView)
        //   maxWidth: .infinity — fills popover width
        //   alignment: .top — pins VStack to top of frame
        //
        //   ❌ NEVER add maxHeight: .infinity — causes vertical centering regression
        //   ❌ NEVER use .frame(width: 340) — does NOT set ideal width
        //   ❌ NEVER use .fixedSize() — collapses width to intrinsic
        //   ❌ NEVER add .frame(height:) — fights fittingSize height reading
        .frame(idealWidth: 340, maxWidth: .infinity, alignment: .top)
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
