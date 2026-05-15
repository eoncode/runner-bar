import AppKit
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

// MARK: - StatusBadge
/// A small pill-shaped label used to display job status/conclusion.
struct StatusBadge: View {
    let label: String
    let color: Color
    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - JobProgressBarView
/// A thin horizontal progress bar for in-progress job rows.
struct JobProgressBarView: View {
    let fraction: CGFloat
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                Rectangle()
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: geo.size.width * max(0, min(1, fraction)))
            }
        }
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
    /// CPU utilisation history (0.0–1.0 per sample) for sparkline display.
    var cpuHistory: [Double] = []
    /// Memory utilisation history (0.0–1.0 per sample) for sparkline display.
    var memHistory: [Double] = []
    /// Disk utilisation history (0.0–1.0 per sample) for sparkline display.
    var diskHistory: [Double] = []

    var body: some View {
        HStack(spacing: 6) {
            systemStatsBadge
            Spacer()
            // #10: green dot removed; only show Sign-in button when unauthenticated.
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
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
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
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(usageColor(pct: pct))
                .lineLimit(1)
        }
    }

    private func blockBar(pct: Double, width: Int = 3) -> String {
        let raw         = Int((pct / 100.0 * Double(width)).rounded())
        let filledCount = max(0, min(width, raw))
        return String(repeating: "█", count: filledCount)
             + String(repeating: "░", count: width - filledCount)
    }

    private func usageColor(pct: Double) -> Color {
        if pct > 85 { return .red    }
        if pct > 60 { return .yellow }
        return .green
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
            HStack(spacing: 8) {
                Circle().fill(Color.yellow).frame(width: 8, height: 8)
                Text(runner.name)
                    .font(.system(size: 12)).foregroundColor(.primary).lineLimit(1)
                Spacer()
                if let metrics = runner.metrics {
                    Text(String(format: "CPU: %.1f%% MEM: %.1f%%", metrics.cpu, metrics.mem))
                        .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 3)
        }
        if busy.count > 3 {
            Text("+ \(busy.count - 3) more…")
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 2)
        }
        Divider()
    }
}

// MARK: - ActionRowView
struct ActionRowView: View {
    let group: ActionGroup
    let tick: Int
    let onSelect: () -> Void
    var onSelectJob: ((ActiveJob, ActionGroup) -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect, label: { rowContent }).buttonStyle(.plain)
            Image(systemName: "chevron.right")
                .font(.caption2).foregroundColor(.secondary).padding(.trailing, 12)
        }
        if group.groupStatus == .inProgress {
            InlineJobRowsView(group: group, tick: tick, onSelectJob: onSelectJob)
        }
    }

    private var rowContent: some View {
        // ⚠️ TICK CONTRACT — DO NOT REMOVE.
        // ❌ NEVER remove this line.
        _ = tick
        return HStack(spacing: 6) {
            PieProgressDot(progress: group.progressFraction, color: dotColor)
            RunnerTypeIcon(isLocal: group.isLocalGroup)
            Text(group.label)
                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
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
        .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 3)
    }

    @ViewBuilder
    private var metaTrailing: some View {
        if let start = group.firstJobStartedAt {
            Text(RelativeTimeFormatter.string(from: start))
                .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
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
            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        Text(group.elapsed)
            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        statusChip
    }

    @ViewBuilder
    private var statusChip: some View {
        switch group.groupStatus {
        case .inProgress:
            Text("IN PROGRESS")
                .font(.system(size: 9, weight: .bold)).foregroundColor(.yellow)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        case .queued:
            Text("QUEUED")
                .font(.system(size: 9, weight: .bold)).foregroundColor(.blue)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        case .completed:
            let success = group.conclusion == "success"
            Text(success ? "SUCCESS" : "FAILED")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(success ? .green : .red)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        }
    }

    private var dotColor: Color {
        switch group.groupStatus {
        case .inProgress: return .yellow
        case .queued: return .blue
        case .completed:
            if group.isDimmed { return .gray }
            return group.conclusion == "success" ? .green : .red
        }
    }
}

// MARK: - InlineJobRowsView
/// Passive read-only ↳ job rows shown beneath every in-progress action group.
/// Only shows jobs that are currently `in_progress`.
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

    @EnvironmentObject private var popoverOpenState: PopoverOpenState
    @State private var cap: Int = 4

    private var activeJobs: [ActiveJob] {
        group.jobs.filter { $0.status == "in_progress" }
    }

    var body: some View {
        ForEach(activeJobs.prefix(cap)) { job in
            if let onSelectJob {
                Button(action: { onSelectJob(job, group) }, label: { jobRow(job) })
                    .buttonStyle(.plain)
            } else {
                jobRow(job)
            }
        }
        if activeJobs.count > cap {
            Button(
                action: {
                    if !popoverOpenState.isOpen { cap += 4 }
                },
                label: {
                    Text("+ \(activeJobs.count - cap) more jobs…")
                        .font(.caption2).foregroundColor(.accentColor)
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
        let stepName    = currentStep.map(\.name).flatMap { $0.isEmpty ? nil : $0 }
        let done  = job.steps.filter { $0.conclusion != nil }.count
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
        case "in_progress": return .yellow
        case "queued":      return .blue
        default: return job.conclusion == "success" ? .green : (job.isDimmed ? .gray : .red)
        }
    }
}
