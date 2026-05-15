import SwiftUI

// MARK: - InlineJobRowsView
/// Collapsed sub-row list shown beneath an ActionRowView when expanded.
///
/// Phase 4 spec (#420): inline `↳` job rows are **read-only / passive context**.
/// They have no `>` chevron and no tap handler — navigation to a job detail view
/// happens only from ActionDetailView, not from the popover inline rows.
/// Therefore this view intentionally has no `onSelectJob` callback.
///
/// ⚠️ REGRESSION GUARD #377 — DO NOT REMOVE `@EnvironmentObject popoverState`:
/// This view must not render (and must not drive any cap/state mutations) while
/// the popover is hidden. Removing the `isOpen` guard re-introduces the
/// cap-mutation-while-hidden bug fixed in #377.
struct InlineJobRowsView: View {
    let group: ActionGroup
    let tick: Int

    @EnvironmentObject private var popoverState: PopoverOpenState

    var body: some View {
        // ⚠️ REGRESSION GUARD #377 — do not remove this check.
        guard popoverState.isOpen else { return AnyView(EmptyView()) }
        // ⚠️ TICK CONTRACT — tick drives live elapsed refresh. DO NOT REMOVE.
        _ = tick
        return AnyView(
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
        )
    }

    // MARK: - Row

    private func jobRow(_ job: ActiveJob) -> some View {
        VStack(alignment: .leading, spacing: 2) {
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
            // Phase 4 spec (#420): keep horizontal progress bar in job sub-rows.
            if job.status == "in_progress" {
                let progress = job.progressFraction ?? 0
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Color.rbBlue)
                    .frame(height: 2)
                    .padding(.leading, 16)
                    .padding(.trailing, RBSpacing.xs)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func jobStatus(for job: ActiveJob) -> RBStatus {
        if let conclusion = job.conclusion {
            switch conclusion {
            case "success": return .success
            case "failure": return .failed
            case "cancelled": return .unknown
            case "skipped": return .unknown
            default: return .unknown
            }
        }
        switch job.status {
        case "in_progress": return .inProgress
        case "queued": return .queued
        default: return .queued
        }
    }
}
