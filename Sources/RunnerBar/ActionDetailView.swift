// swiftlint:disable all
import AppKit
import SwiftUI

/// Navigation level 1 (Actions path): flat job list for an `ActionGroup`.
struct ActionDetailView: View {
    /// The action group whose jobs are displayed.
    let group: ActionGroup
    /// Display tick for live elapsed-time updates.
    let tick: Int
    /// Called when the user taps the back button.
    let onBack: () -> Void
    /// Called when the user taps a job row.
    let onSelectJob: (ActiveJob) -> Void
    @EnvironmentObject var store: RunnerStoreObservable

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            infoBar
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 4) {
                    if group.jobs.isEmpty {
                        Text("Loading jobs…")
                            .font(.caption).foregroundColor(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    } else {
                        ForEach(group.jobs) { job in
                            Button(action: { onSelectJob(job) }) { jobRow(job) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
        }
        .frame(idealWidth: 720, maxWidth: .infinity, alignment: .top)
    }

    // fix(#449): restore ReRunButton, CancelButton, LogCopyButton
    // fix(#450): restore tappable SHA/PR label
    private var headerBar: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.caption)
                    Text("Actions").font(.caption)
                }.foregroundColor(.secondary).fixedSize()
            }.buttonStyle(.plain)
            Spacer(minLength: 8)
            // fix(#450): tappable SHA/PR label
            Button(action: openLabelOnGitHub) {
                Text(group.label)
                    .font(DesignTokens.Fonts.mono)
                    .foregroundColor(.secondary)
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .help(group.label.hasPrefix("#") ? "Open pull request on GitHub" : "Open commit on GitHub")
            Spacer(minLength: 0)
            // fix(#449): restore action buttons
            ReRunButton(
                action: { completion in
                    guard let repo = group.repo else { completion(false); return }
                    let runIDs = group.runs.map { $0.id }
                    DispatchQueue.global(qos: .userInitiated).async {
                        let ok = runIDs.allSatisfy { runID in
                            ghPost("repos/\(repo)/actions/runs/\(runID)/rerun-failed-jobs")
                        }
                        completion(ok)
                    }
                },
                isDisabled: group.groupStatus == .inProgress
            )
            CancelButton(
                action: { completion in
                    guard let repo = group.repo else { completion(false); return }
                    let runIDs = group.runs.map { $0.id }
                    DispatchQueue.global(qos: .userInitiated).async {
                        let ok = runIDs.allSatisfy { runID in
                            cancelRun(runID: runID, scope: repo)
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
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
    }

    private var infoBar: some View {
        let _ = tick
        return HStack(spacing: 6) {
            Text(group.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(group.isDimmed ? .secondary : .primary)
                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
            if let branch = group.headBranch { BranchTagPill(name: branch) }
            Spacer()
            Text(group.jobProgress).font(.caption).foregroundColor(.secondary).lineLimit(1).fixedSize()
            Text("·").font(.caption).foregroundColor(.secondary)
            Text(group.elapsed).font(.caption.monospacedDigit()).foregroundColor(.secondary).lineLimit(1).fixedSize()
        }
    }

    // fix(#448): use DonutStatusView instead of raw SF Symbol icons
    @ViewBuilder private func jobRow(_ job: ActiveJob) -> some View {
        HStack(spacing: 6) {
            DonutStatusView(
                status: job.typedStatus,
                conclusion: job.conclusion,
                progress: job.progressFraction
            )
            .frame(width: 16, height: 16)
            Text(job.name)
                .font(DesignTokens.Fonts.mono)
                .foregroundColor(job.isDimmed ? .secondary : .primary)
                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
            Spacer()
            if let runner = job.runnerName {
                Text(runner).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.1)))
            }
            Text(job.elapsed).font(.caption.monospacedDigit()).foregroundColor(.secondary).fixedSize()
            Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Spacing.cardRadius, style: .continuous)
                .fill(DesignTokens.Colors.rowBackground)
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Spacing.cardRadius, style: .continuous)
                    .strokeBorder(DesignTokens.Colors.rowBorder, lineWidth: 0.5))
        )
        .contentShape(Rectangle())
    }

    // fix(#450): open SHA commit or PR on GitHub
    func openLabelOnGitHub() {
        guard let repo = group.repo else { return }
        let urlString: String
        if group.label.hasPrefix("#"), let number = Int(group.label.dropFirst()) {
            urlString = "https://github.com/\(repo)/pull/\(number)"
        } else {
            urlString = "https://github.com/\(repo)/commit/\(group.headSha)"
        }
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
// swiftlint:enable all
