import SwiftUI

// MARK: - TreeLineLeader
/// L-shaped tree-line with a filled arrowhead drawn with Canvas.
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
            var vertPath = Path()
            vertPath.move(to: CGPoint(x: barX, y: 0))
            vertPath.addLine(to: CGPoint(x: barX, y: isLast ? midY : size.height))
            ctx.stroke(vertPath, with: .color(lineColor), lineWidth: barWidth)
            let arrowTip = CGPoint(x: barX + elbowWidth, y: midY)
            var elbowPath = Path()
            elbowPath.move(to: CGPoint(x: barX, y: midY))
            elbowPath.addLine(to: CGPoint(x: arrowTip.x - arrowSize, y: midY))
            ctx.stroke(elbowPath, with: .color(lineColor), lineWidth: barWidth)
            var arrow = Path()
            arrow.move(to: arrowTip)
            arrow.addLine(to: CGPoint(x: arrowTip.x - arrowSize, y: midY - arrowSize / 2))
            arrow.addLine(to: CGPoint(x: arrowTip.x - arrowSize, y: midY + arrowSize / 2))
            arrow.closeSubpath()
            ctx.fill(arrow, with: .color(lineColor))
        }
        .frame(width: elbowWidth + 2)
    }
}

// MARK: - JobInlineProgress
/// Inline progress capsule rendered in the same HStack row as the job name.
/// fix(#419): fill is rbBlue (in-progress = blue per spec), not rbWarning.
private struct JobInlineProgress: View {
    let progress: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.rbTextTertiary.opacity(0.22)).frame(height: 3)
                Capsule()
                    .fill(Color.rbBlue)   // fix(#419): blue, not yellow
                    .frame(width: max(3, geo.size.width * CGFloat(progress)), height: 3)
            }
        }
        .frame(height: 3)
    }
}

// MARK: - JobRowCard
/// Single job row: tree-line leader + card background with status, name,
/// optional inline progress, step count, and elapsed time.
private struct JobRowCard: View {
    let job: ActiveJob
    let status: RBStatus
    let isLast: Bool

    private var completedSteps: Int {
        job.steps.filter { $0.conclusion != nil || $0.status == "completed" }.count
    }
    private var totalSteps: Int { job.steps.count }

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            TreeLineLeader(isLast: isLast).frame(height: 28)
            cardContent
        }
        .padding(.vertical, 1)
    }

    private var cardContent: some View {
        HStack(spacing: 6) {
            DonutStatusView(status: status, progress: job.progressFraction ?? 0, size: 10)
            Text(job.name)
                .font(DesignTokens.Fonts.mono)
                .foregroundColor(job.isDimmed ? Color.rbTextTertiary : Color.rbTextSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if job.status == "in_progress" {
                JobInlineProgress(progress: job.progressFraction ?? 0)
            }
            Spacer(minLength: 4)
            if totalSteps > 0 {
                Text("\(completedSteps)/\(totalSteps)")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(Color.rbTextTertiary)
                    .fixedSize()
            }
            if job.startedAt != nil {
                Text(job.elapsed)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(Color.rbTextTertiary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, RBSpacing.sm)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous)
                .fill(Color.rbSurfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous)
                        .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5)
                )
        )
    }
}

// MARK: - InlineJobRowsView
/// Collapsed sub-row list shown beneath an ActionRowView when expanded.
///
/// Phase 4 spec (#420): inline job rows are **read-only / passive context**.
/// No `>` chevron and no tap handler — navigation lives in ActionDetailView only.
///
/// Expand behaviour (fix #419):
///   - Default (auto-expand for in-progress): shows ONLY in_progress jobs.
///   - After user taps the pill (fullExpand): shows ALL jobs.
///
/// ⚠️ REGRESSION GUARD #377 — DO NOT REMOVE `@EnvironmentObject popoverState`:
/// This view must not render (or drive any cap/state mutations) while the
/// popover is hidden. Removing the `isOpen` guard re-introduces the
/// cap-mutation-while-hidden bug fixed in #377.
struct InlineJobRowsView: View {
    let group: ActionGroup
    let tick: Int
    /// When false (default auto-expand), only in_progress jobs are shown.
    /// When true (user tapped pill), all jobs are shown.
    var fullExpand: Bool = false

    @EnvironmentObject private var popoverState: PopoverOpenState

    var body: some View {
        // ⚠️ REGRESSION GUARD #377 — do not remove this check.
        guard popoverState.isOpen else { return AnyView(EmptyView()) }
        // ⚠️ TICK CONTRACT — tick drives live elapsed refresh. DO NOT REMOVE.
        _ = tick
        // fix(#419): show only in_progress jobs in default expand; all jobs when fullExpand.
        let jobs = fullExpand
            ? group.jobs
            : group.jobs.filter { $0.status == "in_progress" }
        return AnyView(
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                    JobRowCard(
                        job: job,
                        status: jobStatus(for: job),
                        isLast: index == jobs.count - 1
                    )
                }
            }
            .padding(.leading, RBSpacing.md)
            .padding(.trailing, RBSpacing.xs)
            .padding(.bottom, RBSpacing.xs)
        )
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
