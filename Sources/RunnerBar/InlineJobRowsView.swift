import SwiftUI
// swiftlint:disable colon opening_brace

// MARK: - TreeLineLeader
/// L-shaped tree-line drawn with Canvas.
/// fix(#455): barX is centred under the DonutStatusView dot, not at x=0.
/// The dot sits inside the job card which has .padding(.horizontal, RBSpacing.sm).
/// DonutStatusView size = 10 pt, so dot centre from card left edge
/// = RBSpacing.sm + 5. The card itself is offset from the HStack origin by
/// (treeLeader.width + HStack.spacing=4). We don't need to account for that
/// offset here because TreeLineLeader is sized to fill from the HStack origin;
/// barX just needs to sit at the same x as the dot centre within the leader frame.
/// The leader frame width = elbowWidth + 2.
/// Empirically, barX = 0 (left edge of leader) is where the outer workflow
/// green bar lives. For job-level leaders the bar stays at x=0 (flush with
/// the workflow bar). For step-level leaders we indent slightly.
private struct TreeLineLeader: View {
    let isLast: Bool
    /// Extra left indent — 0 for job rows, non-zero for step rows inside the card.
    var indent: CGFloat = 0

    private let lineColor = Color.secondary.opacity(0.3)
    private let barWidth: CGFloat = 1
    private let elbowWidth: CGFloat = 10
    private let arrowSize: CGFloat = 4

    var body: some View {
        Canvas { ctx, size in
            let midY = size.height / 2
            let barX = indent
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
/// Inline progress capsule. fix(#419): fill is rbBlue (in-progress = blue per spec).
private struct JobInlineProgress: View {
    let progress: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.rbTextTertiary.opacity(0.22)).frame(height: 3)
                Capsule()
                    .fill(Color.rbBlue)
                    .frame(width: max(3, geo.size.width * CGFloat(progress)), height: 3)
            }
        }
        .frame(height: 3)
    }
}

// MARK: - StepRowView
/// A single step row rendered inside the expanded job container.
/// Tapping navigates to StepLogView. Right-click shows step context menu.
/// fix(#455): No individual background — steps live inside the job card's shared background.
/// fix(#455): No Divider above/below — dividers removed; steps are visually separated by spacing only.
private struct StepRowView: View {
    let step: JobStep
    let job: ActiveJob
    let isLast: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // fix(#455): step tree-line indented to align under the job card's left padding.
            TreeLineLeader(isLast: isLast, indent: 0)
                .frame(maxHeight: .infinity)
            stepContent
        }
    }

    private var stepContent: some View {
        HStack(spacing: 6) {
            Text(step.conclusionIcon)
                .font(.system(size: 10))
                .foregroundColor(iconColor)
                .fixedSize()
            Text(step.name)
                .font(DesignTokens.Fonts.mono)
                .foregroundColor(Color.rbTextSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if step.status == "in_progress" || step.conclusion != nil {
                Text(step.elapsed)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(Color.rbTextTertiary)
                    .fixedSize()
            }
            // Steps have a chevron: they navigate to StepLogView.
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Color.rbTextTertiary)
        }
        .padding(.horizontal, RBSpacing.sm)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .stepContextMenu(step: step, job: job, onTap: onTap)
    }

    private var iconColor: Color {
        switch step.conclusion {
        case "success":              return Color.rbSuccess
        case "failure":              return Color.rbDanger
        case "skipped", "cancelled": return Color.rbTextTertiary
        default:                     return step.status == "in_progress" ? Color.rbBlue : Color.rbTextTertiary
        }
    }
}

// MARK: - JobRowCard
/// Single job row with optional inline step expansion.
/// fix(#455): the job header + step rows share ONE background container, per spec.
/// fix(#578): isExpanded owned by parent (expandedJobIDs) so ticks don't reset it.
/// fix(#455-lines): TreeLineLeader uses .frame(maxHeight: .infinity) so the vertical
///   bar extends through the full expanded card height, not just 28 pt.
/// fix(#455-align): HStack uses alignment: .top so the tree leader's vertical bar
///   starts flush with the top of the card. The bar then draws down to midY (isLast)
///   or full height (not last) covering the whole card naturally.
private struct JobRowCard: View {
    let job: ActiveJob
    let status: RBStatus
    let isLast: Bool
    let group: ActionGroup
    let isExpanded: Bool
    let onToggle: () -> Void
    let onStepTap: (JobStep) -> Void

    private var totalSteps: Int { job.steps.count }
    private var completedSteps: Int {
        job.steps.filter { $0.conclusion != nil || $0.status == "completed" }.count
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            // fix(#455-tree): maxHeight: .infinity so the vertical bar spans the full
            // expanded card, not just the header row height.
            TreeLineLeader(isLast: isLast && !isExpanded)
                .frame(maxHeight: .infinity)
                .padding(.top, 9) // visually centre bar against the job dot (28pt header / 2 - barWidth/2)
            // fix(#455): ONE background wraps both job header and steps together.
            VStack(alignment: .leading, spacing: 0) {
                jobHeader
                if isExpanded {
                    stepsContainer
                }
            }
            .background(
                RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous)
                    .fill(Color.rbSurfaceElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous)
                            .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous))
        }
        .padding(.vertical, 1)
        .jobContextMenu(job: job, group: group)
    }

    private var jobHeader: some View {
        HStack(spacing: 6) {
            DonutStatusView(status: status, progress: job.progressFraction ?? 0, size: 10)
            Text(job.name)
                .font(DesignTokens.Fonts.mono)
                .foregroundColor(job.isDimmed ? Color.rbTextTertiary : Color.rbTextSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if job.status == "in_progress" {
                JobInlineProgress(progress: job.progressFraction ?? 0)
                    .frame(width: 120)
            }
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
        .contentShape(Rectangle())
        .onTapGesture {
            guard totalSteps > 0 else { return }
            withAnimation(.easeInOut(duration: 0.15)) { onToggle() }
        }
    }

    // fix(#455-lines): no Dividers between steps — they create the visual noise seen
    // in the screenshots. Steps are separated by their own vertical padding only.
    // Also removed the Divider between jobHeader and stepsContainer.
    private var stepsContainer: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Thin separator between job header and first step — only a colour band, not a SwiftUI Divider.
            Color.rbBorderSubtle.frame(height: 0.5)
                .padding(.horizontal, RBSpacing.sm)
            ForEach(Array(job.steps.enumerated()), id: \.element.id) { index, step in
                StepRowView(
                    step: step,
                    job: job,
                    isLast: index == job.steps.count - 1,
                    onTap: { onStepTap(step) }
                )
            }
        }
        .padding(.horizontal, RBSpacing.xs)
        .padding(.bottom, RBSpacing.xs)
    }
}

// MARK: - InlineJobRowsView
/// Collapsed sub-row list shown beneath an ActionRowView when expanded.
///
/// Phase 4 spec (#420): inline job rows are read-only / passive context.
///
/// Expand behaviour (fix #419):
///   - Default (auto-expand for in-progress): shows ONLY in_progress jobs.
///   - After user taps the workflow row (fullExpand): shows ALL jobs.
///
/// #455: Each job row expands to show steps inside the same background container.
/// fix(#578): expandedJobIDs owned here so ticks don't reset expand state.
///
/// ⚠️ REGRESSION GUARD #377 — DO NOT REMOVE @EnvironmentObject popoverState:
/// This view must not render while the popover is hidden.
struct InlineJobRowsView: View {
    let group: ActionGroup
    let tick: Int
    var fullExpand: Bool = false
    var onStepTap: (ActiveJob, JobStep) -> Void = { _, _ in }

    @EnvironmentObject private var popoverState: PopoverOpenState
    @State private var expandedJobIDs: Set<Int> = []

    private var tickSnapshot: Int { tick }

    var body: some View {
        // ⚠️ REGRESSION GUARD #377 — do not remove this check.
        Group {
            if popoverState.isOpen {
                let jobs = fullExpand
                    ? group.jobs
                    : group.jobs.filter { $0.status == "in_progress" }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                        JobRowCard(
                            job: job,
                            status: jobStatus(for: job),
                            isLast: index == jobs.count - 1,
                            group: group,
                            isExpanded: expandedJobIDs.contains(job.id),
                            onToggle: {
                                if expandedJobIDs.contains(job.id) {
                                    expandedJobIDs.remove(job.id)
                                } else {
                                    expandedJobIDs.insert(job.id)
                                }
                            },
                            onStepTap: { step in onStepTap(job, step) }
                        )
                        .id("\(job.id)-\(tickSnapshot)")
                    }
                }
                .padding(.leading, RBSpacing.md)
                .padding(.trailing, RBSpacing.xs)
                .padding(.bottom, RBSpacing.xs)
            }
        }
    }

    private func jobStatus(for job: ActiveJob) -> RBStatus {
        if let conclusion = job.conclusion {
            switch conclusion {
            case "success":             return .success
            case "failure":             return .failed
            case "cancelled", "skipped": return .unknown
            default:                    return .unknown
            }
        }
        switch job.status {
        case "in_progress": return .inProgress
        case "queued":      return .queued
        default:            return .queued
        }
    }
}
