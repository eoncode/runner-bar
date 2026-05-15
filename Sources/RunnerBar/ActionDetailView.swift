// swiftlint:disable file_length
import AppKit
import SwiftUI
// swiftlint:disable vertical_whitespace_opening_braces

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

// MARK: - ActionDetailView

/// Navigation level 2a (Actions path): shows the flat job list for a commit/PR group.
struct ActionDetailView: View {
    /// The action group whose jobs are displayed.
    let group: ActionGroup
    /// Called when the user taps the back button.
    let onBack: () -> Void
    /// Called when the user selects a job row.
    let onSelectJob: (ActiveJob) -> Void

    @State private var tick = 0
    @State private var tickTimer: Timer?

    private static let timeFmt: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let jobTimeFmt: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// Root body.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            actionDetailHeader
            actionDetailGroupInfo
            Divider()
            actionDetailJobList
        }
        .frame(minWidth: 560, maxWidth: .infinity, alignment: .top)
        .onAppear {
            tickTimer?.invalidate()
            tickTimer = Timer.scheduledTimer(
                withTimeInterval: 1,
                repeats: true
            ) { _ in tick += 1 }
        }
        .onDisappear {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    // MARK: - Header

    @ViewBuilder private var actionDetailHeader: some View {
        HStack(spacing: 6) {
            actionDetailBackButton
            Spacer()
            actionDetailReRunButton
            actionDetailCancelButton
            actionDetailLogCopyButton
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    @ViewBuilder private var actionDetailBackButton: some View {
        Button(action: onBack) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left").font(.caption)
                Text("Actions").font(.caption)
            }
            .foregroundColor(.secondary)
            .fixedSize()
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var actionDetailReRunButton: some View {
        let disabled: Bool = group.groupStatus == .inProgress
        ReRunButton(action: reRunAction, isDisabled: disabled)
    }

    @ViewBuilder private var actionDetailCancelButton: some View {
        let disabled: Bool = group.groupStatus != .inProgress
        CancelButton(action: cancelAction, isDisabled: disabled)
    }

    @ViewBuilder private var actionDetailLogCopyButton: some View {
        LogCopyButton(fetch: logFetchAction, isDisabled: false)
    }

    // MARK: - Group info

    @ViewBuilder private var actionDetailGroupInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            actionDetailGroupTitleRow
            actionDetailBranchRow
            actionDetailTimingRow
            actionDetailJobsSummary
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var actionDetailGroupTitleRow: some View {
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
    }

    @ViewBuilder private var actionDetailBranchRow: some View {
        Group {
            if let branch = group.headBranch {
                Text(branch)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder private var actionDetailJobsSummary: some View {
        Text(jobsSummaryLine)
            .font(DesignTokens.Font.monoSmall)
            .foregroundColor(DesignTokens.Color.labelSecondary)
    }

    @ViewBuilder private var actionDetailTimingRow: some View {
        let startLabel: String = groupStartLabel
        let endLabel: String = groupEndLabel
        let elapsed: String = elapsedLive(tick: tick)
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 9))
                .foregroundColor(DesignTokens.Color.labelSecondary)
            Text(startLabel)
                .font(DesignTokens.Font.monoSmall)
                .foregroundColor(DesignTokens.Color.labelSecondary)
                .fixedSize()
            Text("→")
                .font(.caption2)
                .foregroundColor(DesignTokens.Color.labelSecondary)
            Text(endLabel)
                .font(DesignTokens.Font.monoSmall)
                .foregroundColor(DesignTokens.Color.labelSecondary)
                .fixedSize()
            Text("·")
                .font(.caption2)
                .foregroundColor(DesignTokens.Color.labelSecondary)
            Text(elapsed)
                .font(DesignTokens.Font.monoSmall)
                .foregroundColor(DesignTokens.Color.labelSecondary)
                .fixedSize()
        }
    }

    // MARK: - Job list

    @ViewBuilder private var actionDetailJobList: some View {
        // ❌ NEVER remove .frame(maxHeight:) from this ScrollView.
        let maxH: CGFloat = NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600
        ScrollView(.vertical, showsIndicators: true) {
            actionDetailJobListContent
        }
        .frame(maxHeight: maxH)
    }

    @ViewBuilder private var actionDetailJobListContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if group.jobs.isEmpty {
                Text("No jobs available")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                ForEach(Array(group.jobs.enumerated()), id: \.element.id) { idx, job in
                    Button(action: { onSelectJob(job) }) {
                        jobRow(job, index: idx + 1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
// swiftlint:enable vertical_whitespace_opening_braces

// MARK: - ActionDetailView + Actions

extension ActionDetailView {

    // NOTE: Swift 6.3.2 ICE workaround.
    /// Re-runs each run ID in `runIDs` and returns `true` if all succeeded.
    private func reRunIDs(_ runIDs: [Int], scope: String) -> Bool {
        var succeeded = true
        for runID in runIDs {
            let endpoint: String = "repos/\(scope)/actions/runs/\(runID)/rerun-failed-jobs"
            // swiftlint:disable:next identifier_name
            let ok: Bool = ghPost(endpoint)
            if !ok { succeeded = false }
        }
        return succeeded
    }

    /// Triggers a re-run of all jobs in the group, calling `completion` with the result.
    func reRunAction(completion: @escaping (Bool) -> Void) {
        let scope: String = group.repo
        let runIDs: [Int] = group.runs.map { $0.id }
        DispatchQueue.global(qos: .userInitiated).async {
            completion(reRunIDs(runIDs, scope: scope))
        }
    }

    /// Cancels all runs in the group, calling `completion` with the result.
    func cancelAction(completion: @escaping (Bool) -> Void) {
        let scope: String = group.repo
        let runIDs: [Int] = group.runs.map { $0.id }
        DispatchQueue.global(qos: .userInitiated).async {
            let allCancelled = runIDs.allSatisfy { runID in
                cancelRun(runID: runID, scope: scope)
            }
            completion(allCancelled)
        }
    }

    /// Fetches logs for all jobs in the group, calling `completion` with the result.
    func logFetchAction(completion: @escaping (String?) -> Void) {
        let grp: ActionGroup = group
        DispatchQueue.global(qos: .userInitiated).async {
            completion(fetchActionLogs(group: grp))
        }
    }

    /// Opens the PR or commit URL for this group's label in the default browser.
    func openLabelOnGitHub() {
        let urlStr: String
        if group.label.hasPrefix("#"), let number = Int(group.label.dropFirst()) {
            urlStr = "https://github.com/\(group.repo)/pull/\(number)"
        } else {
            urlStr = "https://github.com/\(group.repo)/commit/\(group.headSha)"
        }
        guard let url = URL(string: urlStr) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Tooltip text for the label link chip.
    var labelLinkTooltip: String {
        return group.label.hasPrefix("#") ? "Open pull request on GitHub" : "Open commit on GitHub"
    }

    /// Formatted start time label for the group timing row.
    var groupStartLabel: String {
        guard let date = group.firstJobStartedAt ?? group.createdAt else { return "—" }
        return Self.timeFmt.string(from: date)
    }

    /// Formatted end time label for the group timing row.
    var groupEndLabel: String {
        if let date = group.lastJobCompletedAt { return Self.timeFmt.string(from: date) }
        if group.groupStatus == .inProgress { return "now" }
        return "—"
    }

    /// Single-line summary of job completion state for the group.
    var jobsSummaryLine: String {
        let done = group.jobsDone
        let total = group.jobsTotal
        let conclusions = group.jobs.compactMap { $0.conclusion }
        if group.groupStatus == .inProgress || conclusions.count < total {
            return "\(done)/\(total) jobs running"
        }
        if conclusions.contains("failure")   { return "\(done)/\(total) jobs failed" }
        if conclusions.contains("cancelled") { return "\(done)/\(total) jobs cancelled" }
        if conclusions.allSatisfy({ $0 == "success" || $0 == "skipped" }) {
            return "\(done)/\(total) jobs succeeded"
        }
        return "\(done)/\(total) jobs completed"
    }

    /// Returns the live elapsed string for the group, re-evaluated every tick.
    func elapsedLive(tick _: Int) -> String { return group.elapsed }
}

// MARK: - ActionDetailView + Job rows

extension ActionDetailView {

    /// Builds the full job row (main line + optional progress bar).
    @ViewBuilder func jobRow(_ job: ActiveJob, index: Int) -> some View {
        VStack(spacing: 0) {
            jobRowMainLine(job, index: index)
            jobRowProgressBar(job)
        }
        .background(Rectangle().fill(jobRowTint(for: job)))
        .contentShape(Rectangle())
    }

    /// Builds the main content line of a job row.
    @ViewBuilder func jobRowMainLine(_ job: ActiveJob, index: Int) -> some View {
        let indexText: String = "#\(index)"
        let dotColor: Color = jobDotColor(for: job)
        let nameColor: Color = job.isDimmed ? Color.secondary : Color.primary
        let timeRange: String = jobTimeRange(job)
        let hasStart: Bool = job.startedAt != nil
        let elapsed: String = job.elapsed
        HStack(spacing: 8) {
            Text(indexText)
                .font(DesignTokens.Font.monoXSmall)
                .foregroundColor(DesignTokens.Color.labelTertiary)
                .frame(width: 28, alignment: .leading)
            PieProgressDot(progress: job.progressFraction, color: dotColor, size: 9)
            Text(job.name)
                .font(.system(size: 12))
                .foregroundColor(nameColor)
                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
            jobRowTimeRangeView(hasStart: hasStart, timeRange: timeRange)
            Spacer(minLength: 0)
            jobRowStatusBadge(job)
            jobRowElapsedView(hasStart: hasStart, elapsed: elapsed)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(DesignTokens.Color.labelTertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    @ViewBuilder private func jobRowTimeRangeView(hasStart: Bool, timeRange: String) -> some View {
        Group {
            if hasStart {
                Text(timeRange)
                    .font(DesignTokens.Font.monoXSmall)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)
            } else {
                Spacer().frame(width: 130)
            }
        }
    }

    @ViewBuilder private func jobRowElapsedView(hasStart: Bool, elapsed: String) -> some View {
        Group {
            if hasStart {
                Text(elapsed)
                    .font(DesignTokens.Font.monoSmall)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                    .frame(width: 44, alignment: .trailing)
            } else {
                Spacer().frame(width: 44)
            }
        }
    }

    @ViewBuilder private func jobRowStatusBadge(_ job: ActiveJob) -> some View {
        let label: String = job.conclusion.map { conclusionLabel($0) } ?? jobStatusLabel(for: job)
        let color: Color = job.conclusion.map { conclusionColor($0) } ?? jobStatusColor(for: job)
        StatusBadge(label: label, color: color)
            .frame(width: 88, alignment: .trailing)
    }

    /// Builds the thin progress bar shown beneath an in-progress job row.
    @ViewBuilder func jobRowProgressBar(_ job: ActiveJob) -> some View {
        let fraction: CGFloat = CGFloat(job.progressFraction ?? 0)
        let isActive: Bool = job.status == "in_progress" && fraction > 0
        Group {
            if isActive {
                JobProgressBarView(fraction: fraction)
                    .frame(height: 2)
                    .padding(.horizontal, 12)
            }
        }
    }

    /// Returns the background tint color for a job row based on status/conclusion.
    func jobRowTint(for job: ActiveJob) -> Color {
        guard !job.isDimmed else { return Color.clear }
        if job.status == "in_progress" || job.status == "queued" {
            return DesignTokens.Color.tintBlue
        }
        if job.conclusion == "success" { return DesignTokens.Color.tintGreen }
        if job.conclusion == "failure" { return DesignTokens.Color.tintRed }
        return Color.clear
    }

    /// Returns the formatted time-range string for a job row.
    func jobTimeRange(_ job: ActiveJob) -> String {
        guard let start = job.startedAt ?? job.createdAt else { return "" }
        let startStr = Self.jobTimeFmt.string(from: start)
        if let end = job.completedAt {
            return "\(startStr)→\(Self.jobTimeFmt.string(from: end))"
        }
        return "\(startStr)→now"
    }

    /// Returns the dot color for a job row based on status/conclusion.
    func jobDotColor(for job: ActiveJob) -> Color {
        if job.isDimmed { return DesignTokens.Color.labelTertiary }
        if job.status == "in_progress" { return DesignTokens.Color.statusBlue }
        if job.status == "queued" { return DesignTokens.Color.statusBlue.opacity(0.5) }
        if job.conclusion == "success" { return DesignTokens.Color.statusGreen }
        if job.conclusion == "failure" { return DesignTokens.Color.statusRed }
        return Color.secondary
    }

    /// Returns the status badge label string for a job that has no conclusion yet.
    func jobStatusLabel(for job: ActiveJob) -> String {
        switch job.status {
        case "in_progress": return "running"
        case "queued":      return "queued"
        case "waiting":     return "waiting"
        default:            return job.status
        }
    }

    /// Returns the status badge color for a job that has no conclusion yet.
    func jobStatusColor(for job: ActiveJob) -> Color {
        switch job.status {
        case "in_progress": return DesignTokens.Color.statusBlue
        case "queued":      return DesignTokens.Color.statusBlue.opacity(0.6)
        default:            return Color.secondary
        }
    }

    /// Returns the human-readable label for a job conclusion string.
    func conclusionLabel(_ conclusion: String) -> String {
        switch conclusion {
        case "success":   return "success"
        case "failure":   return "failed"
        case "cancelled": return "cancelled"
        case "skipped":   return "skipped"
        case "timed_out": return "timed out"
        default:          return conclusion
        }
    }

    /// Returns the badge color for a job conclusion string.
    func conclusionColor(_ conclusion: String) -> Color {
        switch conclusion {
        case "success":   return DesignTokens.Color.statusGreen
        case "failure":   return DesignTokens.Color.statusRed
        case "cancelled": return Color.secondary
        case "skipped":   return Color.secondary
        case "timed_out": return DesignTokens.Color.statusRed
        default:          return Color.secondary
        }
    }
}
// swiftlint:enable file_length
