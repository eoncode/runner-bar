import SwiftUI

// MARK: - SectionHeaderLabel
/// Uppercase section header label used throughout the popover (e.g. "ACTIONS").
struct SectionHeaderLabel: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(RBFont.sectionCaption)
            .foregroundColor(.secondary)
            .padding(.horizontal, DesignTokens.Spacing.rowHPad)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

// MARK: - PopoverHeaderView
/// Header row: sparkline stats left, settings + close right.
/// ⚠️ Auth green dot removed — auth status lives in Settings > Account only (#10).
/// Phase 2: accepts the shared SystemStatsViewModel so sparkline histories are live.
/// The disk-used percentage pill is rendered inside HeaderStatsBar (adjacent to the
/// DISK sparkline). Do NOT add a second DiskUsagePill here.
struct PopoverHeaderView: View {
    @ObservedObject var statsVM: SystemStatsViewModel
    let isAuthenticated: Bool
    let onSelectSettings: () -> Void
    let onSignIn: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // Phase 2: HeaderStatsBar renders CPU/MEM/DISK sparklines + disk pill.
            // Receives the shared VM — no second sampler is created.
            HeaderStatsBar(statsVM: statsVM)

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
        .padding(.horizontal, DesignTokens.Spacing.rowHPad)
        .padding(.top, 10)
        .padding(.bottom, 8)
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
/// Card-styled busy runner row.
/// Phase 3 changes:
///  - Each runner gets a RoundedRectangle card with .rbSurfaceElevated fill + .rbBorderSubtle stroke
///  - CPU / MEM values use StatPill from ViewModifiers (ultraThinMaterial pill)
///  - Runner name uses RBFont.label monospaced style
///  - Trailing chevron.right added
struct PopoverLocalRunnerRow: View {
    let runners: [Runner]

    var body: some View {
        let busy = runners.filter { $0.busy }
        if !busy.isEmpty {
            runnerList(busy)
        }
    }

    @ViewBuilder
    private func runnerList(_ busy: [Runner]) -> some View {
        ForEach(busy.prefix(3)) { runner in
            runnerCard(runner)
        }
        if busy.count > 3 {
            Text("+ \(busy.count - 3) more…")
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, DesignTokens.Spacing.rowHPad)
                .padding(.vertical, 2)
        }
        Divider()
    }

    private func runnerCard(_ runner: Runner) -> some View {
        HStack(spacing: 8) {
            // Status dot
            Circle()
                .fill(Color.rbWarning)
                .frame(width: 7, height: 7)

            // Runner name — monospaced per Phase 1 spec
            Text(runner.name)
                .font(RBFont.label)
                .foregroundColor(.primary)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer()

            // CPU / MEM stat pills
            if let metrics = runner.metrics {
                StatPill(
                    label: "CPU",
                    value: String(format: "%.0f%%", metrics.cpu)
                )
                StatPill(
                    label: "MEM",
                    value: String(format: "%.0f%%", metrics.mem)
                )
            }

            // Trailing chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.rbTextTertiary)
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, RBSpacing.xs + 2)
        // Card background: elevated fill + subtle border
        .background(
            RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous)
                .fill(Color.rbSurfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous)
                        .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5)
                )
        )
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, RBSpacing.xxs)
    }
}

// MARK: - ActionRowView
/// Phase 4 redesign:
///  4a — Left-side status indicator: a 3pt-wide Capsule clipped inside the card
///       RoundedRectangle so it never bleeds past the card corner radius.
///       Tapping the pill toggles between auto-expand (in-progress jobs only)
///       and full-expand (all jobs).
///  4b — DonutStatusView replaces PieProgressDot
///  4c — Subtle row background tint keyed to status
///  4d — chevron.right is now always used (was chevron.down in some paths)
///
/// Expand behaviour (fix #419 bug 2 & 3):
///   - In-progress rows auto-expand on appear, showing ONLY in_progress jobs.
///   - Failed/success/queued rows start collapsed.
///   - User tap on pill cycles: collapsed -> auto (in-progress only) -> full (all jobs).
///   - When status transitions to a terminal state, auto-collapse.
struct ActionRowView: View {
    let group: ActionGroup
    let tick: Int
    let onSelect: () -> Void

    /// Three-state expand:
    ///  - nil        : collapsed — no inline rows
    ///  - false      : auto-expand — only in_progress jobs (default for in-progress rows)
    ///  - true       : full-expand — all jobs (user tapped a second time)
    @State private var expandState: Bool? = nil

    var body: some View {
        ZStack(alignment: .leading) {
            // Card background — elevated surface + subtle border stroke
            RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous)
                .fill(Color.rbSurfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous)
                        .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5)
                )

            // Status tint overlay at very low opacity
            RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous)
                .fill(rowStatus.tint)

            // Left status indicator — tappable to cycle expand state.
            // fix(#419 bug 4): no extra leading padding on the content below,
            // so the donut aligns directly with the tree-line hierarchy.
            Button(
                action: {
                    if !group.jobs.isEmpty {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            switch expandState {
                            case nil:   expandState = false  // collapsed -> auto (in-progress only)
                            case false: expandState = true   // auto -> full
                            case true:  expandState = nil    // full -> collapsed
                            default:    expandState = nil
                            }
                        }
                    }
                },
                label: {
                    Capsule(style: .continuous)
                        .fill(rowStatus.color)
                        .frame(width: 3)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, RBSpacing.xs)
                }
            )
            .buttonStyle(.plain)
            .help(expandState == nil ? "Expand jobs" : "Collapse / expand jobs")

            // Content column — offset only enough to clear the 3pt Capsule pill.
            // fix(#419 bug 4): removed extra .padding(.leading, RBSpacing.sm) from rowContent
            // so the donut aligns with the hierarchy line drawn by TreeLineLeader below.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: RBSpacing.md)

                    Button(action: onSelect, label: { rowContent })
                        .buttonStyle(.plain)

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.trailing, 12)
                }

                // Inline job rows — shown when not collapsed
                if let fullExpand = expandState {
                    InlineJobRowsView(group: group, tick: tick, fullExpand: fullExpand)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous))
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, RBSpacing.xxs)
        .onAppear {
            // fix(#419 bug 2): in-progress rows auto-expand showing only active jobs.
            // Other states (queued, success, failed) start collapsed.
            expandState = (rowStatus == .inProgress) ? false : nil
        }
        // fix(#419 bug 3): auto-collapse when run transitions to terminal state.
        .onChange(of: rowStatus) { newStatus in
            if newStatus == .success || newStatus == .failed {
                withAnimation(.easeInOut(duration: 0.15)) { expandState = nil }
            }
        }
    }

    // MARK: - Helpers

    private var rowStatus: RBStatus {
        switch group.groupStatus {
        case .inProgress: return .inProgress
        case .queued:     return .queued
        case .completed:
            switch group.conclusion {
            case "success":  return .success
            case "failure":  return .failed
            default:         return .unknown
            }
        }
    }

    private var rowContent: some View {
        // ⚠️ TICK CONTRACT — DO NOT REMOVE.
        // ☞ NEVER remove this line. tickSnapshot forces SwiftUI to invalidate
        //   this view on every 1-second displayTick so elapsed strings stay live.
        let tickSnapshot = tick
        return HStack(spacing: 6) {
            // 4b: DonutStatusView replaces PieProgressDot
            DonutStatusView(
                status: rowStatus,
                progress: group.progressFraction ?? 0,
                size: 14
            )
            RunnerTypeIcon(isLocal: group.isLocalGroup)
            Text(group.label)
                .font(DesignTokens.Fonts.mono)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(group.title)
                .font(.system(size: 12))
                .foregroundColor(group.isDimmed ? .secondary : .primary)
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
            Spacer()
            metaTrailing(tick: tickSnapshot)
        }
        // fix(#419 bug 4): no extra .padding(.leading) here — the Color.clear spacer
        // above (width: RBSpacing.md) is sufficient to clear the Capsule pill.
        // Removing this extra indent aligns the donut with the tree-line below.
        .padding(.trailing, RBSpacing.xs)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func metaTrailing(tick tickSnapshot: Int) -> some View {
        // tickSnapshot is consumed via .id() on the elapsed Text to force
        // SwiftUI invalidation every display tick — DO NOT REMOVE.
        if let start = group.firstJobStartedAt {
            Text(RelativeTimeFormatter.string(from: start))
                .font(DesignTokens.Fonts.mono)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .id(tickSnapshot)
        }
        if group.groupStatus == .inProgress || group.groupStatus == .queued {
            Text(group.currentJobName)
                .font(.caption).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(0)
        }
        Text(group.jobProgress)
            .font(DesignTokens.Fonts.mono)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        Text(group.elapsed)
            .font(DesignTokens.Fonts.mono)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        statusBadge
    }

    /// Phase 4: Status badge uses `StatusBadge` component from Phase 1 ViewModifiers
    /// instead of raw Text with hardcoded colors.
    @ViewBuilder
    private var statusBadge: some View {
        switch group.groupStatus {
        case .inProgress:
            StatusBadge(status: .inProgress, text: "IN PROGRESS")
        case .queued:
            StatusBadge(status: .queued, text: "QUEUED")
        case .completed:
            switch group.conclusion {
            case "success":  StatusBadge(status: .success, text: "SUCCESS")
            case "failure":  StatusBadge(status: .failed, text: "FAILED")
            default:         StatusBadge(status: .unknown, text: "DONE")
            }
        }
    }
}
