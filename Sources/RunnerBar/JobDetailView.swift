import AppKit
import SwiftUI

// ⚠️ REGRESSION GUARD — frame rules (ref #52 #54 #57)
//
// ARCHITECTURE:
//   AppDelegate uses sizingOptions=[] + manual contentSize.
//   In sizingOptions=[] mode, NSHostingController does NOT read ideal size.
//   The popover has a fixed contentSize set by openPopover() before show().
//   navigate() swaps hc.rootView ONLY while popover IS open — ZERO size changes.
//   JobDetailView renders inside the SAME fixed frame as PopoverMainView.
//
// RULE 1 — ROOT FRAME:
//   MUST use .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
//   This fills the fixed contentSize frame AppDelegate provides and pins to top.
//   The Spacer(minLength: 8) at VStack bottom absorbs remaining vertical space.
//   ❌ NEVER use .frame(idealWidth:) — only used in preferredContentSize mode
//   ❌ NEVER use .frame(width: 320) or .frame(height: ...) — fights fixed frame
//   ❌ NEVER use .fixedSize() — collapses to intrinsic size
//
// RULE 2 — NO SIZE CHANGES IN navigate():
//   navigate() fires while popover IS open. Any contentSize change = left-jump.
//   The fixed frame from openPopover() is shared by main and detail views.
//   openPopover() always sets height to computeMainHeight() (main view budget).
//   This means detail view gets main-view-height frame — that is intentional.
//   Detail content aligns to top, Spacer at bottom absorbs slack.
//
// RULE 3 — SPACERS ARE LOAD-BEARING:
//   Spacer() in header HStack and Spacer(minLength:8) at VStack bottom
//   MUST NOT be removed. They maintain layout under fixed-height frame.
struct JobDetailView: View {
    let job: ActiveJob
    let onBack: () -> Void
    @State private var tick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Back button + elapsed
            // ⚠️ Spacer() here is load-bearing (RULE 3) — do NOT remove
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
                Spacer()  // ⚠️ RULE 3: load-bearing — do NOT remove
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

            Spacer(minLength: 8)  // ⚠️ RULE 3: load-bearing — absorbs remaining height
        }
        // ⚠️ RULE 1: fill the fixed contentSize frame AppDelegate provides.
        // maxWidth: .infinity + maxHeight: .infinity + alignment: .top
        // pins all content to top-left within the fixed popover frame.
        // ❌ NEVER use idealWidth, fixedSize, or fixed width/height here.
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
