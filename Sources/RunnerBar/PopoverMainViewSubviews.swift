import SwiftUI

// MARK: - SectionHeaderLabel
/// Uppercase section header label used throughout the popover (e.g. "ACTIONS").
struct SectionHeaderLabel: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

// MARK: - PopoverHeaderView
/// Header row: system stats left, settings + close right.
/// ⚠️ Auth green dot removed — auth status lives in Settings > Account only (#10).
struct PopoverHeaderView: View {
    let stats: SystemStats
    let isAuthenticated: Bool
    let onSelectSettings: () -> Void
    let onSignIn: () -> Void

    var cpuHistory: [Double] = []
    var memHistory: [Double] = []
    var diskHistory: [Double] = []

    var body: some View {
        HStack(spacing: DesignTokens.Layout.statGroupGap) {
            statGroup(
                label: "CPU",
                valueText: String(format: "%.1f%%", stats.cpuPct),
                pct: stats.cpuPct,
                history: cpuHistory
            )
            statDivider
            statGroup(
                label: "MEM",
                valueText: String(format: "%.1f/%.1fGB", stats.memUsedGB, stats.memTotalGB),
                pct: stats.memTotalGB > 0 ? (stats.memUsedGB / stats.memTotalGB) * 100 : 0,
                history: memHistory
            )
            statDivider
            diskGroup
            Spacer()
            if !isAuthenticated {
                Button(
                    action: onSignIn,
                    label: {
                        HStack(spacing: 4) {
                            Circle().fill(Color.orange).frame(width: 7, height: 7)
                            Text("Sign in")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                )
                .buttonStyle(.plain)
                .help("Sign in with GitHub")
            }
            Button(
                action: onSelectSettings,
                label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13)).foregroundColor(.secondary)
                }
            )
            .buttonStyle(.plain).help("Settings")
            Button(
                action: { NSApplication.shared.terminate(nil) },
                label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                }
            )
            .buttonStyle(.plain).help("Quit RunnerBar")
        }
        .padding(.horizontal, DesignTokens.Layout.panelHPad)
        .padding(.top, DesignTokens.Layout.panelVPad)
        .padding(.bottom, 8)
    }

    private var diskGroup: some View {
        let total = stats.diskTotalGB
        let used = stats.diskUsedGB
        let free = max(0, total - used)
        let usedPct = total > 0 ? (used / total) * 100 : 0
        let freePct = total > 0 ? (free / total) * 100 : 0
        let valueStr = String(format: "%d/%dGB", Int(used.rounded()), Int(total.rounded()))
        let freeStr = String(format: "%dGB %d%%", Int(free.rounded()), Int(freePct.rounded()))
        return HStack(spacing: DesignTokens.Layout.statInnerGap) {
            Text("DISK")
                .font(DesignTokens.Font.statLabel)
                .foregroundColor(DesignTokens.Color.labelSecondary)
                .lineLimit(1)
            SparklineView(samples: diskHistory, pct: usedPct)
            Text(valueStr)
                .font(DesignTokens.Font.statValue)
                .foregroundColor(DesignTokens.Color.statColor(for: usedPct))
                .lineLimit(1)
            Text(freeStr)
                .font(DesignTokens.Font.monoXSmall)
                .foregroundColor(DesignTokens.Color.statColor(for: usedPct))
                .padding(.horizontal, 8).padding(.vertical, 1)
                .background(
                    Capsule()
                        .fill(DesignTokens.Color.statColor(for: usedPct).opacity(0.15))
                        .overlay(
                            Capsule().strokeBorder(
                                DesignTokens.Color.statColor(for: usedPct).opacity(0.4),
                                lineWidth: 1
                            )
                        )
                )
                .lineLimit(1)
        }
    }

    private func statGroup(label: String, valueText: String, pct: Double, history: [Double]) -> some View {
        HStack(spacing: DesignTokens.Layout.statInnerGap) {
            Text(label)
                .font(DesignTokens.Font.statLabel)
                .foregroundColor(DesignTokens.Color.labelSecondary)
                .lineLimit(1)
            SparklineView(samples: history, pct: pct)
            Text(valueText)
                .font(DesignTokens.Font.statValue)
                .foregroundColor(DesignTokens.Color.statColor(for: pct))
                .lineLimit(1)
        }
    }

    private var statDivider: some View {
        Rectangle()
            .fill(DesignTokens.Color.separator)
            .frame(width: DesignTokens.Layout.separatorThickness, height: 16)
    }
}

// MARK: - SparklineView
/// Renders a sparkline graph with gradient fill for a stat history array.
struct SparklineView: View {
    let samples: [Double]
    let pct: Double

    private var color: Color { DesignTokens.Color.statColor(for: pct) }

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else { return }
            let pts = points(in: size)

            var fillPath = Path()
            fillPath.move(to: CGPoint(x: 0, y: size.height))
            for point in pts { fillPath.addLine(to: point) }
            fillPath.addLine(to: CGPoint(x: size.width, y: size.height))
            fillPath.closeSubpath()
            context.fill(
                fillPath,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: color.opacity(0.55), location: 0),
                        .init(color: color.opacity(0), location: 1)
                    ]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            var basePath = Path()
            basePath.move(to: CGPoint(x: 0, y: size.height))
            basePath.addLine(to: CGPoint(x: size.width, y: size.height))
            context.stroke(
                basePath,
                with: .color(color.opacity(0.25)),
                style: StrokeStyle(lineWidth: 0.5)
            )

            var linePath = Path()
            linePath.move(to: pts[0])
            for point in pts.dropFirst() { linePath.addLine(to: point) }
            context.stroke(
                linePath,
                with: .color(color),
                style: StrokeStyle(
                    lineWidth: DesignTokens.Layout.sparklineStroke,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
        .opacity(0.85)
        .frame(width: DesignTokens.Layout.sparklineWidth, height: DesignTokens.Layout.sparklineHeight)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let count = samples.count
        return samples.enumerated().map { idx, val in
            let xPos = size.width * CGFloat(idx) / CGFloat(count - 1)
            let yPos = size.height * (1 - CGFloat(min(max(val, 0), 1))) * 0.85 + 2
            return CGPoint(x: xPos, y: yPos)
        }
    }
}

// MARK: - RunnerTypeIcon
private struct RunnerTypeIcon: View {
    let isLocal: Bool?
    var body: some View {
        if let local = isLocal {
            Image(systemName: local ? "desktopcomputer" : "cloud")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .accessibilityLabel(local ? "Local runner" : "Cloud runner")
                .fixedSize()
        }
    }
}

// MARK: - PopoverLocalRunnerRow
/// Displays busy local runners as elevated bordered cards with CPU/MEM pill badges.
struct PopoverLocalRunnerRow: View {
    let runners: [Runner]

    var body: some View {
        let busy = runners.filter { $0.busy }
        if !busy.isEmpty { runnerList(busy) }
    }

    @ViewBuilder
    private func runnerList(_ busy: [Runner]) -> some View {
        VStack(spacing: 4) {
            ForEach(busy.prefix(3)) { runner in
                RunnerCardRow(runner: runner)
            }
            if busy.count > 3 {
                Text("+ \(busy.count - 3) more…")
                    .font(DesignTokens.Font.monoXSmall)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                    .padding(.horizontal, DesignTokens.Layout.panelHPad).padding(.vertical, 2)
            }
        }
        .padding(.horizontal, DesignTokens.Layout.sectionInset)
        .padding(.vertical, 6)
        Divider()
    }
}

// MARK: - RunnerCardRow
/// Elevated card row for a single busy runner with CPU/MEM pill badges.
struct RunnerCardRow: View {
    let runner: Runner

    var body: some View {
        HStack(spacing: DesignTokens.Layout.runnerRowGap) {
            // ⚠️ Use statusOrange (not .yellow) — consistent with DesignTokens color system.
            // In-progress runners are "active/busy" which maps to the orange warning token,
            // not the system yellow which is semantically undefined and not adaptive.
            Circle()
                .fill(DesignTokens.Color.statusOrange)
                .frame(width: 8, height: 8)
                .shadow(color: DesignTokens.Color.statusOrange.opacity(0.6), radius: 3)
            Text(runner.name)
                .font(DesignTokens.Font.monoBody)
                .foregroundColor(.primary)
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
            Spacer()
            if let metrics = runner.metrics {
                MetricPill(label: "CPU", value: String(format: "%.1f%%", metrics.cpu))
                MetricPill(label: "MEM", value: String(format: "%.1f%%", metrics.mem))
            } else {
                MetricPill(label: "CPU", value: "—")
                MetricPill(label: "MEM", value: "—")
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DesignTokens.Color.labelTertiary)
        }
        .padding(.horizontal, DesignTokens.Layout.rowHPad)
        .padding(.vertical, DesignTokens.Layout.rowVPad)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Layout.cardRadius)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Layout.cardRadius)
                        .strokeBorder(
                            DesignTokens.Color.cardBorder,
                            lineWidth: DesignTokens.Layout.cardBorderWidth
                        )
                )
        )
        .contentShape(Rectangle())
    }
}

// MARK: - MetricPill
/// Pill-shaped CPU/MEM metric badge for runner card rows.
struct MetricPill: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(DesignTokens.Font.monoXSmall)
                .foregroundColor(DesignTokens.Color.labelSecondary)
            Text(value)
                .font(DesignTokens.Font.monoXSmall)
                .foregroundColor(.primary.opacity(0.75))
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(
            Capsule()
                .fill(DesignTokens.Color.pillBg)
                .overlay(Capsule().strokeBorder(DesignTokens.Color.pillBorder, lineWidth: 0.75))
        )
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - ActionRowView
/// Action group row — Phase 4 redesign:
/// - Left vertical indicator bar toggles expand/collapse of inline job rows
/// - Tapping the row body navigates to ActionDetailView as before
/// - StatusDonutView replaces PieProgressDot
/// - Faint per-row status tint background
/// - chevron.right always points right; rotates 90° when expanded
/// - Meta text in monospaced font
/// - InlineJobRowsView is rendered inside this view so `expanded` can be
///   passed directly as `showAll:` — keeping the toggle wired end-to-end.
struct ActionRowView: View {
    let group: ActionGroup
    let tick: Int
    let onSelect: () -> Void
    var onSelectJob: ((ActiveJob, ActionGroup) -> Void)?

    /// Controls whether the inline job list shows all jobs (true) or only in-progress (false).
    /// Toggled exclusively by tapping the left indicator bar.
    @State private var expanded = false

    private var accentColor: Color {
        DesignTokens.Color.actionColor(status: group.groupStatus, conclusion: group.conclusion)
    }

    var body: some View {
        // ⚠️ TICK CONTRACT — DO NOT REMOVE.
        // ❌ NEVER remove this line.
        _ = tick
        return VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                Rectangle().fill(accentColor.opacity(0.06))

                HStack(spacing: 0) {
                    Button(action: { expanded.toggle() }) { leftIndicator }
                        .buttonStyle(.plain)
                        .help(expanded ? "Collapse jobs" : "Expand all jobs")

                    Button(action: onSelect) { rowContent }
                        .buttonStyle(.plain)

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.18), value: expanded)
                        .padding(.trailing, 12)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            // ── Inline job rows — shown for in-progress groups;
            //    showAll is wired directly to `expanded` so the left-indicator
            //    toggle actually controls the content.
            if group.groupStatus == .inProgress && !group.jobs.isEmpty {
                InlineJobRowsView(
                    group: group,
                    tick: tick,
                    onSelectJob: onSelectJob,
                    showAll: expanded
                )
            }
        }
    }

    private var leftIndicator: some View {
        accentColor
            .frame(width: DesignTokens.Layout.leftIndicatorWidth)
            .clipShape(RoundedCorners(topLeft: 0, topRight: 3, bottomLeft: 0, bottomRight: 3))
            .padding(.vertical, 4)
            .frame(maxHeight: .infinity)
            .overlay(
                // ⚠️ Use .primary.opacity() NOT .white.opacity() — .white is invisible
                // in light mode. .primary is adaptive: near-black on light, near-white on dark.
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 5, weight: .bold))
                    .foregroundColor(.primary.opacity(expanded ? 0.7 : 0.35))
            )
            .contentShape(Rectangle())
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            StatusDonutView(
                status: group.groupStatus,
                conclusion: group.conclusion,
                progress: group.progressFraction
            )
            RunnerTypeIcon(isLocal: group.isLocalGroup)
            Text(group.label)
                .font(DesignTokens.Font.monoSmall)
                .foregroundColor(DesignTokens.Color.labelSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(group.title)
                .font(.system(size: 12))
                .foregroundColor(group.isDimmed ? .secondary : .primary)
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
            Spacer()
            metaTrailing
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var metaTrailing: some View {
        if let start = group.firstJobStartedAt {
            Text(RelativeTimeFormatter.string(from: start))
                .font(DesignTokens.Font.monoSmall)
                .foregroundColor(DesignTokens.Color.labelSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        if group.groupStatus == .inProgress || group.groupStatus == .queued {
            Text(group.currentJobName)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(0)
        }
        Text(group.jobProgress)
            .font(DesignTokens.Font.monoSmall)
            .foregroundColor(DesignTokens.Color.labelSecondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        Text(group.elapsed)
            .font(DesignTokens.Font.monoSmall)
            .foregroundColor(DesignTokens.Color.labelSecondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        statusChip
    }

    @ViewBuilder
    private var statusChip: some View {
        switch group.groupStatus {
        case .inProgress:
            StatusBadge(label: "IN PROGRESS", color: DesignTokens.Color.statusBlue)
        case .queued:
            StatusBadge(label: "QUEUED", color: DesignTokens.Color.statusBlue)
        case .completed:
            let success = group.conclusion == "success"
            StatusBadge(
                label: success ? "SUCCESS" : "FAILED",
                color: success ? DesignTokens.Color.statusGreen : DesignTokens.Color.statusRed
            )
        }
    }
}

// MARK: - StatusBadge
/// Pill-shaped status label for action rows. Replaces the plain coloured Text chip.
struct StatusBadge: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
                    .overlay(Capsule().strokeBorder(color.opacity(0.3), lineWidth: 0.75))
            )
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - RoundedCorners
/// Custom shape with per-corner independent radii.
/// Used for the left indicator bar: right corners rounded (3pt), left flush (0pt).
private struct RoundedCorners: Shape {
    var topLeft, topRight, bottomLeft, bottomRight: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - topRight, y: rect.minY + topRight),
            radius: topRight,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        path.addArc(
            center: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY - bottomRight),
            radius: bottomRight,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY - bottomLeft),
            radius: bottomLeft,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        path.addArc(
            center: CGPoint(x: rect.minX + topLeft, y: rect.minY + topLeft),
            radius: topLeft,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - InlineJobRowsView
/// Passive read-only ↳ job rows shown beneath every action group.
/// Default: shows only `in_progress` jobs.
/// When `showAll == true` (triggered by the left indicator expand toggle): shows all jobs.
///
/// ⚠️ REGRESSION GUARD (#377):
/// `cap += 4` on button tap mutates @State while the popover is visible.
/// isPopoverOpen is read from @EnvironmentObject PopoverOpenState — NOT from a plain Bool prop.
/// ❌ NEVER add `var isPopoverOpen: Bool` prop back.
/// ❌ NEVER mutate cap while popoverOpenState.isOpen == true.
/// ❌ NEVER remove .disabled(popoverOpenState.isOpen) from the expand button.
/// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
/// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
/// is major major major.
struct InlineJobRowsView: View {
    let group: ActionGroup
    let tick: Int
    var onSelectJob: ((ActiveJob, ActionGroup) -> Void)?
    /// When true, all jobs are shown; when false, only in_progress jobs are shown.
    /// Pass `expanded` from ActionRowView directly — do NOT default this to true at the call site.
    var showAll: Bool = false

    @EnvironmentObject private var popoverOpenState: PopoverOpenState
    @State private var cap: Int = 4

    private var visibleJobs: [ActiveJob] {
        showAll ? group.jobs : group.jobs.filter { $0.status == "in_progress" }
    }

    var body: some View {
        ForEach(visibleJobs.prefix(cap)) { job in
            if let onSelectJob {
                Button(action: { onSelectJob(job, group) }, label: { jobRow(job) })
                    .buttonStyle(.plain)
            } else {
                jobRow(job)
            }
        }
        if visibleJobs.count > cap {
            Button(
                action: {
                    if !popoverOpenState.isOpen { cap += 4 }
                },
                label: {
                    Text("+ \(visibleJobs.count - cap) more jobs…")
                        .font(DesignTokens.Font.monoXSmall)
                        .foregroundColor(.accentColor)
                        .padding(.leading, 24).padding(.trailing, 12).padding(.vertical, 2)
                }
            )
            .buttonStyle(.plain)
            .disabled(popoverOpenState.isOpen)
        }
    }

    private func jobRow(_ job: ActiveJob) -> some View {
        // ⚠️ TICK CONTRACT — DO NOT REMOVE.
        // ❌ NEVER remove this line.
        _ = tick
        let currentStep = job.steps.first(where: { $0.status == "in_progress" })
        let stepName = currentStep.map(\.name).flatMap { $0.isEmpty ? nil : $0 }
        let done = job.steps.filter { $0.conclusion != nil }.count
        let total = job.steps.count
        return HStack(spacing: 6) {
            Text("↳").font(.caption).foregroundColor(.secondary).frame(width: 16, alignment: .trailing)
            PieProgressDot(progress: job.progressFraction, color: jobDotColor(for: job), size: 7)
            Group {
                if let name = stepName {
                    Text(job.name + " · " + name)
                } else {
                    Text(job.name)
                }
            }
            .font(.caption).foregroundColor(.secondary)
            .lineLimit(1).truncationMode(.tail)
            .layoutPriority(1)
            Spacer()
            if total > 0 {
                Text("\(done)/\(total)")
                    .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text(job.elapsed)
                .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if onSelectJob != nil {
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.leading, 24).padding(.trailing, 12).padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func jobDotColor(for job: ActiveJob) -> Color {
        switch job.status {
        case "in_progress": return DesignTokens.Color.statusBlue
        case "queued":      return DesignTokens.Color.statusBlue.opacity(0.5)
        default: return job.conclusion == "success"
            ? DesignTokens.Color.statusGreen
            : (job.isDimmed ? DesignTokens.Color.labelTertiary : DesignTokens.Color.statusRed)
        }
    }
}
