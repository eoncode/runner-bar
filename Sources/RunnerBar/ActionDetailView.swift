import AppKit
import SwiftUI
// swiftlint:disable identifier_name vertical_whitespace_opening_braces superfluous_disable_command

// ═══════════════════════════════════════════════════════════════════════════════
// ⚠️ REGRESSION GUARD
// ═══════════════════════════════════════════════════════════════════════════════
//
// Height is driven by AppDelegate.openPopover() fittingSize — read once per open.
// This view must NOT use maxHeight:.infinity — that stretches it to the main
// view's pre-existing frame. Use maxWidth:.infinity only.
// Header is OUTSIDE ScrollView. Job list is INSIDE ScrollView.
// ❌ NEVER add maxHeight:.infinity to the root frame — causes inherited height bug.
// ❌ NEVER call navigate() directly — use onBack / onSelectJob callbacks.
// ═══════════════════════════════════════════════════════════════════════════════

struct ActionDetailView: View {
    let group: ActionGroup
    let onBack: () -> Void
    let onSelectJob: (ActiveJob) -> Void

    @State private var tick = 0
    @State private var tickTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header: OUTSIDE ScrollView
            HStack(spacing: 6) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.caption)
                        Text("Actions").font(.caption)
                    }
                    .foregroundColor(.secondary)
                    .fixedSize()
                }
                .buttonStyle(.plain)
                Spacer()
                ReRunButton(
                    action: { completion in
                        let scope = group.repo
                        let runIDs = group.runs.map { $0.id }
                        DispatchQueue.global(qos: .userInitiated).async {
                            let ok = runIDs.allSatisfy { runID in
                                ghPost("repos/\(scope)/actions/runs/\(runID)/rerun-failed-jobs")
                            }
                            completion(ok)
                        }
                    },
                    isDisabled: group.groupStatus == .inProgress
                )
                CancelButton(
                    action: { completion in
                        let scope = group.repo
                        let runIDs = group.runs.map { $0.id }
                        DispatchQueue.global(qos: .userInitiated).async {
                            let ok = runIDs.allSatisfy { runID in
                                cancelRun(runID: runID, scope: scope)
                            }
                            completion(ok)
                        }
                    },
                    isDisabled: group.groupStatus != .inProgress
                )
                LogCopyButton(
                    fetch: { completion in
                        let g = group
                        DispatchQueue.global(qos: .userInitiated).async {
                            completion(fetchActionLogs(group: g))
                        }
                    },
                    isDisabled: false
                )
                Text(elapsedLive(tick: tick))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.label)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                    Text(group.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let branch = group.headBranch {
                    Text(branch)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("\(group.jobsDone)/\(group.jobsTotal) jobs concluded")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            // ── Jobs list: INSIDE ScrollView
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    if group.jobs.isEmpty {
                        Text("No jobs available")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(group.jobs) { job in
                            Button(action: { onSelectJob(job) }, label: {
                                HStack(spacing: 8) {
                                    PieProgressView(
                                        progress: job.progressFraction,
                                        color: jobDotColor(for: job),
                                        size: 7
                                    )
                                    Text(job.name)
                                        .font(.system(size: 12))
                                        .foregroundColor(job.isDimmed ? .secondary : .primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer()
                                    if let conclusion = job.conclusion {
                                        Text(conclusionLabel(conclusion))
                                            .font(.caption)
                                            .foregroundColor(conclusionColor(conclusion))
                                            .frame(width: 76, alignment: .trailing)
                                    } else {
                                        Text(jobStatusLabel(for: job))
                                            .font(.caption)
                                            .foregroundColor(jobStatusColor(for: job))
                                            .frame(width: 76, alignment: .trailing)
                                    }
                                    Text(job.elapsed)
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
        // ⚠️ maxWidth:.infinity only. NO maxHeight:.infinity — that inherits main view's
        // frame height instead of sizing to this view's own content via fittingSize.
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear {
            tickTimer?.invalidate()
            tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick += 1 }
        }
        .onDisappear {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    private func elapsedLive(tick _: Int) -> String { group.elapsed }

    private func jobDotColor(for job: ActiveJob) -> Color {
        switch job.status {
        case "in_progress": return .yellow
        case "queued":      return .blue
        default:
            if job.isDimmed { return .gray }
            return job.conclusion == "success" ? .green : .red
        }
    }

    private func jobStatusLabel(for job: ActiveJob) -> String {
        switch job.status {
        case "in_progress": return "In Progress"
        case "queued":      return "Queued"
        default:            return "Pending"
        }
    }

    private func jobStatusColor(for job: ActiveJob) -> Color {
        job.status == "in_progress" ? .yellow : .secondary
    }

    private func conclusionLabel(_ c: String) -> String {
        switch c {
        case "success":   return "✓ success"
        case "failure":   return "✗ failure"
        case "cancelled": return "⊗ cancelled"
        case "skipped":   return "− skipped"
        default:          return c
        }
    }

    private func conclusionColor(_ c: String) -> Color {
        switch c {
        case "success": return .green
        case "failure": return .red
        default:        return .secondary
        }
    }
}
// swiftlint:enable identifier_name vertical_whitespace_opening_braces superfluous_disable_command
