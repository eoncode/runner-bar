import SwiftUI

// MARK: - InlineJobRowsView
/// Collapsed sub-row list shown beneath an ActionRowView when expanded.
/// Phase 4 spec (#420): each job row must retain a progress indicator.
/// Fix: DonutStatusView (10 pt) replaces the removed PieProgressDot,
/// preserving the horizontal progress bar requirement from the spec.
struct InlineJobRowsView: View {
    let group: ActionGroup
    let tick: Int

    var body: some View {
        // ⚠️ TICK CONTRACT — tick drives live elapsed refresh. DO NOT REMOVE.
        _ = tick
        VStack(alignment: .leading, spacing: 0) {
            ForEach(group.jobs.prefix(5)) { job in
                jobRow(job)
            }
            if group.jobs.count > 5 {
                Text("+ \(group.jobs.count - 5) more…")
                    .font(.caption2)
                    .foregroundColor(Color.rbTextTertiary)
                    .padding(.leading, RBSpacing.xl)
                    .padding(.vertical, 2)
            }
        }
        .padding(.leading, RBSpacing.sm)
        .padding(.trailing, RBSpacing.xs)
        .padding(.bottom, RBSpacing.xs)
    }

    // MARK: - Row

    private func jobRow(_ job: ActiveJob) -> some View {
        HStack(spacing: 6) {
            // Phase 4 spec #420: keep progress indicator in job sub-rows.
            // DonutStatusView replaces the old PieProgressDot at 10 pt.
            DonutStatusView(
                status: jobStatus(for: job),
                progress: job.progressFraction ?? 0,
                size: 10
            )

            Text(job.name)
                .font(DesignTokens.Fonts.mono)
                .foregroundColor(job.isDimmed ? Color.rbTextTertiary : Color.rbTextSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Spacer()

            if job.startedAt != nil {
                Text(job.elapsed)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(Color.rbTextTertiary)
                    .fixedSize()
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func jobStatus(for job: ActiveJob) -> RBStatus {
        if let conclusion = job.conclusion {
            switch conclusion {
            case "success":   return .success
            case "failure":   return .failed
            case "cancelled": return .unknown
            case "skipped":   return .unknown
            default:          return .unknown
            }
        }
        switch job.status {
        case "in_progress": return .inProgress
        case "queued":      return .queued
        default:            return .queued
        }
    }
}
