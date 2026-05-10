import AppKit
import SwiftUI
// swiftlint:disable identifier_name vertical_whitespace_opening_braces superfluous_disable_command

// ═══════════════════════════════════════════════════════════════════════════════
// ⚠️ REGRESSION GUARD — mirrors JobDetailView frame/layout contract
// ═══════════════════════════════════════════════════════════════════════════════
//
// ── FRAME CONTRACT ────────────────────────────────────────────────────────────────────────
//   Root: .frame(idealWidth: 420, maxWidth: .infinity, alignment: .top)
//   idealWidth MUST match AppDelegate.fixedWidth (420).
//   maxHeight:.infinity is BANNED — it corrupts fittingSize and causes side-jump on navigate().
//   ScrollView absorbs overflow — do NOT fight the frame.
//
// ── LAYOUT RULES ────────────────────────────────────────────────────────────────────────
//   ✔ Root: .frame(idealWidth: 420, maxWidth: .infinity, alignment: .top)
//   ✔ Job list MUST be inside ScrollView
//   ✔ Header (back button + title + Divider) MUST be OUTSIDE ScrollView
//   ❌ NEVER put header inside ScrollView
//   ❌ NEVER add maxHeight:.infinity or .frame(height:) to root
//   ❌ NEVER add .fixedSize(horizontal:false,vertical:true) to multi-line title texts in header
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
                    // ⚠️ lineLimit(2) + NO fixedSize(horizontal:false,vertical:true).
                    // fixedSize(h:false,v:true) is BANNED on title texts — it lets the label grow
                    // vertically and corrupts fittingSize.height (ref #52 #54 #57).
                    Text(group.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.tail)
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
                            })
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // ⚠️ REGRESSION GUARD: idealWidth:420 MUST match AppDelegate.fixedWidth.
        // maxHeight:.infinity is BANNED here — it corrupts fittingSize and causes side-jump on navigate() (ref #52 #54 #57).
        .frame(idealWidth: 420, maxWidth: .infinity, alignment: .top)
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

    private func conclusionLabel(_ c: String) -> String {
        switch c {
        case "success":   return "\u{2713} success"
        case "failure":   return "\u{2717} failure"
        case "cancelled": return "\u{2297} cancelled"
        case "skipped":   return "\u{2212} skipped"
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
