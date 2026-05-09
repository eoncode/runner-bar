import AppKit
import SwiftUI
// swiftlint:disable identifier_name vertical_whitespace_opening_braces superfluous_disable_command

// ═══════════════════════════════════════════════════════════════════════════════
// ⚠️ REGRESSION GUARD — mirrors JobDetailView frame/layout contract
// ═══════════════════════════════════════════════════════════════════════════════
//
// ── FRAME CONTRACT ───────────────────────────────────────────────────────────────
//   Root MUST use .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
//   Height is set by AppDelegate.navigate(to:fixedHeight:) — never by this view.
//   ScrollView absorbs overflow — do NOT fight the frame.
//   ❌ NEVER add .frame(height:) or .frame(maxHeight:) to root
//   ❌ NEVER add .fixedSize() to root or ScrollView
//   ❌ NEVER add maxHeight cap to ScrollView — causes side-jump regression
//
// ── LAYOUT RULES ─────────────────────────────────────────────────────────────────
//   ✔ Header (back button + title + Divider) MUST be OUTSIDE ScrollView
//   ✔ Job list MUST be inside ScrollView
//   ❌ NEVER put header inside ScrollView
//   ❌ NEVER call navigate() directly — use onBack / onSelectJob callbacks
//
// ── HEIGHT SIZING ────────────────────────────────────────────────────────────────
//   Height is controlled by PopoverSize.actionDetailHeight() in AppDelegate.
//   That function sizes based on group.jobs.count so the popover fits content.
//   Do NOT replicate height logic here.
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
    /// Held so we can invalidate on disappear and prevent timer accumulation.
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
                    .fixedSize()
                }
                .buttonStyle(.plain)
                Spacer()  // ⚠️ load-bearing — pushes elapsed to right edge
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
                            })
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // ⚠️ maxWidth + maxHeight BOTH required. Height is set by AppDelegate via
        // navigate(to:fixedHeight:) using PopoverSize.actionDetailHeight(for:).
        // Width: .infinity fills the fixed 420pt popover — removing it causes side-jump.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    // MARK: - Job row helpers

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
