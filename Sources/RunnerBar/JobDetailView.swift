import AppKit
import SwiftUI

// ⚠️ REGRESSION GUARD — frame rules (ref issue #59)
//
// RULE 1: Root body MUST use .frame(idealWidth: 320, maxWidth: 320)
//   AppDelegate uses sizingOptions = .preferredContentSize.
//   preferredContentSize reads the SwiftUI IDEAL size.
//   If idealWidth is not set, SwiftUI collapses width to near-zero
//   and the back button / header become invisible.
//   NEVER use .frame(maxWidth: .infinity) as the root frame.
//   NEVER use .frame(width: 320) — overrides ideal size.
//
// RULE 2: NEVER set popover.contentSize anywhere.
//   Any write to contentSize re-anchors the popover X position = left-jump.
//
// RULE 3: Steps list does NOT need a ScrollView for typical job counts.
//   preferredContentSize auto-grows the popover height to fit all steps.
//   If you add ScrollView, set a maxHeight or the popover will grow unbounded.
struct JobDetailView: View {
    let job: ActiveJob
    let onBack: () -> Void
    @State private var tick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Back button + elapsed
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

            Text(job.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Divider()

            // ── Steps
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
                            Spacer()  // ⚠️ load-bearing — do NOT remove
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

            Spacer(minLength: 8)
        }
        // ⚠️ RULE 1: idealWidth=320 is REQUIRED for preferredContentSize.
        // NEVER replace with .frame(maxWidth: .infinity) — collapses width.
        // NEVER replace with .frame(width: 320) — overrides ideal size.
        // Must match PopoverMainView’s root frame exactly.
        .frame(idealWidth: 320, maxWidth: 320, alignment: .top)
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick += 1 }
        }
    }

    private func openLog(step: JobStep) {
        // Open GitHub log URL anchored to the step number
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
