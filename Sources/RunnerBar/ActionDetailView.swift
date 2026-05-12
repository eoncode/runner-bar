import AppKit
import SwiftUI
// swiftlint:disable identifier_name vertical_whitespace_opening_braces superfluous_disable_command

// ════════════════════════════════════════════════════════════════════════════════
// ⚠️⚠️⚠️  NSPANEL SIZING GUARD — READ BEFORE ANY EDIT  ⚠️⚠️⚠️
// ════════════════════════════════════════════════════════════════════════════════
//
// ARCHITECTURE: NSPanel (NOT NSPopover).
// NSPanel has no anchor — setFrame() never causes a side-jump.
// Width IS dynamic: AppDelegate KVO-observes preferredContentSize and calls
// NSPanel.setFrame(), repositioning under the status button each time.
//
// ROOT FRAME RULE:
//   .frame(idealWidth: 560, maxWidth: .infinity, alignment: .top)
//   • idealWidth: 560 — MUST match AppDelegate.initPanelWidth (currently 560).
//   • maxWidth: .infinity — fills the panel width.
//   • NO idealHeight / maxHeight on the root frame.
//
// SCROLLVIEW HEIGHT CAP — REQUIRED:
//   .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
//   Prevents the panel growing taller than the screen.
//   ❌ NEVER remove this modifier from the ScrollView.
//   ❌ NEVER use a fixed constant — must adapt to screen size.
//
// ════════════════════════════════════════════════════════════════════════════════
// HISTORY:
//   Widened from 480 → 560 to accommodate start/end time columns (NSPanel).
//   Job rows collapsed to single line: [#N][dot][name][time range]...[status][elapsed][›]
//   Time range format changed to HH:mm:ss→HH:mm:ss (column width 96 → 130).
//   Side-jump is impossible with NSPanel — no anchor to re-calculate.
//   Added #N order index badge to each job row (1-based, start order).
// ════════════════════════════════════════════════════════════════════════════════

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
    /// Called when user taps a job row. AppDelegate wires this to detailViewFromAction(job:group:).\
    let onSelectJob: (ActiveJob) -> Void

    /// Drives the live elapsed timer every second.
    @State private var tick = 0
    /// Held so we can invalidate on disappear and prevent timer accumulation.
    @State private var tickTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ────────────────────────────────────────────────────────────
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

            // ── Group title block ─────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.label)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
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

            // ── Jobs list ────────────────────────────────────────────────────────
            // ❌ NEVER remove .frame(maxHeight:) from this ScrollView.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    if group.jobs.isEmpty {
                        Text("No jobs available")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    } else {
                        // Use enumerated() so each row can display its 1-based start order index.
                        // The index reflects the order jobs appear in group.jobs (sorted by
                        // startedAt/createdAt upstream), so #1 = first job started, #N = last.
                        ForEach(Array(group.jobs.enumerated()), id: \.element.id) { index, job in
                            Button(action: { onSelectJob(job) }, label: {
                                jobRow(job, index: index + 1)
                            })
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
        }
        .frame(idealWidth: 560, maxWidth: .infinity, alignment: .top)
        .onAppear {
            tickTimer?.invalidate()
            tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick += 1 }
        }
        .onDisappear {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    // MARK: - Job row

    /// Single-line job row:
    /// [#N] [dot] [name — truncates last] [time range — fixed width] ... [status] [elapsed] [›]
    ///
    /// Column widths (right side, fixed so columns stay aligned):
    ///   index      : 28pt  ("#10" = 3 chars monospaced, left-aligned)
    ///   time range : 130pt  ("HH:mm:ss→HH:mm:ss" = 19 chars monospaced)
    ///   status     : 80pt
    ///   elapsed    : 40pt
    ///   chevron    : intrinsic
    @ViewBuilder
    private func jobRow(_ job: ActiveJob, index: Int) -> some View {
        HStack(spacing: 8) {
            // Order index badge: #1, #2 … #10 etc.
            // Fixed width so all job names left-align regardless of digit count.
            Text("#\(index)")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 28, alignment: .leading)

            Circle()
                .fill(jobDotColor(for: job))
                .frame(width: 7, height: 7)

            // Name: flex, truncates when row is tight
            Text(job.name)
                .font(.system(size: 12))
                .foregroundColor(job.isDimmed ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            // Time range: fixed width, always visible
            // Format: HH:mm:ss→HH:mm:ss  |  HH:mm:ss→now  |  –
            Text(jobTimeRange(job))
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: 130, alignment: .leading)

            Spacer(minLength: 0)

            // Status / conclusion: fixed width, right-aligned
            if let conclusion = job.conclusion {
                Text(conclusionLabel(conclusion))
                    .font(.caption)
                    .foregroundColor(conclusionColor(conclusion))
                    .frame(width: 80, alignment: .trailing)
            } else {
                Text(jobStatusLabel(for: job))
                    .font(.caption)
                    .foregroundColor(jobStatusColor(for: job))
                    .frame(width: 80, alignment: .trailing)
            }

            // Elapsed: fixed width
            Text(job.elapsed)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .trailing)

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    // MARK: - Helpers

    private func elapsedLive(tick _: Int) -> String { group.elapsed }

    /// Formats the start → end time range with seconds.
    /// queued (no timestamps): "–"
    /// in_progress:            "HH:mm:ss→now"
    /// completed:              "HH:mm:ss→HH:mm:ss"
    private func jobTimeRange(_ job: ActiveJob) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        guard let start = job.startedAt ?? job.createdAt else { return "–" }
        let startStr = fmt.string(from: start)
        if let end = job.completedAt {
            return "\(startStr)→\(fmt.string(from: end))"
        }
        if job.status == "queued" { return "–" }
        return "\(startStr)→now"
    }

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
