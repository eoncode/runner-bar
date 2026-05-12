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
//   Replaced generic "X/N jobs concluded" with context-aware outcome label:
//     in progress → "X/N jobs running"
//     all success  → "X/N jobs succeeded"
//     any failure  → "X/N jobs failed"
//     any cancel   → "X/N jobs cancelled"
//     otherwise    → "X/N jobs completed"
//   Elapsed moved from header to timing row below branch label.
//   SHA/PR label made tappable: opens commit or PR on GitHub.
//   Time-range and elapsed columns hidden for queued jobs (no startedAt).
//   Previously these showed "–" which carried no meaning — now suppressed.
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
    /// Called when user taps a job row. AppDelegate wires this to detailViewFromAction(job:group:).
    let onSelectJob: (ActiveJob) -> Void

    /// Drives the live elapsed timer every second.
    @State private var tick = 0
    /// Held so we can invalidate on disappear and prevent timer accumulation.
    @State private var tickTimer: Timer?

    // MARK: - Formatters

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ──────────────────────────────────────────────────────────────
            // Elapsed has been moved to the timing row below the branch label.
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
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            // ── Group title block ───────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // SHA / PR label: tappable, opens commit or PR on GitHub.
                    // PR labels start with "#"; everything else is a short sha.
                    Button(action: openLabelOnGitHub) {
                        Text(group.label)
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(labelLinkTooltip)

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
                // Timing row: start → end · elapsed
                // Shows start time of first job and end time of last job (or "now" if running).
                // Elapsed ticks every second via `tick`.
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text(groupStartLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                        .fixedSize()
                    Text("→")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(groupEndLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                        .fixedSize()
                    Text("·")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(elapsedLive(tick: tick))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                        .fixedSize()
                }
                Text(jobsSummaryLine)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            // ── Jobs list ──────────────────────────────────────────────────────────
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

    // MARK: - GitHub link helpers

    /// Opens the commit or PR on GitHub.
    /// PR labels start with "#" (e.g. "#1270") — those link to the PR page.
    /// Everything else is a short sha — links to the commit page.
    private func openLabelOnGitHub() {
        let urlString: String
        if group.label.hasPrefix("#"),
           let number = Int(group.label.dropFirst()) {
            urlString = "https://github.com/\(group.repo)/pull/\(number)"
        } else {
            // Use the full headSha for the commit link so GitHub resolves it correctly.
            urlString = "https://github.com/\(group.repo)/commit/\(group.headSha)"
        }
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Tooltip for the label button.
    private var labelLinkTooltip: String {
        group.label.hasPrefix("#")
            ? "Open pull request on GitHub"
            : "Open commit on GitHub"
    }

    // MARK: - Timing row helpers

    private var groupStartLabel: String {
        guard let d = group.firstJobStartedAt ?? group.createdAt else { return "—" }
        return Self.timeFmt.string(from: d)
    }

    private var groupEndLabel: String {
        if let d = group.lastJobCompletedAt { return Self.timeFmt.string(from: d) }
        if group.groupStatus == .inProgress { return "now" }
        return "—"
    }

    // MARK: - Job summary line

    /// Context-aware summary shown below the group title.
    ///
    /// Priority order (first match wins):
    ///   1. Any job still running/queued  → "X/N jobs running"
    ///   2. Any job failed                → "X/N jobs failed"
    ///   3. Any job cancelled             → "X/N jobs cancelled"
    ///   4. All jobs succeeded            → "X/N jobs succeeded"
    ///   5. Otherwise                     → "X/N jobs completed"
    ///
    /// Note: jobsDone counts jobs that have a conclusion (completed field set).
    /// jobsTotal is the total job count for this group.
    private var jobsSummaryLine: String {
        let done  = group.jobsDone
        let total = group.jobsTotal
        let conclusions = group.jobs.compactMap { $0.conclusion }

        // Still running: at least one job has no conclusion yet
        if group.groupStatus == .inProgress || conclusions.count < total {
            return "\(done)/\(total) jobs running"
        }
        // Any failure takes priority over everything else
        if conclusions.contains("failure") {
            return "\(done)/\(total) jobs failed"
        }
        // Any cancellation
        if conclusions.contains("cancelled") {
            return "\(done)/\(total) jobs cancelled"
        }
        // All succeeded (skipped counts as a passing outcome here)
        if conclusions.allSatisfy({ $0 == "success" || $0 == "skipped" }) {
            return "\(done)/\(total) jobs succeeded"
        }
        // Catch-all for mixed/unknown conclusions
        return "\(done)/\(total) jobs completed"
    }

    // MARK: - Job row

    /// Single-line job row:
    /// [#N] [dot] [name — truncates last] [time range — fixed width] ... [status] [elapsed] [›]
    ///
    /// Column widths (right side, fixed so columns stay aligned):
    ///   index      : 28pt  ("#10" = 3 chars monospaced, left-aligned)
    ///   time range : 130pt  ("HH:mm:ss→HH:mm:ss" = 19 chars monospaced)
    ///                shown only when job has started — hidden for queued jobs
    ///   status     : 80pt
    ///   elapsed    : 40pt  shown only when job has started
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

            // Time range: only shown when the job has actually started.
            // Queued jobs have no startedAt — suppress entirely rather than
            // showing a meaningless "–" placeholder.
            if job.startedAt != nil {
                Text(jobTimeRange(job))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)
            } else {
                // Reserve the same space so right-side columns stay aligned.
                Spacer()
                    .frame(width: 130)
            }

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

            // Elapsed: only shown when the job has started.
            // Queued jobs have no duration yet — suppress rather than showing "–".
            if job.startedAt != nil {
                Text(job.elapsed)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .trailing)
            } else {
                Spacer().frame(width: 40)
            }

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
    /// Only called when job.startedAt is non-nil.
    /// in_progress:  "HH:mm:ss→now"
    /// completed:    "HH:mm:ss→HH:mm:ss"
    private func jobTimeRange(_ job: ActiveJob) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        guard let start = job.startedAt ?? job.createdAt else { return "" }
        let startStr = fmt.string(from: start)
        if let end = job.completedAt {
            return "\(startStr)→\(fmt.string(from: end))"
        }
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
