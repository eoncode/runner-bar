import SwiftUI

// MARK: - TreeLineLeader
/// L-shaped tree-line drawn with Canvas: a vertical bar from the top down to
/// the mid-point of the row, then a short horizontal elbow to the right.
/// Matches the reference screenshot indentation style (↳ leader per job row).
private struct TreeLineLeader: View {
    /// Total height of the row (passed in from GeometryReader).
    let rowHeight: CGFloat
    /// Whether this is the last job in the list (draws a corner, not a T).
    let isLast: Bool

    private let lineColor = Color.secondary.opacity(0.3)
    private let barWidth: CGFloat = 1
    // fix(#419): wider elbow so the └─ character reads clearly
    private let elbowWidth: CGFloat = 12

    var body: some View {
        Canvas { ctx, size in
            let midY = size.height / 2
            // Vertical line left-aligned inside frame.
            // Non-last rows: full height so lines connect continuously across rows.
            // Last row: only to midY (creates the └ corner).
            let barX: CGFloat = 0
            var vertPath = Path()
            vertPath.move(to: CGPoint(x: barX, y: 0))
            vertPath.addLine(to: CGPoint(x: barX, y: isLast ? midY : size.height))
            ctx.stroke(vertPath, with: .color(lineColor), lineWidth: barWidth)

            // Horizontal elbow at midY
            var elbowPath = Path()
            elbowPath.move(to: CGPoint(x: barX, y: midY))
            elbowPath.addLine(to: CGPoint(x: barX + elbowWidth, y: midY))
            ctx.stroke(elbowPath, with: .color(lineColor), lineWidth: barWidth)
        }
        .frame(width: elbowWidth + 2)
    }
}

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
    /// The action group whose jobs are rendered as inline sub-rows.
    let group: ActionGroup
    /// A monotonically-increasing tick value used to refresh elapsed timers.
    let tick: Int

    @EnvironmentObject private var popoverState: PopoverOpenState

    /// Renders job sub-rows, guarded by `popoverState.isOpen` to prevent cap mutations while hidden.
    var body: some View {
        // ⚠️ REGRESSION GUARD #377 — do not remove this check.
        guard popoverState.isOpen else { return AnyView(EmptyView()) }
        // ⚠️ TICK CONTRACT — tick drives live elapsed refresh. DO NOT REMOVE.
        _ = tick
        let jobs = Array(group.jobs.prefix(5))
        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                    jobRow(job, isLast: index == jobs.count - 1 && group.jobs.count <= 5)
                }
                if group.jobs.count > 5 {
                    HStack(spacing: 4) {
                        // Continuation line for the overflow label
                        TreeLineLeader(rowHeight: 20, isLast: true)
                            .frame(height: 20)
                        Text("+ \(group.jobs.count - 5) more…")
                            .font(.caption2)
                            .foregroundColor(Color.rbTextTertiary)
                    }
                    .padding(.leading, RBSpacing.md)
                    .padding(.vertical, 2)
                }
            }
            // fix(#419): subtle inner rounded background that visually nests
            // the job rows inside the parent group card.
            .background(
                RoundedRectangle(cornerRadius: RBRadius.small - 2, style: .continuous)
                    .fill(Color.rbSurface.opacity(0.45))
                    .padding(.horizontal, RBSpacing.xs)
            )
            // Left indent: aligns tree-line leader with the status indicator bar
            .padding(.leading, RBSpacing.md)
            .padding(.trailing, RBSpacing.xs)
            .padding(.bottom, RBSpacing.xs)
        )
    }

    // MARK: - Row

    private func jobRow(_ job: ActiveJob, isLast: Bool) -> some View {
        GeometryReader { geo in
            HStack(alignment: .top, spacing: 4) {
                // L-shaped tree-line leader
                TreeLineLeader(rowHeight: geo.size.height, isLast: isLast)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
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
                    if job.status == "in_progress" {
                        let progress = job.progressFraction ?? 0
                        // fix(#419): custom capsule progress bar matching reference design —
                        // dark muted track with a colored fill, not the stock ProgressView.
                        GeometryReader { barGeo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.rbTextTertiary.opacity(0.22))
                                    .frame(height: 3)
                                Capsule()
                                    .fill(Color.rbBlue)
                                    .frame(
                                        width: max(3, barGeo.size.width * CGFloat(progress)),
                                        height: 3
                                    )
                            }
                        }
                        .frame(height: 3)
                        .padding(.leading, 16)
                        .padding(.trailing, RBSpacing.xs)
                    }
                }
            }
            // fix(#419): per-row rounded background so each job row reads as
            // a distinct item inside the expanded card, matching the reference.
            .background(
                RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous)
                    .fill(Color.rbSurfaceElevated.opacity(0.55))
            )
            .padding(.horizontal, RBSpacing.xs)
        }
        // Fixed height per row so GeometryReader reports a stable value
        .frame(height: 28)
        .padding(.vertical, 1)
    }

    // MARK: - Helpers

    private func jobStatus(for job: ActiveJob) -> RBStatus {
        if let conclusion = job.conclusion {
            switch conclusion {
            case "success": return .success
            case "failure": return .failed
            case "cancelled", "skipped": return .unknown
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
