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
            Circle()
                .fill(Color.rbWarning)
                .frame(width: 7, height: 7)
            Text(runner.name)
                .font(RBFont.label)
                .foregroundColor(.primary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer()
            if let metrics = runner.metrics {
                StatPill(label: "CPU", value: String(format: "%.0f%%", metrics.cpu))
                StatPill(label: "MEM", value: String(format: "%.0f%%", metrics.mem))
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.rbTextTertiary)
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, RBSpacing.xs + 2)
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
/// Phase 4 redesign — left status pill, DonutStatusView, tint, chevron.
///
/// Expand behaviour:
///   expandState == nil   → collapsed (no inline rows)
///   expandState == false → auto-expanded, shows only in_progress jobs
///                          (set by .onAppear for in-progress runs)
///   expandState == true  → user-expanded, shows ALL jobs
///
/// Pill tap is a SIMPLE TOGGLE: nil ↔ true.
/// This means one tap always expands (all jobs), one tap always collapses.
/// The auto-expand false state is only ever set by .onAppear / .onChange,
/// never by the tap handler — eliminating the double-tap bug.
struct ActionRowView: View {
    let group: ActionGroup
    let tick: Int
    let onSelect: () -> Void

    /// nil = collapsed, false = auto-expanded (in-progress only), true = user-expanded (all jobs)
    @State private var expandState: Bool? = nil

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous)
                .fill(Color.rbSurfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous)
                        .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5)
                )

            RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous)
                .fill(rowStatus.tint)

            // Left status pill — SIMPLE TOGGLE: nil ↔ true.
            // Never cycles through false — that avoids the double-tap bug where
            // false→true looked like nothing happened (both states show rows) or
            // nil→false showed zero jobs on a completed run.
            Button(
                action: {
                    guard !group.jobs.isEmpty else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        expandState = (expandState == nil) ? true : nil
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
            .help(expandState == nil ? "Expand jobs" : "Collapse jobs")

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

                if let fullExpand = expandState {
                    InlineJobRowsView(group: group, tick: tick, fullExpand: fullExpand)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous))
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, RBSpacing.xxs)
        .onAppear {
            // Auto-expand in-progress rows showing only active jobs (false).
            // Terminal/queued rows start collapsed (nil).
            expandState = (rowStatus == .inProgress) ? false : nil
        }
        // Auto-collapse when run transitions to a terminal state.
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
        let tickSnapshot = tick
        return HStack(spacing: 6) {
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
        .padding(.trailing, RBSpacing.xs)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func metaTrailing(tick tickSnapshot: Int) -> some View {
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
