import SwiftUI

// MARK: - ActionRowView

/// A single row in the actions list showing one `ActionGroup`’s status,
/// title, progress donut, meta-trailing chips, and optional inline job rows.
struct ActionRowView: View {
    /// The action group this row represents.
    let group: ActionGroup
    /// Monotonically incrementing tick value used to force SwiftUI to re-evaluate
    /// time-dependent computed properties (elapsed, relative timestamps).
    let tick: Int
    /// Callback fired when the user taps the row to navigate to the detail view.
    let onSelect: () -> Void
    /// Callback fired when the user taps an inline job row.
    let onSelectJob: (ActiveJob, ActionGroup) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                indicatorBar
                Button(action: onSelect) { rowContent }.buttonStyle(.plain)
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundColor(.secondary).padding(.trailing, 12)
            }
            if group.groupStatus == .inProgress {
                InlineJobRowsView(group: group, tick: tick, onSelectJob: onSelectJob)
                    .padding(.leading, 6)
            }
        }
    }

    private var indicatorBar: some View {
        Capsule()
            .fill(indicatorColor)
            .frame(width: 3)
            .padding(.vertical, 6)
            .padding(.leading, 6)
            .padding(.trailing, 4)
    }

    private var rowContent: some View {
        _ = tick // ⚠️ TICK CONTRACT — DO NOT REMOVE
        return HStack(spacing: 6) {
            statusDonut
            RunnerTypeIcon(isLocal: group.isLocalGroup)
            Text(group.label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(group.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(group.isDimmed ? .secondary : .primary)
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
            Spacer()
            metaTrailing
        }
        .padding(.leading, 4).padding(.trailing, 4).padding(.vertical, 6)
        .background(rowBackground)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if group.groupStatus == .inProgress {
            RoundedRectangle(cornerRadius: 0).fill(Color.tokenBlue.opacity(0.05))
        } else if group.groupStatus == .completed {
            if group.conclusion == "success" {
                RoundedRectangle(cornerRadius: 0).fill(Color.tokenGreen.opacity(0.04))
            } else {
                RoundedRectangle(cornerRadius: 0).fill(Color.tokenRed.opacity(0.04))
            }
        }
    }

    @ViewBuilder
    private var statusDonut: some View {
        switch group.groupStatus {
        case .inProgress:
            // ⚠️ progressFraction is Double? — always coalesce to 0, do NOT remove ?? 0
            StatusDonut(state: .inProgress(group.progressFraction ?? 0))
        case .queued:
            StatusDonut(state: .inProgress(0.0))
        case .completed:
            if group.conclusion == "success" {
                StatusDonut(state: .success)
            } else {
                StatusDonut(state: .failed)
            }
        }
    }

    @ViewBuilder
    private var metaTrailing: some View {
        if let start = group.firstJobStartedAt {
            Text(RelativeTimeFormatter.string(from: start))
                .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        }
        Text(group.jobProgress)
            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        Text(group.elapsed)
            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        statusChip
    }

    @ViewBuilder
    private var statusChip: some View {
        switch group.groupStatus {
        case .inProgress:
            StatusBadge(label: "IN PROGRESS", color: .tokenBlue)
        case .queued:
            StatusBadge(label: "QUEUED", color: .tokenBlue)
        case .completed:
            StatusBadge(
                label: group.conclusion == "success" ? "SUCCESS" : "FAILED",
                color: group.conclusion == "success" ? .tokenGreen : .tokenRed
            )
        }
    }

    private var indicatorColor: Color {
        switch group.groupStatus {
        case .inProgress: return .tokenBlue
        case .queued:     return .tokenBlue.opacity(0.6)
        case .completed:
            if group.isDimmed { return .gray.opacity(0.3) }
            return group.conclusion == "success" ? .tokenGreen : .tokenRed
        }
    }
}
