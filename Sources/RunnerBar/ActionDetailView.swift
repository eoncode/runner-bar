import AppKit
import SwiftUI
// swiftlint:disable file_length identifier_name vertical_whitespace_opening_braces superfluous_disable_command

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
//   .frame(minWidth: 560, maxWidth: .infinity, alignment: .top)
//   • minWidth: 560 — minimum panel width; content decides actual width.
//   • maxWidth: .infinity — fills the panel width up to AppDelegate.maxWidth.
//   • NO idealWidth — width is content-driven, not pinned to a fixed value.
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
//   Added #N order index badge to each job row (1-based display order).
//   Replaced generic "X/N jobs concluded" with context-aware outcome label.
//   Elapsed moved from header to timing row below branch label.
//   SHA/PR label made tappable: opens commit or PR on GitHub.
//   Time-range and elapsed columns hidden for queued jobs (no startedAt).
//   Switched from idealWidth (fixed) to minWidth (content-driven) width model.
//   Phase 5: PieProgressDot replaces plain Circle dot; StatusBadge chips;
//            DesignTokens fonts + colours on all meta columns.
//   Gap fix: thin horizontal progress bar added beneath in_progress job rows.
//   Gap fix: jobRowTint now uses DesignTokens.Color tint constants (not raw opacity).
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

    /// HH:mm formatter — used for group start/end labels in the header.
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// HH:mm:ss formatter — used for per-job time-range column.
    /// Static so it is created once and reused on every 1 Hz tick × N job rows.
    private static let jobTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ────────────────────────────────────────────────────────────────
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

            // ── Group title block ────────────────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Button(action: openLabelOnGitHub) {
                        Text(group.label)
                            .font(DesignTokens.Font.monoSmall)
                            .foregroundColor(DesignTokens.Color.labelSecondary)
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
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                    Text(groupStartLabel)
                        .font(DesignTokens.Font.monoSmall)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                        .fixedSize()
                    Text("→")
                        .font(.caption2)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                    Text(groupEndLabel)
                        .font(DesignTokens.Font.monoSmall)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                        .fixedSize()
                    Text("·")
                        .font(.caption2)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                    Text(elapsedLive(tick: tick))
                        .font(DesignTokens.Font.monoSmall)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                        .fixedSize()
                }
                Text(jobsSummaryLine)
                    .font(DesignTokens.Font.monoSmall)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            // ── Jobs list ────────────────────────────────────────────────────────────────
            // ❌ NEVER remove .frame(maxHeight:) from this ScrollView.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    if group.jobs.isEmpty {
                        Text("No jobs available")
                            .font(.caption).foregroundColor(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    } else {
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
        .frame(minWidth: 560, maxWidth: .infinity, alignment: .top)
        .onAppear {
            tickTimer?.invalidate()
            tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick += 1 }
        }
        .onDisappear {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }
}
// swiftlint:enable file_length identifier_name vertical_whitespace_opening_braces superfluous_disable_command

extension ActionDetailView { // swiftlint:disable:this missing_docs
    /// Opens the SHA commit or PR associated with the group label on GitHub.
    func openLabelOnGitHub() {
        let urlString: String
        if group.label.hasPrefix("#"),
           let number = Int(group.label.dropFirst()) {
            urlString = "https://github.com/\(group.repo)/pull/\(number)"
        } else {
            urlString = "https://github.com/\(group.repo)/commit/\(group.headSha)"
        }
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Tooltip text for the label link button.
    var labelLinkTooltip: String {
        group.label.hasPrefix("#")
            ? "Open pull request on GitHub"
            : "Open commit on GitHub"
    }

    /// Formatted start time for the group.
    var groupStartLabel: String {
        guard let date = group.firstJobStartedAt ?? group.createdAt else { return "—" }
        return Self.timeFmt.string(from: date)
    }

    /// Formatted end time for the group, or "now" while in progress.
    var groupEndLabel: String {
        if let date = group.lastJobCompletedAt { return Self.timeFmt.string(from: date) }
        if group.groupStatus == .inProgress { return "now" }
        return "—"
    }

    /// Human-readable summary of job completion state.
    var jobsSummaryLine: String {
        let done  = group.jobsDone
        let total = group.jobsTotal
        let conclusions = group.jobs.compactMap { $0.conclusion }
        if group.groupStatus == .inProgress || conclusions.count < total { return "\(done)/\(total) jobs running" }
        if conclusions.contains("failure") { return "\(done)/\(total) jobs failed" }
        if conclusions.contains("cancelled") { return "\(done)/\(total) jobs cancelled" }
        if conclusions.allSatisfy({ $0 == "success" || $0 == "skipped" }) { return "\(done)/\(total) jobs succeeded" }
        return "\(done)/\(total) jobs completed"
    }

    /// Returns the group elapsed string; `tick` triggers SwiftUI refresh every second.
    func elapsedLive(tick _: Int) -> String { group.elapsed }

    // MARK: - Job row
    @ViewBuilder func jobRow(_ job: ActiveJob, index: Int) -> some View { // swiftlint:disable:this missing_docs
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Index badge
                Text("#\(index)")
                    .font(DesignTokens.Font.monoXSmall)
                    .foregroundColor(DesignTokens.Color.labelTertiary)
                    .frame(width: 28, alignment: .leading)

                // Animated progress dot (PieProgressDot replaces plain Circle)
                PieProgressDot(
                    progress: job.progressFraction,
                    color: jobDotColor(for: job),
                    size: 9
                )

                // Job name
                Text(job.name)
                    .font(.system(size: 12))
                    .foregroundColor(job.isDimmed ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(1)

                // Time range column (hidden for queued jobs)
                if job.startedAt != nil {
                    Text(jobTimeRange(job))
                        .font(DesignTokens.Font.monoXSmall)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                        .lineLimit(1)
                        .frame(width: 130, alignment: .leading)
                } else {
                    Spacer().frame(width: 130)
                }

                Spacer(minLength: 0)

                // Conclusion / status chip (StatusBadge replaces plain Text)
                if let conclusion = job.conclusion {
                    StatusBadge(
                        label: conclusionLabel(conclusion),
                        color: conclusionColor(conclusion)
                    )
                    .frame(width: 88, alignment: .trailing)
                } else {
                    StatusBadge(
                        label: jobStatusLabel(for: job),
                        color: jobStatusColor(for: job)
                    )
                    .frame(width: 88, alignment: .trailing)
                }

                // Elapsed column (hidden for queued jobs)
                if job.startedAt != nil {
                    Text(job.elapsed)
                        .font(DesignTokens.Font.monoSmall)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                        .frame(width: 44, alignment: .trailing)
                } else {
                    Spacer().frame(width: 44)
                }

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(DesignTokens.Color.labelTertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 5)

            // Horizontal progress bar — shown only for in_progress jobs with measurable progress
            if job.status == "in_progress", job.progressFraction > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(DesignTokens.Color.statusBlue.opacity(0.12))
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [DesignTokens.Color.statusBlue, DesignTokens.Color.statusBlue.opacity(0.6)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * CGFloat(job.progressFraction))
                    }
                }
                .frame(height: 2)
                .padding(.horizontal, 12)
            }
        }
        .background(
            // Subtle tint per job status — uses DesignTokens.Color tint constants.
            // ❌ NEVER replace with raw .opacity() values — use the pre-defined tint tokens
            // so all row tints come from the single source of truth in DesignTokens.
            Rectangle().fill(jobRowTint(for: job))
        )
        .contentShape(Rectangle())
    }

    /// Subtle background tint for each job row based on live status.
    /// Uses DesignTokens.Color tint constants (tintBlue/tintGreen/tintRed) for
    /// system-wide consistency — do not replace with raw .opacity() values.
    func jobRowTint(for job: ActiveJob) -> Color {
        guard !job.isDimmed else { return .clear }
        switch job.status {
        case "in_progress": return DesignTokens.Color.tintBlue
        case "queued":      return DesignTokens.Color.tintBlue
        default:
            switch job.conclusion {
            case "success":   return DesignTokens.Color.tintGreen
            case "failure":   return DesignTokens.Color.tintRed
            default:          return .clear
            }
        }
    }

    /// Formats start→end time range for a job row.
    func jobTimeRange(_ job: ActiveJob) -> String {
        guard let start = job.startedAt ?? job.createdAt else { return "" }
        let startStr = Self.jobTimeFmt.string(from: start)
        if let end = job.completedAt { return "\(startStr)→\(Self.jobTimeFmt.string(from: end))" }
        return "\(startStr)→now"
    }

    /// Status dot colour for a job row (used by PieProgressDot).
    func jobDotColor(for job: ActiveJob) -> Color {
        if job.isDimmed { return DesignTokens.Color.labelTertiary }
        switch job.status {
        case "in_progress": return DesignTokens.Color.statusBlue
        case "queued":      return DesignTokens.Color.statusBlue.opacity(0.5)
        default:
            return job.conclusion == "success"
                ? DesignTokens.Color.statusGreen
                : (job.conclusion == "failure" ? DesignTokens.Color.statusRed : .secondary)
        }
    }

    /// Short status label for jobs without a conclusion.
    func jobStatusLabel(for job: ActiveJob) -> String {
        switch job.status {
        case "in_progress": return "IN PROGRESS"
        case "queued":      return "QUEUED"
        default:            return "PENDING"
        }
    }

    /// StatusBadge colour for a live (no-conclusion) job.
    func jobStatusColor(for job: ActiveJob) -> Color {
        job.status == "in_progress" ? DesignTokens.Color.statusBlue : DesignTokens.Color.labelSecondary
    }

    /// Maps a raw conclusion string to an uppercase label for StatusBadge.
    func conclusionLabel(_ conclusion: String) -> String {
        switch conclusion {
        case "success":   return "SUCCESS"
        case "failure":   return "FAILED"
        case "cancelled": return "CANCELLED"
        case "skipped":   return "SKIPPED"
        default:          return conclusion.uppercased()
        }
    }

    /// Maps a raw conclusion string to the appropriate DesignTokens colour.
    func conclusionColor(_ conclusion: String) -> Color {
        switch conclusion {
        case "success":   return DesignTokens.Color.statusGreen
        case "failure":   return DesignTokens.Color.statusRed
        default:          return DesignTokens.Color.labelSecondary
        }
    }
}
