import AppKit
import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════════
// ⚠️ REGRESSION GUARD — mirrors JobDetailView frame/layout contract
// ═══════════════════════════════════════════════════════════════════════════════
//
// ── FRAME CONTRACT ────────────────────────────────────────────────────────────
//   Receives the same FIXED frame from AppDelegate as JobDetailView.
//   Sized once at openPopover() from mainView()'s fittingSize; never changes.
//   ScrollView absorbs overflow — do NOT fight the frame.
//
// ── LAYOUT RULES ──────────────────────────────────────────────────────────────
//   ✔ Root: .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
//   ✔ Job list MUST be inside ScrollView
//   ✔ Header (back button + title + Divider) MUST be OUTSIDE ScrollView
//   ❌ NEVER put header inside ScrollView
//   ❌ NEVER add .idealWidth or .frame(height:) to root
//   ❌ NEVER call navigate() directly — use onBack / onSelectJob callbacks
// ═══════════════════════════════════════════════════════════════════════════════

/// Navigation level 2a (Actions path): shows the flat job list for a commit/PR group.
///
/// Drill-down chain:
///   PopoverMainView (action row tap)
///   → ActionDetailView            ← this view
///   → JobDetailView (step list)   ← existing, unchanged
///   → StepLogView (log)           ← existing, unchanged
struct ActionDetailView: View {
    let group: ActionGroup
    let onBack: () -> Void
    /// Called when user taps a job row. AppDelegate wires this to detailViewFromAction(job:group:).
    let onSelectJob: (ActiveJob) -> Void

    /// Drives the live elapsed timer every second.
    @State private var tick = 0
    /// Held so we can invalidate on disappear and prevent timer accumulation
    /// when the user navigates away and back (AppDelegate swaps rootView each time).
    @State private var tickTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header: OUTSIDE ScrollView — always visible at top
            HStack(spacing: 6) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.caption)
                        Text("Actions").font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()  // ⚠️ load-bearing — pushes elapsed to right edge
                ReRunButton(
                    action: { completion in
                        let scope = group.repo
                        let runIDs = group.runs.map { $0.id }
                        DispatchQueue.global(qos: .userInitiated).async {
                            let isSuccess = runIDs.allSatisfy { runID in
                                ghPost("repos/\(scope)/actions/runs/\(runID)/rerun-failed-jobs")
                            }
                            completion(isSuccess)
                        }
                    },
                    isDisabled: group.groupStatus == .inProgress
                )
                CancelButton(
                    action: { completion in
                        let scope = group.repo
                        let runIDs = group.runs.map { $0.id }
                        DispatchQueue.global(qos: .userInitiated).async {
                            let isSuccess = runIDs.allSatisfy { runID in
                                cancelRun(runID: runID, scope: scope)
                            }
                            completion(isSuccess)
                        }
                    },
                    isDisabled: group.groupStatus != .inProgress
                )
                LogCopyButton(
                    fetch: { completion in
                        let currentGroup = group
                        DispatchQueue.global(qos: .userInitiated).async {
                            completion(fetchActionLogs(group: currentGroup))
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

            // Label + title below nav bar.
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
                // Job progress summary
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
                            Button(action: { onSelectJob(job) }) {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(jobDotColor(for: job))
                                        .frame(width: 7, height: 7)
                                    Text(job.name)
                                        .font(.system(size: 12))
                                        .foregroundColor(job.isDimmed ? .secondary : .primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer()  // ⚠️ load-bearing
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
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            // Invalidate any existing timer before creating a new one — prevents
            // accumulation when the user navigates away and back multiple times.
            tickTimer?.invalidate()
            tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick += 1 }
        }
        .onDisappear {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    // Re-evaluates group.elapsed on every tick to drive a live counter.
    private func elapsedLive(tick _: Int) -> String { group.elapsed }

    // MARK: - Job row helpers

    private func jobDotColor(for job: ActiveJob) -> Color {
        if job.isDimmed { return .secondary }
        return job.status == "in_progress" ? .yellow : .gray
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

    private func conclusionLabel(_ conclusion: String) -> String {
        switch conclusion {
        case "success":   return "✓ success"
        case "failure":   return "✗ failure"
        case "cancelled": return "⊗ cancelled"
        case "skipped":   return "− skipped"
        default:          return conclusion
        }
    }

    private func conclusionColor(_ conclusion: String) -> Color {
        switch conclusion {
        case "success": return .green
        case "failure": return .red
        default:        return .secondary
        }
    }
}
