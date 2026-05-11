import AppKit
import SwiftUI

// ⚠️ REGRESSION GUARD — Architecture 1 (ref #49 #51 #52 #53 #54 #57 #321 #370 #375 #376 #377)
//
// sizingOptions = .preferredContentSize + idealWidth:420 on root drives ALL sizing.
// Root frame MUST be fixed width AND fixed height — never maxHeight:.infinity.
//
// WHY maxHeight:.infinity CAUSES SIDE JUMP:
//   .infinity propagates the full uncapped ScrollView content height as
//   preferredContentSize.height on every state change (tick timer, step status update).
//   NSPopover sees a changed contentSize → re-anchors → side jump on every update.
//
// FIX: fixed frame 420×480 on root. preferredContentSize = 420×480 always.
//   ScrollView clips and scrolls content internally. No jump possible.
//
// ❌ NEVER use .fixedSize inside a ScrollView here.
// ❌ NEVER remove idealWidth:420.
// ❌ NEVER revert maxHeight to .infinity — re-introduces the jump.

/// Navigation level 2 (Jobs path): step list for a single `ActiveJob`.
struct JobDetailView: View {
    let job: ActiveJob
    let onBack: () -> Void
    let onSelectStep: (JobStep) -> Void

    @State private var tick = 0
    @State private var tickTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header: OUTSIDE ScrollView
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
                        guard scopeStr.contains("/"), let runID else { completion(false); return }
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

            Text(job.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            Divider()

            // ── Steps list: INSIDE ScrollView
            // ⚠️ NO .fixedSize inside this ScrollView.
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
                                    Spacer()
                                    Text(step.elapsed)
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // ⚠️ FIXED frame — NOT maxHeight:.infinity.
        // preferredContentSize = 420×480 always → NSPopover never re-anchors.
        // ❌ NEVER revert to maxHeight:.infinity.
        .frame(minWidth: 420, idealWidth: 420, maxWidth: 420,
               minHeight: 480, idealHeight: 480, maxHeight: 480)
        .onAppear {
            tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick += 1 }
        }
        .onDisappear {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    private func elapsedLive(tick _: Int) -> String { job.elapsed }

    private func stepColor(_ step: JobStep) -> Color {
        switch step.conclusion {
        case "success": return .green
        case "failure": return .red
        default: return step.status == "in_progress" ? .yellow : .secondary
        }
    }
}
