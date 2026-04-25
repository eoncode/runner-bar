import AppKit
import SwiftUI

// ⚠️ REGRESSION GUARD — frame rules (ref issue #59, causes 1-5 in AppDelegate.swift)
//
// RULE 1: This view MUST use .frame(maxWidth: .infinity) as its root modifier.
//   AppDelegate uses sizingOptions = .preferredContentSize.
//   The root container (PopoverMainView/JobDetailView) sets .frame(idealWidth: 340)
//   in the NSHostingController — AppDelegate wraps BOTH views in AnyView and the
//   navigate() call swaps hc.rootView.
//   JobDetailView is the root view when on detail screen. It must fill the 340px
//   wide popover without overriding the ideal width set by NSHostingController.
//   .frame(maxWidth: .infinity) fills available width without touching idealWidth.
//   ❌ NEVER use .frame(width: 340) — overrides ideal width contract
//   ❌ NEVER use .frame(idealWidth: 340) here — hc already has it as root view
//
// RULE 2: The Spacer() in the header HStack is load-bearing.
//   Removes it causes elapsed time to collide with back button text.
//
// RULE 3: NEVER add contentSize or setFrameSize calls inside navigate().
//   See AppDelegate.swift — navigate() fires while popover IS open.
//   Any size op while popover is open = re-anchor = left-jump.
//
// RULE 4: Spacer(minLength: 8) at VStack bottom absorbs remaining height.
//   preferredContentSize grows the popover to fit all steps.
//   If steps are tall, popover grows. That is correct and expected.
struct JobDetailView: View {
    let job: ActiveJob
    let onBack: () -> Void
    @State private var tick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Back button + elapsed
            // ⚠️ RULE 2: Spacer() here is load-bearing — do NOT remove
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
                Spacer()  // ⚠️ RULE 2: load-bearing — do NOT remove
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

            Spacer(minLength: 8)  // ⚠️ RULE 4: absorbs remaining height
        }
        // ⚠️ RULE 1: maxWidth: .infinity fills available width without overriding idealWidth.
        // The hc.rootView swap in navigate() means this IS the root view while on detail screen.
        // idealWidth is already set by the NSHostingController container level.
        // minHeight: 300 prevents popover from collapsing on jobs with very few steps.
        // maxHeight: 480 caps unbounded growth for jobs with very many steps.
        // ❌ NEVER use .frame(width: 340) here
        // ❌ NEVER use .frame(idealWidth: 340) here — already set at container level
        .frame(maxWidth: .infinity, minHeight: 300, maxHeight: 480, alignment: .top)
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
