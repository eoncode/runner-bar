import AppKit
import SwiftUI

// ⚠️ REGRESSION GUARD — READ BEFORE TOUCHING (ref #52 #54 #57 #375 #376)
// navigate() = rootView swap ONLY. sizingOptions=.preferredContentSize drives sizing.
// idealWidth:420 pins preferredContentSize.width -> no horizontal jump on navigate().
// ScrollView absorbs overflow — NEVER fight the frame.
// ❌ NEVER put header inside ScrollView
// ❌ NEVER add .frame(height:) to root
// ❌ NEVER remove idealWidth:420 — without it preferredContentSize.width is unbounded
//    and NSPopover jumps sideways on every navigate() call.
// ❌ NEVER remove .maxHeight:.infinity from root — detail views must fill existing frame.
// ❌ NEVER remove .fixedSize(horizontal:false,vertical:true) from ScrollView VStack
// ❌ NEVER call navigate() directly — use onBack/onSelectStep callbacks
// ❌ NEVER call layoutSubtreeIfNeeded() anywhere — causes sideways jump

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
        VStack(alignment: .leading, spacing: 0) {
            // ── Header: OUTSIDE ScrollView — always visible at top
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
                            log("ReRunButton › could not derive scope from htmlUrl: \(job.htmlUrl ?? "nil")")
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
                            log("CancelButton › could not derive scope/runID from htmlUrl: \(job.htmlUrl ?? "nil")")
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

            Text(job.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            Divider()

            // ── Steps list: INSIDE ScrollView
            // ⚠️ .fixedSize(horizontal:false,vertical:true) on the VStack is LOAD-BEARING.
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
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // ⚠️ idealWidth:420 is REQUIRED — pins preferredContentSize.width so NSPopover
        // does not jump sideways when navigate() swaps this view in. Must match
        // AppDelegate.fixedWidth and PopoverMainView's idealWidth.
        .frame(idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    /// Returns job.elapsed, re-evaluated every tick so the header updates live.
    private func elapsedLive(tick _: Int) -> String { job.elapsed }

    /// Color-codes the step icon based on conclusion/status.
    private func stepColor(_ step: JobStep) -> Color {
        switch step.conclusion {
        case "success": return .green
        case "failure": return .red
        default: return step.status == "in_progress" ? .yellow : .secondary
        }
    }
}
