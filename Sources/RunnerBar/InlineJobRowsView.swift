import SwiftUI
// swiftlint:disable colon opening_brace

// MARK: - TreeLineLeader
/// L-shaped tree-line drawn with Canvas. Used for both job rows and step rows.
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
/// A single step row rendered beneath an expanded JobRowCard.
/// Tapping navigates to StepLogView. Right-click shows step context menu.
private struct StepRowView: View {
    let step: JobStep
    let isLast: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            TreeLineLeader(isLast: isLast).frame(height: 24)
            stepCard
        }
        .padding(.vertical, 1)
    }

    private var stepCard: some View {
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
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Color.rbTextTertiary)
        }
        .padding(.horizontal, RBSpacing.sm)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous)
                .fill(Color.rbSurfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous)
                        .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .stepContextMenu(step: step)
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
/// Single job row: tree-line + card with status, name, progress, step count, elapsed.
/// Tapping expands/collapses inline step rows (Phase 1 of #455).
/// Right-click attaches job-level context menu via .jobContextMenu.
private struct JobRowCard: View {
    let job: ActiveJob
    let status: RBStatus
    let isLast: Bool
    let group: ActionGroup
    /// Bubble step tap up to AppDelegate navigation.
    let onStepTap: (JobStep) -> Void

    @State private var isExpanded = false

    private var totalSteps: Int { job.steps.count }
    private var completedSteps: Int {
        job.steps.filter { $0.conclusion != nil || $0.status == "completed" }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Job row ─────────────────────────────────────────────────────
            HStack(alignment: .center, spacing: 4) {
                // isLast=false while expanded so vertical line continues to steps
                TreeLineLeader(isLast: isLast && !isExpanded).frame(height: 28)
                cardContent
            }
            .padding(.vertical, 1)
            .jobContextMenu(job: job, group: group)
            .contentShape(Rectangle())
            .onTapGesture {
                guard totalSteps > 0 else { return }
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            }

            // ── Step rows (expanded) ────────────────────────────────────────
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(job.steps.enumerated()), id: \.element.id) { index, step in
                        StepRowView(
                            step: step,
                            isLast: index == job.steps.count - 1,
                            onTap: { onStepTap(step) }
                        )
                    }
                }
                .padding(.leading, RBSpacing.md)
                .padding(.trailing, RBSpacing.xs)
                .padding(.bottom, RBSpacing.xs)
            }
        }
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
            // Chevron: only when steps exist; rotates when expanded.
            if totalSteps > 0 {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color.rbTextTertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.15), value: isExpanded)
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
/// Phase 4 spec (#420): inline job rows are read-only / passive context.
///
/// Expand behaviour (fix #419):
///   - Default (auto-expand for in-progress): shows ONLY in_progress jobs.
///   - After user taps the workflow row (fullExpand): shows ALL jobs.
///
/// #455 Phase 1: Each job row expands inline to show step rows.
///   Tapping a step calls onStepTap, routed to StepLogView via AppDelegate.
///
/// ⚠️ REGRESSION GUARD #377 — DO NOT REMOVE @EnvironmentObject popoverState:
/// This view must not render while the popover is hidden.
struct InlineJobRowsView: View {
    let group: ActionGroup
    let tick: Int
    /// false = only in_progress jobs shown (auto-compact). true = all jobs.
    var fullExpand: Bool = false
    /// Called when user taps a step row — routed to StepLogView.
    var onStepTap: (ActiveJob, JobStep) -> Void = { _, _ in }

    @EnvironmentObject private var popoverState: PopoverOpenState

    // ⚠️ TICK CONTRACT — tick drives live elapsed refresh. DO NOT REMOVE.
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
                            onStepTap: { step in onStepTap(job, step) }
                        )
                    }
                }
                .padding(.leading, RBSpacing.md)
                .padding(.trailing, RBSpacing.xs)
                .padding(.bottom, RBSpacing.xs)
                .id(tickSnapshot)
            }
        }
    }

    // MARK: - Helpers

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
