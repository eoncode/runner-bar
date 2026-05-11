import AppKit
import SwiftUI

// ⚠️ REGRESSION GUARD — Architecture 1 (ref #49 #51 #52 #53 #54 #57 #321 #370 #375 #376 #377)
//
// sizingOptions = .preferredContentSize + .frame(idealWidth:420) on root drives ALL sizing.
//
// ROOT FRAME RULE:
//   .frame(idealWidth: 420) ONLY. No height constraints.
//   preferredContentSize.width = 420 always — stable width — no re-anchor — no jump.
//   Height = natural content height of header + steps list.
//
// ❌ NEVER add minHeight/idealHeight/maxHeight to the root frame.
// ❌ NEVER use .frame(width: 420) — must be idealWidth.
// ❌ NEVER use .fixedSize on the inner ScrollView content.
// ❌ NEVER remove idealWidth:420.
//
// TICK TIMER RULE:
//   tick fires every 1s — triggers SwiftUI re-render — updates elapsed label.
//   With dynamic height, each re-render re-reports preferredContentSize.height.
//   Timer must ONLY run while the view is the active nav state (controlled by caller).
//   It is started in .onAppear and stopped in .onDisappear.
//   This is safe because navigate() swaps rootView immediately — onDisappear fires
//   synchronously before the new view appears — no timer fires after navigate().
// ❌ NEVER run the timer while a child view (StepLogView) is shown over this view.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.

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
            // ⚠️ NO .fixedSize inside this ScrollView — kills dynamic height.
            // ScrollView clips and scrolls content that exceeds available height.
            // preferredContentSize.height = header height + this ScrollView's natural height.
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
            // ⚠️ Cap ScrollView height so detail view doesn’t grow off-screen.
            // 75% of screen height is the same cap used by SettingsView.
            // preferredContentSize.height = header + min(steps content, cappedScrollHeight).
            // ❌ NEVER remove this — unbounded ScrollView ideal height → spike → jump.
            .frame(maxHeight: (NSScreen.main?.visibleFrame.height ?? 800) * 0.75)
        }
        // ⚠️ REGRESSION GUARD: idealWidth:420 ONLY — no height constraints.
        // Width is stable at 420 always. Height is natural content height.
        // ❌ NEVER add minHeight/idealHeight/maxHeight here.
        // ❌ NEVER use .frame(width:420) — must be idealWidth.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
        // is major major major.
        .frame(idealWidth: 420)
        .onAppear {
            tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                tick += 1
            }
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
