import SwiftUI

// MARK: - TreeLineLeader
/// L-shaped tree-line with an arrowhead drawn with Canvas.
/// A vertical bar runs from the top of the row to the mid-point, then a short
/// horizontal elbow terminates with a filled arrowhead pointing right.
private struct TreeLineLeader: View {
    let isLast: Bool

    private let lineColor = Color.secondary.opacity(0.3)
    private let barWidth: CGFloat = 1
    private let elbowWidth: CGFloat = 10
    private let arrowSize: CGFloat = 4

    var body: some View {
        Canvas { ctx, size in
            let midY = size.height / 2
            let barX: CGFloat = 0

            // Vertical bar — stop at midY for last item, full height otherwise
            var vertPath = Path()
            vertPath.move(to: CGPoint(x: barX, y: 0))
            vertPath.addLine(to: CGPoint(x: barX, y: isLast ? midY : size.height))
            ctx.stroke(vertPath, with: .color(lineColor), lineWidth: barWidth)

            // Horizontal elbow, stopping short of the arrowhead
            let arrowTip = CGPoint(x: barX + elbowWidth, y: midY)
            var elbowPath = Path()
            elbowPath.move(to: CGPoint(x: barX, y: midY))
            elbowPath.addLine(to: CGPoint(x: arrowTip.x - arrowSize, y: midY))
            ctx.stroke(elbowPath, with: .color(lineColor), lineWidth: barWidth)

            // Filled arrowhead pointing right
            var arrow = Path()
            arrow.move(to: arrowTip)
            arrow.addLine(to: CGPoint(x: arrowTip.x - arrowSize, y: midY - arrowSize / 2))
            arrow.addLine(to: CGPoint(x: arrowTip.x - arrowSize, y: midY + arrowSize / 2))
            arrow.closeSubpath()
            ctx.fill(arrow, with: .color(lineColor))
        }
        // Width must accommodate elbow + arrowhead tip
        .frame(width: elbowWidth + 2)
    }
}

// MARK: - InlineJobRowsView
/// Collapsed sub-row list shown beneath an ActionRowView when expanded.
///
/// Phase 4 spec (#420): inline job rows are **read-only / passive context**.
/// No `>` chevron and no tap handler — navigation lives in ActionDetailView only.
///
/// Fix list applied here:
///  1. Each job card has its own RoundedRectangle background + stroke border.
///  2. Progress bar is laid out inline in the same HStack as the text row.
///  3. in_progress jobs use rbWarning (yellow) not rbBlue.
///  4. "+ N more" button removed.
///  5. Step count (e.g. "20/21") added at the trailing edge.
///  6. Tree-line arrows added (filled arrowhead on elbow).
///
/// ⚠️ REGRESSION GUARD #377 — DO NOT REMOVE `@EnvironmentObject popoverState`:
/// This view must not render (or drive any cap/state mutations) while the
/// popover is hidden. Removing the `isOpen` guard re-introduces the
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
        let jobs = group.jobs
        return AnyView(
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                    jobRow(job, isLast: index == jobs.count - 1)
                }
            }
            .padding(.leading, RBSpacing.md)
            .padding(.trailing, RBSpacing.xs)
            .padding(.bottom, RBSpacing.xs)
        )
    }

    // MARK: - Row

    private func jobRow(_ job: ActiveJob, isLast: Bool) -> some View {
        let status = jobStatus(for: job)
        let progress = job.progressFraction ?? 0
        let completedSteps = job.steps.filter { $0.conclusion != nil || $0.status == "completed" }.count
        let totalSteps = job.steps.count

        return HStack(alignment: .center, spacing: 4) {
            // Tree-line leader with arrow
            TreeLineLeader(isLast: isLast)
                .frame(height: 28)

            // Card content
            HStack(spacing: 6) {
                // Status donut
                DonutStatusView(
                    status: status,
                    progress: progress,
                    size: 10
                )

                // Job name
                Text(job.name)
                    .font(DesignTokens.Fonts.mono)
                    .foregroundColor(
                        job.isDimmed ? Color.rbTextTertiary : Color.rbTextSecondary
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                // Inline progress bar — only for in_progress jobs
                if job.status == "in_progress" {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.rbTextTertiary.opacity(0.22))
                                .frame(height: 3)
                            Capsule()
                                // fix(4): yellow for in-progress, not blue
                                .fill(Color.rbWarning)
                                .frame(width: max(3, geo.size.width * CGFloat(progress)), height: 3)
                        }
                    }
                    .frame(height: 3)
                }

                Spacer(minLength: 4)

                // Step count (fix 6): e.g. "20/21" — only when steps are known
                if totalSteps > 0 {
                    Text("\(completedSteps)/\(totalSteps)")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(Color.rbTextTertiary)
                        .fixedSize()
                }

                // Elapsed time
                if job.startedAt != nil {
                    Text(job.elapsed)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(Color.rbTextTertiary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, RBSpacing.sm)
            .padding(.vertical, 5)
            // fix(1): individual card background + border stroke per job row
            .background(
                RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous)
                    .fill(Color.rbSurfaceElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous)
                            .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5)
                    )
            )
        }
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
        // fix(3): in_progress uses .inProgress whose color is rbWarning (yellow)
        // after we update DesignTokens.swift below.
        case "in_progress": return .inProgress
        case "queued": return .queued
        default: return .queued
        }
    }
}
