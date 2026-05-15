import AppKit
import SwiftUI

// ════════════════════════════════════════════════════════════════════════════════
// ⚠️⚠️⚠️ NSPANEL SIZING GUARD — READ THIS BEFORE ANY EDIT ⚠️⚠️⚠️
// ════════════════════════════════════════════════════════════════════════════════
//
// ARCHITECTURE: NSPanel (NOT NSPopover). Width is dynamic.
//
// ROOT FRAME RULE:
//   .frame(idealWidth: 720, maxWidth: .infinity, alignment: .top)
//
// SCROLLVIEW HEIGHT CAP — REQUIRED:
//   .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
//   ❌ NEVER remove this modifier from the ScrollView.
//   ❌ NEVER use a fixed constant.
//
// ════════════════════════════════════════════════════════════════════════════════
// swiftlint:disable:next type_body_length
/// Navigation level 2 (Jobs path): step list for a single `ActiveJob`.
/// Drill-down chain: PopoverMainView → JobDetailView → StepLogView.
struct JobDetailView: View {
    /// The job whose steps are displayed.
    let job: ActiveJob
    /// The action group this job belongs to (used for metadata chips).
    let group: ActionGroup
    /// Called when the user taps the back button.
    let onBack: () -> Void
    /// Called when the user taps a step row.
    let onSelectStep: (JobStep) -> Void

    @State private var tick = 0
    @State private var tickTimer: Timer?

    /// Root body: top action bar + info bar + step list.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.caption)
                        Text("Jobs").font(.caption)
                    }
                    .foregroundColor(.secondary)
                    .fixedSize()
                }
                .buttonStyle(.plain)

                Text(job.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                ReRunButton(
                    action: { completion in
                        let jobID = job.id
                        let scopeStr = scopeFromHtmlUrl(job.htmlUrl) ?? ""
                        if scopeStr.isEmpty {
                            log(
                                "ReRunButton › could not derive scope from htmlUrl: "
                                + "\(String(describing: job.htmlUrl))"
                            )
                        }
                        DispatchQueue.global(qos: .userInitiated).async {
                            let isOk = scopeStr.contains("/")
                                && ghPost("repos/\(scopeStr)/actions/jobs/\(jobID)/rerun")
                            completion(isOk)
                        }
                    },
                    isDisabled: job.status == "in_progress" || job.status == "queued"
                )

                ReRunFailedButton(
                    action: { completion in
                        let scopeStr = scopeFromHtmlUrl(job.htmlUrl) ?? ""
                        let runID = runIDFromHtmlUrl(job.htmlUrl)
                        guard scopeStr.contains("/"), let runID else {
                            log(
                                "ReRunFailedButton › could not derive scope/runID from htmlUrl: "
                                + "\(String(describing: job.htmlUrl))"
                            )
                            completion(false)
                            return
                        }
                        DispatchQueue.global(qos: .userInitiated).async {
                            completion(
                                ghPost("repos/\(scopeStr)/actions/runs/\(runID)/rerun-failed-jobs")
                            )
                        }
                    },
                    isDisabled: job.status == "in_progress"
                        || job.status == "queued"
                        || (job.conclusion != "failure" && job.conclusion != "cancelled")
                )

                CancelButton(
                    action: { completion in
                        let scopeStr = scopeFromHtmlUrl(job.htmlUrl) ?? ""
                        let runID = runIDFromHtmlUrl(job.htmlUrl)
                        guard scopeStr.contains("/"), let runID else {
                            log(
                                "CancelButton › could not derive scope/runID from htmlUrl: "
                                + "\(String(describing: job.htmlUrl))"
                            )
                            completion(false)
                            return
                        }
                        DispatchQueue.global(qos: .userInitiated).async {
                            completion(cancelRun(runID: runID, scope: scopeStr))
                        }
                    },
                    isDisabled: job.status != "in_progress" && job.status != "queued"
                )

                if let urlString = job.htmlUrl, let url = URL(string: urlString) {
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
                    .help("Open job on GitHub")
                }

                LogCopyButton(
                    fetch: { completion in
                        let jobID = job.id
                        let scopeStr = scopeFromHtmlUrl(job.htmlUrl) ?? ""
                        DispatchQueue.global(qos: .userInitiated).async {
                            completion(fetchJobLog(jobID: jobID, scope: scopeStr))
                        }
                    },
                    isDisabled: false
                )
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 3)

            infoBar
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Divider()

            // ❌ NEVER remove .frame(maxHeight:) from this ScrollView.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    if job.steps.isEmpty {
                        Text("No step data available")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(job.steps) { step in
                            Button(
                                action: { onSelectStep(step) },
                                label: { stepRow(step) }
                            )
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
        }
        .frame(idealWidth: 720, maxWidth: .infinity, alignment: .top)
        .onAppear {
            tickTimer = Timer.scheduledTimer(
                withTimeInterval: 1,
                repeats: true,
                block: { _ in tick += 1 }
            )
        }
        .onDisappear {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    // MARK: - Info bar (row 2)

    /// Single caption-height line combining timing + metadata chips.
    @ViewBuilder private var infoBar: some View {
        HStack(spacing: 4) {
            if let start = job.startedAt {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                Text(wallTime(start))
                    .font(DesignTokens.Font.monoSmall)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9))
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                if let end = job.completedAt {
                    Text(wallTime(end))
                        .font(DesignTokens.Font.monoSmall)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                } else {
                    Text("running")
                        .font(DesignTokens.Font.monoSmall)
                        .foregroundColor(DesignTokens.Color.statusBlue)
                }
                Text("·")
                    .font(.caption)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                Text(job.isDimmed ? job.elapsed : elapsedLive(tick: tick))
                    .font(DesignTokens.Font.monoSmall)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                Text("·")
                    .font(.caption)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                    .padding(.horizontal, 1)
            }
            if let repoURL = URL(string: "https://github.com/\(group.repo)") {
                let repoName = group.repo.components(separatedBy: "/").last ?? group.repo
                metadataChip(icon: "folder", label: repoName, url: repoURL, tooltip: group.repo)
            }
            if let branch = group.headBranch,
               let branchURL = URL(
                    string: "https://github.com/\(group.repo)/tree/"
                        + (branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch)
               ) {
                metadataChip(
                    icon: "arrow.triangle.branch",
                    label: branch,
                    url: branchURL,
                    tooltip: "Branch: \(branch)"
                )
            }
            let originURL: URL? = {
                let lbl = group.label
                if lbl.hasPrefix("#"),
                   let num = lbl.dropFirst()
                        .components(separatedBy: CharacterSet.decimalDigits.inverted).first,
                   !num.isEmpty {
                    return URL(string: "https://github.com/\(group.repo)/pull/\(num)")
                } else {
                    return URL(string: "https://github.com/\(group.repo)/commit/\(group.headSha)")
                }
            }()
            if let url = originURL {
                let isPR = group.label.hasPrefix("#")
                metadataChip(
                    icon: isPR ? "arrow.triangle.pull" : "chevron.left.forwardslash.chevron.right",
                    label: group.label,
                    url: url,
                    tooltip: isPR
                        ? "Pull request \(group.label)"
                        : "Commit \(group.headSha.prefix(7))"
                )
            }
            Spacer(minLength: 0)
        }
    }

    /// A small pressable label chip: icon + text, opens `url` on click.
    @ViewBuilder private func metadataChip(
        icon: String,
        label: String,
        url: URL,
        tooltip: String
    ) -> some View {
        Button(
            action: { NSWorkspace.shared.open(url) },
            label: {
                HStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.system(size: 9))
                    Text(label)
                        .font(DesignTokens.Font.monoSmall)
                        .lineLimit(1)
                }
                .foregroundColor(DesignTokens.Color.labelSecondary)
                .fixedSize()
            }
        )
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: - Step row

    /// Single-line step row: badge, icon, name, timestamps, elapsed, chevron.
    @ViewBuilder private func stepRow(_ step: JobStep) -> some View {
        HStack(spacing: 6) {
            Text(String(format: "#%02d", step.id))
                .font(DesignTokens.Font.monoXSmall)
                .foregroundColor(DesignTokens.Color.labelTertiary)
                .fixedSize(horizontal: true, vertical: false)
            Text(step.conclusionIcon)
                .font(.system(size: 11))
                .foregroundColor(stepColor(step))
                .frame(width: 14, alignment: .center)
            Text(step.name)
                .font(.system(size: 12))
                .foregroundColor(step.status == "queued" ? DesignTokens.Color.labelSecondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if let start = step.startedAt {
                HStack(spacing: 3) {
                    Text(wallTime(start))
                        .font(DesignTokens.Font.monoSmall)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                    Text("→")
                        .font(.caption)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                    if let end = step.completedAt {
                        Text(wallTime(end))
                            .font(DesignTokens.Font.monoSmall)
                            .foregroundColor(DesignTokens.Color.labelSecondary)
                    } else {
                        Text("now")
                            .font(DesignTokens.Font.monoSmall)
                            .foregroundColor(DesignTokens.Color.statusBlue)
                    }
                }
                .fixedSize()
            }
            Text(step.elapsed)
                .font(DesignTokens.Font.monoSmall)
                .foregroundColor(DesignTokens.Color.labelSecondary)
                .fixedSize()
                .frame(width: 40, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(DesignTokens.Color.labelTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    // MARK: - Helpers

    /// Returns the live elapsed string, re-evaluated every tick.
    private func elapsedLive(tick _: Int) -> String { job.elapsed }

    /// Maps a step's conclusion/status to a DesignTokens display colour.
    private func stepColor(_ step: JobStep) -> Color {
        switch step.conclusion {
        case "success": return DesignTokens.Color.statusGreen
        case "failure": return DesignTokens.Color.statusRed
        default: return step.status == "in_progress"
            ? DesignTokens.Color.statusBlue
            : DesignTokens.Color.labelSecondary
        }
    }
}

// MARK: - Wallclock formatter

private let _wallTimeFmt: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
}()

/// Formats a `Date` as a wall-clock string (`HH:mm:ss`).
private func wallTime(_ date: Date) -> String {
    _wallTimeFmt.string(from: date)
}
