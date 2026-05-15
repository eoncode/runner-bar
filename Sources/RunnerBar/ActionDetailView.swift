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

/// Navigation level 2a (Actions path): shows the flat job list for a commit/PR group.
struct ActionDetailView: View {
    let group: ActionGroup
    let onBack: () -> Void
    let onSelectJob: (ActiveJob) -> Void

    @State private var tick = 0
    @State private var tickTimer: Timer?

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    private static let jobTimeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

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
            tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick += 1 }
        }
        .onDisappear {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    // MARK: - Body sub-views (split to avoid swift-frontend result-builder ICE)

    @ViewBuilder private var actionDetailHeader: some View {
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
    }

    @ViewBuilder private var actionDetailGroupInfo: some View {
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
            actionDetailTimingRow
            Text(jobsSummaryLine)
                .font(DesignTokens.Font.monoSmall)
                .foregroundColor(DesignTokens.Color.labelSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var actionDetailTimingRow: some View {
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
    }

    @ViewBuilder private var actionDetailJobList: some View {
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
}
// swiftlint:enable file_length identifier_name vertical_whitespace_opening_braces superfluous_disable_command

extension ActionDetailView { // swiftlint:disable:this missing_docs
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

    var labelLinkTooltip: String {
        group.label.hasPrefix("#")
            ? "Open pull request on GitHub"
            : "Open commit on GitHub"
    }

    var groupStartLabel: String {
        guard let date = group.firstJobStartedAt ?? group.createdAt else { return "—" }
        return Self.timeFmt.string(from: date)
    }

    var groupEndLabel: String {
        if let date = group.lastJobCompletedAt { return Self.timeFmt.string(from: date) }
        if group.groupStatus == .inProgress { return "now" }
        return "—"
    }

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

    func elapsedLive(tick _: Int) -> String { group.elapsed }

    // MARK: - Job row

    @ViewBuilder func jobRow(_ job: ActiveJob, index: Int) -> some View { // swiftlint:disable:this missing_docs
        VStack(spacing: 0) {
            jobRowMainLine(job, index: index)
            jobRowProgressBar(job)
        }
        .background(Rectangle().fill(jobRowTint(for: job)))
        .contentShape(Rectangle())
    }

    @ViewBuilder func jobRowMainLine(_ job: ActiveJob, index: Int) -> some View {
        HStack(spacing: 8) {
            Text("#\(index)")
                .font(DesignTokens.Font.monoXSmall)
                .foregroundColor(DesignTokens.Color.labelTertiary)
                .frame(width: 28, alignment: .leading)

            PieProgressDot(
                progress: job.progressFraction,
                color: jobDotColor(for: job),
                size: 9
            )

            Text(job.name)
                .font(.system(size: 12))
                .foregroundColor(job.isDimmed ? .secondary : .primary)
                .lineLimit(1).truncationMode(.tail).layoutPriority(1)

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
    }

    @ViewBuilder func jobRowProgressBar(_ job: ActiveJob) -> some View {
        if job.status == "in_progress", (job.progressFraction ?? 0) > 0 {
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
                        .frame(width: geo.size.width * CGFloat(job.progressFraction ?? 0))
                }
            }
            .frame(height: 2)
            .padding(.horizontal, 12)
        }
    }

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

    func jobTimeRange(_ job: ActiveJob) -> String {
        guard let start = job.startedAt ?? job.createdAt else { return "" }
        let startStr = Self.jobTimeFmt.string(from: start)
        if let end = job.completedAt { return "\(startStr)→\(Self.jobTimeFmt.string(from: end))" }
        return "\(startStr)→now"
    }

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

    func jobStatusLabel(for job: ActiveJob) -> String {
        switch job.status {
        case "in_progress": return "IN PROGRESS"
        case "queued":      return "QUEUED"
        default:            return "PENDING"
        }
    }

    func jobStatusColor(for job: ActiveJob) -> Color {
        job.status == "in_progress" ? DesignTokens.Color.statusBlue : DesignTokens.Color.labelSecondary
    }

    func conclusionLabel(_ conclusion: String) -> String {
        switch conclusion {
        case "success":   return "SUCCESS"
        case "failure":   return "FAILED"
        case "cancelled": return "CANCELLED"
        case "skipped":   return "SKIPPED"
        default:          return conclusion.uppercased()
        }
    }

    func conclusionColor(_ conclusion: String) -> Color {
        switch conclusion {
        case "success":   return DesignTokens.Color.statusGreen
        case "failure":   return DesignTokens.Color.statusRed
        default:          return DesignTokens.Color.labelSecondary
        }
    }
}
