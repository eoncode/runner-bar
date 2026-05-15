import SwiftUI

// MARK: - SectionHeaderLabel
/// Uppercase section header label used throughout the popover (e.g. "ACTIONS").
struct SectionHeaderLabel: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, DesignTokens.Spacing.rowHPad)
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

    var body: some View {
        HStack(spacing: 6) {
            systemStatsBadge
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

    /// Inline CPU / MEM / DISK chips with block-bar fill prefix.
    /// ⚠️ LOAD-BEARING: `.lineLimit(1)` on chip texts prevents multi-line wrapping that
    /// would change `preferredContentSize.height` and corrupt the panel frame (ref #52 #54).
    private var systemStatsBadge: some View {
        HStack(spacing: 8) {
            statChip(
                label: "CPU",
                value: blockBar(pct: stats.cpuPct) + " " + String(format: "%.1f%%", stats.cpuPct),
                pct: stats.cpuPct
            )
            statChip(
                label: "MEM",
                value: blockBar(pct: stats.memTotalGB > 0 ? (stats.memUsedGB / stats.memTotalGB) * 100 : 0)
                    + " " + String(format: "%.1f/%.1fGB", stats.memUsedGB, stats.memTotalGB),
                pct: stats.memTotalGB > 0 ? (stats.memUsedGB / stats.memTotalGB) * 100 : 0
            )
            diskChip
        }
    }

    private var diskChip: some View {
        let total   = stats.diskTotalGB
        let used    = stats.diskUsedGB
        let free    = max(0, total - used)
        let pct     = total > 0 ? (used / total) * 100 : 0
        let freePct = total > 0 ? (free / total) * 100 : 0
        let value   = blockBar(pct: pct)
            + " " + String(format: "%d/%dGB", Int(used.rounded()), Int(total.rounded()))
            + " (" + String(format: "%dGB %d%%", Int(free.rounded()), Int(freePct.rounded())) + ")"
        return statChip(label: "DISK", value: value, pct: pct)
    }

    private func statChip(label: String, value: String, pct: Double) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(DesignTokens.Fonts.monoLabel)   // Phase 1: mono font token
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(value)
                .font(DesignTokens.Fonts.monoStat)    // Phase 1: mono font token
                .foregroundColor(DesignTokens.Colors.usage(pct: pct)) // Phase 1: colour token
                .lineLimit(1)
        }
    }

    private func blockBar(pct: Double, width: Int = 3) -> String {
        let raw         = Int((pct / 100.0 * Double(width)).rounded())
        let filledCount = max(0, min(width, raw))
        return String(repeating: "▓", count: filledCount)
             + String(repeating: "░", count: width - filledCount)
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
///  4a — Left-side elong status indicator bar (3pt wide RoundedRectangle)
///       NOW also acts as expand/collapse toggle for inline job rows (spec #420 Phase 4).
///  4b — DonutStatusView replaces PieProgressDot
///  4c — Subtle row background tint keyed to status
///  4d — chevron.right is now always used (was chevron.down in some paths)
struct ActionRowView: View {
    let group: ActionGroup
    let tick: Int
    let onSelect: () -> Void

    // Expanded state for inline job rows; defaults to true for in-progress, false otherwise.
    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                // 4a: Left status indicator — toggle for expand/collapse (Phase 4 spec #420)
                // Guard: allow toggle whenever the group has any jobs (not just in-progress)
                Button(
                    action: {
                        if !group.jobs.isEmpty {
                            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                        }
                    },
                    label: {
                        LeftStatusIndicator(status: rowStatus)
                            .padding(.vertical, 6)
                    }
                )
                .buttonStyle(.plain)
                .help(expanded ? "Collapse jobs" : "Expand jobs")

                Button(action: onSelect, label: { rowContent })
                    .buttonStyle(.plain)

                // 4d: Always chevron.right (fixed — was chevron.down in some states)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.trailing, 12)
            }
            // Inline job rows -- only when expanded
            if expanded {
                InlineJobRowsView(group: group, tick: tick)
            }
        }
        // 4c: Subtle status tint on the row background
        .background(
            rowStatus.tint
                .clipShape(RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous))
        )
        .onAppear {
            // In-progress rows start expanded by default
            expanded = (rowStatus == .inProgress)
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
        // ☞ NEVER remove this line.
        _ = tick
        return HStack(spacing: 6) {
            // 4b: DonutStatusView replaces PieProgressDot
            DonutStatusView(
                status: rowStatus,
                progress: group.progressFraction ?? 0,
                size: 14
            )
            RunnerTypeIcon(isLocal: group.isLocalGroup)
            Text(group.label)
                .font(DesignTokens.Fonts.mono)         // Phase 1: mono font token
                .foregroundColor(.secondary)
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
        .padding(.leading, RBSpacing.sm)
        .padding(.trailing, RBSpacing.xs)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var metaTrailing: some View {
        if let start = group.firstJobStartedAt {
            Text(RelativeTimeFormatter.string(from: start))
                .font(DesignTokens.Fonts.mono)         // Phase 1: mono font token
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        if group.groupStatus == .inProgress || group.groupStatus == .queued {
            Text(group.currentJobName)
                .font(.caption).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(0)
        }
        Text(group.jobProgress)
            .font(DesignTokens.Fonts.mono)             // Phase 1: mono font token
            .foregroundColor(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        Text(group.elapsed)
            .font(DesignTokens.Fonts.mono)             // Phase 1: mono font token
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
