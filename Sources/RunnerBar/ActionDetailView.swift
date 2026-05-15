// swiftlint:disable all
import AppKit
import SwiftUI
// swiftlint:disable vertical_whitespace_opening_braces

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

    private var headerBar: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.caption)
                    Text("Actions").font(.caption)
                }.foregroundColor(.secondary).fixedSize()
            }.buttonStyle(.plain)
            Spacer(minLength: 8)
            if let urlString = group.htmlUrl, let url = URL(string: urlString) {
                Button(action: { NSWorkspace.shared.open(url) }) {
                    HStack(spacing: 3) {
                        Image(systemName: "safari").font(.caption)
                        Text("GitHub").font(.caption)
                    }.foregroundColor(.secondary).fixedSize()
                }.buttonStyle(.plain).help("Open repo on GitHub")
            }
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

    @ViewBuilder private func jobRow(_ job: ActiveJob) -> some View {
        HStack(spacing: 6) {
            Image(systemName: jobIcon(job)).foregroundColor(jobColor(job)).frame(width: 14, alignment: .center)
            Text(job.name)
                .font(RBFont.mono)
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

    private func jobIcon(_ job: ActiveJob) -> String {
        switch job.conclusion {
        case "success": return "checkmark.circle.fill"
        case "failure": return "xmark.circle.fill"
        case "skipped", "cancelled": return "minus.circle"
        default: return job.status == "in_progress" ? "circle.dotted" : "circle"
        }
    }

    private func jobColor(_ job: ActiveJob) -> Color {
        switch job.conclusion {
        case "success": return .rbSuccess
        case "failure": return .rbDanger
        default: return job.status == "in_progress" ? .rbBlue : .secondary
        }
    }
}
// swiftlint:enable all
