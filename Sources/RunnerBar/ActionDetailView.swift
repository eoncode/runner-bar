import AppKit
import SwiftUI
// swiftlint:disable identifier_name
// ════════════════════════════════════════════════════════════════════════════════
// ⚠️⚠️⚠️ NSPANEL SIZING GUARD — READ BEFORE ANY EDIT ⚠️⚠️⚠️
// ════════════════════════════════════════════════════════════════════════════════
//
// ARCHITECTURE: NSPanel (NOT NSPopover).
// Width is dynamic — set by NSPanel.setFrame(), repositioning under the status button each time.
//
// ROOT FRAME RULE:
// .frame(minWidth: 560, maxWidth: .infinity, alignment: .top)
// • minWidth: 560 — minimum panel width; content decides actual width.
// • maxWidth: .infinity — fills the panel width up to AppDelegate.maxWidth.
// • NO idealWidth — width is content-driven, not pinned to a fixed value.
// • NO idealHeight / maxHeight on the root frame.
//
// SCROLLVIEW HEIGHT CAP — REQUIRED:
// .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
// Prevents the panel growing taller than the screen.
// ❌ NEVER remove this modifier from the ScrollView.
// ❌ NEVER use a fixed constant — must adapt to screen size.
//
// ════════════════════════════════════════════════════════════════════════════════
// HISTORY:
// Widened from 480 → 560 to accommodate start/end time columns (NSPanel).
// Job rows collapsed to single line: [#N][dot][name][time range]...[status][elapsed][›]
// Time range format changed to HH:mm:ss→HH:mm:ss (column width 96 → 130).
// Side-jump is impossible with NSPanel — no anchor to re-calculate.
// Added #N order index badge to each job row (1-based display order).
// Replaced generic "X/N jobs concluded" with context-aware outcome label.
// Elapsed moved from header to timing row below branch label.
// SHA/PR label made tappable: opens commit or PR on GitHub.
// Time-range and elapsed columns hidden for queued jobs (no startedAt).
// Switched from idealWidth (fixed) to minWidth (content-driven) width model.
// Phase 5: DesignToken colour sweep — all hardcoded .yellow/.green/.red replaced
//          with Color.rbWarning / rbSuccess / rbDanger; job rows card-styled.
// Review item 3: job rows now use .cardRow() modifier for consistency.
// Review item 4: headBranch label replaced with BranchTagPill.
// ════════════════════════════════════════════════════════════════════════════════

/// Navigation level 2a (Actions path): shows the flat job list for a commit/PR group.
///
/// Drill-down chain:
/// PopoverMainView (action row tap)
///   -> ActionDetailView <- this view
///   -> JobDetailView (step list) <- existing, unchanged
///   -> StepLogView (log) <- existing, unchanged
struct ActionDetailView: View {
    let group: ActionGroup
    let onBack: () -> Void
    let onSelectJob: (ActiveJob) -> Void

    @State private var tick: Int = 0
    @State private var tickTimer: Timer?

    // MARK: - Formatters
    /// HH:mm formatter — used for group start/end labels in the header.
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    /// HH:mm:ss formatter — used for per-job time-range column.
    /// Static so it is created once and reused on every 1 Hz tick x N job rows.
    private static let jobTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Root layout: back button bar, group title block, divider, scrollable jobs list.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ───────────────────────────────────────────────────────────────────────────────────
            HStack(spacing: 6) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.caption)
                        Text("Actions").font(.caption)
                    }
                    .foregroundColor(Color.rbTextSecondary)
                    .fixedSize()
                }
                .buttonStyle(.plain)
                Spacer()
                ReRunButton(
                    action: { completion in
                        let scope = group.repo
                        if scope.isEmpty {
                            completion(false)
                            return
                        }
                        DispatchQueue.global(qos: .userInitiated).async {
                            let ok = ghPost("repos/\(scope)/actions/runs/\(group.runID)/rerun")
                            DispatchQueue.main.async { completion(ok) }
                        }
                    },
                    isDisabled: group.groupStatus == .inProgress || group.groupStatus == .queued
                )
                ReRunFailedButton(
                    action: { completion in
                        let scope = group.repo
                        if scope.isEmpty { completion(false); return }
                        DispatchQueue.global(qos: .userInitiated).async {
                            let ok = ghPost("repos/\(scope)/actions/runs/\(group.runID)/rerun-failed-jobs")
                            DispatchQueue.main.async { completion(ok) }
                        }
                    },
                    isDisabled: group.groupStatus == .inProgress || group.groupStatus == .queued
                )
                CancelButton(
                    action: { completion in
                        let scope = group.repo
                        if scope.isEmpty { completion(false); return }
                        DispatchQueue.global(qos: .userInitiated).async {
                            let ok = cancelRun(runID: group.runID, scope: scope)
                            DispatchQueue.main.async { completion(ok) }
                        }
                    },
                    isDisabled: false
                )
            }
            .padding(.horizontal, RBSpacing.md)
            .padding(.top, 10)
            .padding(.bottom, 4)

            // ── Group title block ────────────────────────────────────────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Button(action: openLabelOnGitHub) {
                        Text(group.label)
                            .font(.caption.monospacedDigit())
                            .foregroundColor(Color.rbTextSecondary)
                    }
                    .buttonStyle(.plain)
                    .help(labelLinkTooltip)
                    Text(group.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                if let branch = group.headBranch {
                    BranchTagPill(name: branch)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                        .foregroundColor(Color.rbTextSecondary)
                    Text(groupStartLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(Color.rbTextSecondary)
                        .fixedSize()
                    Text("→").font(.caption2).foregroundColor(Color.rbTextSecondary)
                    Text(groupEndLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(Color.rbTextSecondary)
                        .fixedSize()
                    Text("·").font(.caption2).foregroundColor(Color.rbTextSecondary)
                    Text(elapsedLive(tick: tick))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(Color.rbTextSecondary)
                        .fixedSize()
                }
                Text(jobsSummaryLine).font(.caption).foregroundColor(Color.rbTextSecondary)
            }
            .padding(.horizontal, RBSpacing.md)
            .padding(.bottom, 8)

            Divider()

            // ── Jobs list ──────────────────────────────────────────────────────────────────────────────────────
            // ❌ NEVER remove .frame(maxHeight:) from this ScrollView.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: RBSpacing.xxs) {
                    if group.jobs.isEmpty {
                        Text("No jobs available")
                            .font(.caption).foregroundColor(Color.rbTextSecondary)
                            .padding(.horizontal, RBSpacing.md).padding(.vertical, 8)
                    } else {
                        ForEach(Array(group.jobs.enumerated()), id: \.element.id) { index, job in
                            Button(action: { onSelectJob(job) }, label: { jobRow(job, index: index + 1) })
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, RBSpacing.md)
                .padding(.vertical, RBSpacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
        }
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
}
// swiftlint:enable identifier_name

/// Helper methods for `ActionDetailView`: GitHub navigation, computed labels, and row builders.
extension ActionDetailView {
    /// Opens the SHA commit or PR associated with the group label on GitHub.
    func openLabelOnGitHub() {
        let urlString: String
        if group.label.hasPrefix("#"), let number = Int(group.label.dropFirst()) {
            urlString = "https://github.com/\(group.repo)/pull/\(number)"
        } else {
            urlString = "https://github.com/\(group.repo)/commit/\(group.headSha)"
        }
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Tooltip text for the label link button.
    var labelLinkTooltip: String {
        group.label.hasPrefix("#") ? "Open pull request on GitHub" : "Open commit on GitHub"
    }

    /// Formatted start time for the group.
    var groupStartLabel: String {
        guard let date = group.firstJobStartedAt ?? group.createdAt else { return "—" }
        return Self.timeFmt.string(from: date)
    }

    /// Formatted end time for the group.
    var groupEndLabel: String {
        guard let date = group.updatedAt else { return "—" }
        return Self.timeFmt.string(from: date)
    }

    /// Human-readable summary of job completion state for the group.
    var jobsSummaryLine: String {
        let done = group.jobsDone
        let total = group.jobsTotal
        let conclusions = group.jobs.compactMap { $0.conclusion }
        if group.groupStatus == .inProgress || conclusions.count < total { return "\(done)/\(total) jobs running" }
        let failed = conclusions.filter { $0 == "failure" }.count
        let cancelled = conclusions.filter { $0 == "cancelled" }.count
        if failed > 0 { return "\(failed) failed · \(done)/\(total) jobs" }
        if cancelled > 0 { return "\(cancelled) cancelled · \(done)/\(total) jobs" }
        return "\(done)/\(total) jobs completed"
    }

    /// Returns the group elapsed string; `tick` triggers SwiftUI refresh every second.
    func elapsedLive(tick _: Int) -> String { group.elapsed }

    /// Job row view builder — renders a single-line card for a job inside the list.
    @ViewBuilder
    func jobRow(_ job: ActiveJob, index: Int) -> some View {
        HStack(spacing: 8) {
            Text("#\(index)")
                .font(.caption2.monospacedDigit()).foregroundColor(Color.rbTextTertiary)
                .frame(width: 28, alignment: .leading)
            Circle().fill(jobDotColor(for: job)).frame(width: 7, height: 7)
            Text(job.name)
                .font(RBFont.body)
                .foregroundColor(job.isDimmed ? Color.rbTextSecondary : Color.rbTextPrimary)
                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
            if job.startedAt != nil {
                Text(jobTimeRange(job))
                    .font(.caption2.monospacedDigit()).foregroundColor(Color.rbTextSecondary)
                    .lineLimit(1).frame(width: 130, alignment: .leading)
            } else {
                Spacer().frame(width: 130)
            }
            Spacer()
            if let conclusion = job.conclusion {
                Text(conclusionLabel(conclusion))
                    .font(.caption2)
                    .foregroundColor(conclusionColor(conclusion))
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Text(jobStatusLabel(for: job))
                    .font(.caption2)
                    .foregroundColor(jobStatusColor(for: job))
                    .lineLimit(1)
                    .fixedSize()
            }
            if job.startedAt != nil {
                Text(job.elapsed)
                    .font(.caption.monospacedDigit()).foregroundColor(Color.rbTextSecondary)
                    .frame(width: 40, alignment: .trailing)
            } else {
                Spacer().frame(width: 40)
            }
            Image(systemName: "chevron.right").font(.caption2).foregroundColor(Color.rbTextTertiary)
        }
        .padding(.horizontal, RBSpacing.sm)
        .padding(.vertical, 5)
        .cardRow(cornerRadius: RBRadius.small)
        .contentShape(Rectangle())
    }

    /// Formats start->end time range for a job row.
    func jobTimeRange(_ job: ActiveJob) -> String {
        guard let start = job.startedAt ?? job.createdAt else { return "" }
        let startStr = Self.jobTimeFmt.string(from: start)
        if let end = job.completedAt { return "\(startStr)->\(Self.jobTimeFmt.string(from: end))" }
        return "\(startStr)->now"
    }

    /// Returns the status dot colour for a job row using design tokens.
    func jobDotColor(for job: ActiveJob) -> Color {
        if job.isDimmed { return Color.rbTextTertiary }
        return job.status == "in_progress" ? Color.rbWarning : Color.rbTextTertiary
    }

    /// Short status label shown when a job has no conclusion yet.
    func jobStatusLabel(for job: ActiveJob) -> String {
        switch job.status {
        case "in_progress": return "In Progress"
        case "queued": return "Queued"
        default: return "Pending"
        }
    }

    /// Text colour for a live (no-conclusion) job status label.
    func jobStatusColor(for job: ActiveJob) -> Color {
        job.status == "in_progress" ? Color.rbWarning : Color.rbTextSecondary
    }

    /// Maps a raw conclusion string to a human-readable label.
    func conclusionLabel(_ conclusion: String) -> String {
        switch conclusion {
        case "success": return "checkmark success"
        case "failure": return "x failure"
        case "cancelled": return "cancelled"
        case "skipped": return "skipped"
        default: return conclusion
        }
    }

    /// Maps a raw conclusion string to a display colour using design tokens.
    func conclusionColor(_ conclusion: String) -> Color {
        switch conclusion {
        case "success": return Color.rbSuccess
        case "failure": return Color.rbDanger
        default: return Color.rbTextSecondary
        }
    }
}
