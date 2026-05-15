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
//   .frame(minWidth: 560, maxWidth: .infinity, alignment: .top)
//   • minWidth: 560 — minimum panel width; content decides actual width.
//   • maxWidth: .infinity — fills the panel width up to AppDelegate.maxWidth.
//   • NO idealWidth here (set on sub-VStack if needed for measurement).
//   • NO maxHeight on the root frame.
//
// SCROLLVIEW HEIGHT CAP — REQUIRED:
//   .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
//   • Prevents the panel from growing off-screen with tall job lists.
//   • Without this, preferredContentSize.height == full content height on
//     navigate → NSPanel.setFrame() stretches the window off-screen.
//   ❌ NEVER remove this modifier from either ScrollView below.
//
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
// ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment
// is removed is major major major.
// ════════════════════════════════════════════════════════════════════════════════
//   Issue #419 Phase 5: jobDotColor / jobStatusColor / conclusionColor use DesignTokens.
//   Issue #419 Phase 5: job rows wrapped in cardRow-style RoundedRectangle background.
// ════════════════════════════════════════════════════════════════════════════════

/// Navigation level 2a (Actions path): shows the flat job list for a commit/PR group.
struct ActionDetailView: View {
    /// The action group whose jobs are displayed.
    let group: ActionGroup
    /// Called when the user taps the back button.
    let onBack: () -> Void
    /// Called when the user taps a job row.
    let onSelectJob: (ActiveJob) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            groupTitleBlock
            Divider()
            // ❌ NEVER remove .frame(maxHeight:) from this ScrollView.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 4) {
                    if group.jobs.isEmpty {
                        Text("No jobs available")
                            .font(.caption).foregroundColor(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    } else {
                        // Use enumerated() so the badge shows 1-based display order
                        // (#01, #02, …) rather than the GitHub workflow run number.
                        ForEach(Array(group.jobs.enumerated()), id: \.element.id) { index, job in
                            Button(action: { onSelectJob(job) }) {
                                jobRow(job, index: index + 1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
        }
        .frame(minWidth: 560, maxWidth: .infinity, alignment: .top)
    }

    // MARK: - Header bar
    private var headerBar: some View {
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
            actionCluster
            if let urlString = group.htmlUrl, let url = URL(string: urlString) {
                Button(
                    action: { NSWorkspace.shared.open(url) },
                    label: {
                        HStack(spacing: 3) {
                            Image(systemName: "safari").font(.caption)
                            Text("GitHub").font(.caption)
                        }
                        .foregroundColor(.secondary)
                        .fixedSize()
                    }
                )
                .buttonStyle(.plain)
                .help("Open on GitHub")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    // MARK: - Action cluster (extracted to reduce body length)
    private var actionCluster: some View {
        HStack(spacing: 4) {
            ReRunButton(
                action: { completion in
                    let scope = group.repo
                    let runIDs = group.runs.map { $0.id }
                    DispatchQueue.global(qos: .userInitiated).async {
                        let succeeded = runIDs.allSatisfy { runID in
                            reRunFailedJobs(runID: runID, repoSlug: scope)
                        }
                        DispatchQueue.main.async { completion(succeeded) }
                    }
                },
                isDisabled: group.groupStatus == .inProgress
            )
            CancelButton(
                action: { completion in
                    let scope = group.repo
                    let runIDs = group.runs.map { $0.id }
                    DispatchQueue.global(qos: .userInitiated).async {
                        let succeeded = runIDs.allSatisfy { runID in
                            cancelRun(runID: runID, repoSlug: scope)
                        }
                        DispatchQueue.main.async { completion(succeeded) }
                    }
                },
                isDisabled: group.groupStatus != .inProgress
            )
            LogCopyButton(
                fetch: { completion in
                    let grp = group
                    DispatchQueue.global(qos: .userInitiated).async {
                        completion(fetchActionLogs(group: grp))
                    }
                },
                isDisabled: false
            )
        }
    }

    // MARK: - Group title block
    private var groupTitleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button(action: openLabelOnGitHub) {
                    Text(group.label)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
                .help("Open on GitHub")
                BranchTagPill(name: repoSlug)
                Spacer()
                Text(group.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(group.isDimmed ? .secondary : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let start = group.firstJobStartedAt {
                Text(RelativeTimeFormatter.string(from: start))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private func openLabelOnGitHub() {
        guard let urlString = group.htmlUrl, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private var repoSlug: String {
        guard let url = group.htmlUrl else { return "" }
        let parts = url
            .replacingOccurrences(of: "https://github.com/", with: "")
            .components(separatedBy: "/")
        guard parts.count >= 2 else { return url }
        return parts[0] + "/" + parts[1]
    }
}

// MARK: - Row builder
extension ActionDetailView { // swiftlint:disable:this missing_docs

    /// Shared static formatter — avoids allocating a new DateFormatter on every row render.
    private static let timeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt
    }()

    /// Renders a single job row.
    /// - Parameters:
    ///   - job: The job to render.
    ///   - index: 1-based display-order position within this group's job list.
    @ViewBuilder
    private func jobRow(_ job: ActiveJob, index: Int) -> some View {
        HStack(spacing: 6) {
            // 1-based index within the group, zero-padded — NOT the GitHub run number.
            Text(String(format: "#%02d", index))
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 28, alignment: .leading)
            Circle().fill(jobDotColor(for: job)).frame(width: 7, height: 7)
            Text(job.name)
                .font(RBFont.mono)
                .foregroundColor(job.isDimmed ? .secondary : .primary)
                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
            if job.startedAt != nil {
                Spacer()
                Text(timeRange(for: job))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text(job.elapsed)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                Spacer()
            }
            jobStatusView(for: job)
            Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
        }
        // Issue #419 Phase 5: card row background
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Spacing.cardRadius, style: .continuous)
                .fill(DesignTokens.Colors.rowBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Spacing.cardRadius, style: .continuous)
                        .strokeBorder(DesignTokens.Colors.rowBorder, lineWidth: 0.5)
                )
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func jobStatusView(for job: ActiveJob) -> some View {
        if let conclusion = job.conclusion {
            Text(conclusionLabel(conclusion))
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(conclusionColor(conclusion))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        } else {
            Text(jobStatusLabel(for: job))
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(jobStatusColor(for: job))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func timeRange(for job: ActiveJob) -> String {
        guard let start = job.startedAt else { return "" }
        let fmt = Self.timeFormatter
        let startStr = fmt.string(from: start)
        if let end = job.completedAt { return "\(startStr)→\(fmt.string(from: end))" }
        return "\(startStr)→now"
    }

    /// Returns the status dot colour for a job row — uses DesignTokens.
    func jobDotColor(for job: ActiveJob) -> Color {
        if job.isDimmed { return .secondary }
        switch job.status {
        case "in_progress": return .rbBlue
        case "queued":      return .rbBlue.opacity(0.5)
        default:            return .secondary
        }
    }

    /// Short status label shown when a job has no conclusion yet.
    func jobStatusLabel(for job: ActiveJob) -> String {
        switch job.status {
        case "in_progress": return "IN PROGRESS"
        case "queued":      return "QUEUED"
        default:            return job.status.uppercased()
        }
    }

    /// Text colour for a live (no-conclusion) job status label — uses DesignTokens.
    func jobStatusColor(for job: ActiveJob) -> Color {
        job.status == "in_progress" ? .rbBlue : .secondary
    }

    /// Maps a raw conclusion string to a human-readable icon + label.
    func conclusionLabel(_ conclusion: String) -> String {
        switch conclusion {
        case "success":           return "✓ SUCCESS"
        case "failure":           return "✗ FAILED"
        case "cancelled":         return "⊘ CANCELLED"
        case "skipped":           return "⊘ SKIPPED"
        case "action_required":   return "! ACTION"
        default:                  return conclusion.uppercased()
        }
    }

    /// Maps a raw conclusion string to a display colour — uses DesignTokens.
    func conclusionColor(_ conclusion: String) -> Color {
        switch conclusion {
        case "success": return .rbSuccess
        case "failure": return .rbDanger
        default:        return .secondary
        }
    }
}
