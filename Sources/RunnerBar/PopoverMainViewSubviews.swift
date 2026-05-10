import SwiftUI

// MARK: - PopoverHeaderView

/// Header row: system stats left, auth indicator + settings + close right.
struct PopoverHeaderView: View {
    let stats: SystemStats
    let isAuthenticated: Bool
    let onSelectSettings: () -> Void
    let onSignIn: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            systemStatsBadge
            Spacer()
            authIndicator
            Button(
                action: onSelectSettings,
                label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13)).foregroundColor(.secondary)
                }
            )
            .buttonStyle(.plain).help("Settings")
            Button(
                action: { NSApplication.shared.hide(nil) },
                label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                }
            )
            .buttonStyle(.plain).help("Close")
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
    }

    @ViewBuilder
    private var authIndicator: some View {
        if isAuthenticated {
            Circle().fill(Color.green).frame(width: 7, height: 7)
        } else {
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
    }

    /// Inline CPU / MEM / DISK chips with block-bar fill prefix.
    /// ⚠️ LOAD-BEARING: `.lineLimit(1)` on chip texts prevents multi-line wrapping that
    /// would change `hc.view.fittingSize.height` and corrupt the popover frame in
    /// `AppDelegate.openPopover()` (ref #52 #54).
    private var systemStatsBadge: some View {
        HStack(spacing: 8) {
            statChip(
                label: "CPU",
                value: blockBar(pct: stats.cpuPct) + " " + String(format: "%.1f%%", stats.cpuPct),
                pct: stats.cpuPct
            )
            statChip(
                label: "MEM",
                value: blockBar(pct: stats.memTotalGB > 0
                    ? (stats.memUsedGB / stats.memTotalGB) * 100 : 0)
                    + " "
                    + String(format: "%.1f/%.1fGB", stats.memUsedGB, stats.memTotalGB),
                pct: stats.memTotalGB > 0 ? (stats.memUsedGB / stats.memTotalGB) * 100 : 0
            )
            statChip(
                label: "DISK",
                value: blockBar(pct: stats.diskTotalGB > 0
                    ? (stats.diskUsedGB / stats.diskTotalGB) * 100 : 0)
                    + " "
                    + String(
                        format: "%d/%dGB",
                        Int(stats.diskUsedGB.rounded()), Int(stats.diskTotalGB.rounded())
                    ),
                pct: stats.diskTotalGB > 0 ? (stats.diskUsedGB / stats.diskTotalGB) * 100 : 0
            )
        }
    }

    /// Single label+value chip coloured by usage level.
    /// Both texts are `.lineLimit(1)` — load-bearing, see `systemStatsBadge` doc.
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
        let raw = Int((pct / 100.0 * Double(width)).rounded())
        let filledCount = max(0, min(width, raw))
        return String(repeating: "█", count: filledCount) + String(repeating: "░", count: width - filledCount)
    }

    private func usageColor(pct: Double) -> Color {
        if pct > 85 { return .red }
        if pct > 60 { return .yellow }
        return .green
    }
}

// MARK: - PopoverLocalRunnerRow

/// Conditionally shows online local runners — hidden when all are idle/offline.
struct PopoverLocalRunnerRow: View {
    let runners: [Runner]

    var body: some View {
        let active = runners.filter { $0.status == "online" }
        if !active.isEmpty { runnerList(active) }
    }

    @ViewBuilder
    private func runnerList(_ active: [Runner]) -> some View {
        ForEach(active.prefix(3)) { runner in
            HStack(spacing: 8) {
                Circle().fill(runner.busy ? Color.yellow : Color.green).frame(width: 8, height: 8)
                Text(runner.name)
                    .font(.system(size: 12)).foregroundColor(.primary).lineLimit(1)
                Spacer()
                if let metrics = runner.metrics {
                    Text(String(format: "CPU: %.1f%%  MEM: %.1f%%", metrics.cpu, metrics.mem))
                        .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 3)
        }
        if active.count > 3 {
            Text("+ \(active.count - 3) more…")
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 2)
        }
        Divider()
    }
}

// MARK: - ActionRowView

/// Single action-group row with pie progress dot, started-ago timestamp,
/// and spec-parity typography (#178).
struct ActionRowView: View {
    let group: ActionGroup
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect, label: { rowContent }).buttonStyle(.plain)
            Image(systemName: "chevron.right")
                .font(.caption2).foregroundColor(.secondary).padding(.trailing, 12)
        }
    }

    private var rowContent: some View {
        HStack(spacing: 6) {
            PieProgressDot(progress: group.progressFraction, color: dotColor)
            Text(group.label)
                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                .lineLimit(1).frame(width: 52, alignment: .leading)
            Text(group.title)
                .font(.system(size: 12))
                .foregroundColor(group.isDimmed ? .secondary : .primary)
                .lineLimit(1).truncationMode(.tail)
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
                .frame(width: 44, alignment: .trailing)
        }
        if group.groupStatus == .inProgress || group.groupStatus == .queued {
            Text(group.currentJobName)
                .font(.caption).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: 72, alignment: .trailing)
        }
        Text(group.jobProgress)
            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
            .frame(width: 30, alignment: .trailing)
        Text(group.elapsed)
            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
            .frame(width: 40, alignment: .trailing)
        statusChip
    }

    /// Status chip — .lineLimit(1) + .fixedSize(horizontal: true, vertical: false) prevents
    /// multi-word labels like "IN PROGRESS" from wrapping onto a second line, which would
    /// corrupt fittingSize.height and cause the popover to be mis-sized (ref #52 #54).
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
/// Only shows jobs that are currently `in_progress` — queued and completed jobs
/// are intentionally excluded (per spec: inline rows communicate active work only).
/// Rows have no tap action per spec #324 Gap 2.
struct InlineJobRowsView: View {
    let group: ActionGroup
    @State private var cap: Int = 4

    /// Only in-progress jobs — ❌ never include queued or completed jobs here.
    private var activeJobs: [ActiveJob] {
        group.jobs.filter { $0.status == "in_progress" }
    }

    var body: some View {
        ForEach(activeJobs.prefix(cap)) { job in
            jobRow(job)
        }
        if activeJobs.count > cap {
            Button(
                action: { cap += 4 },
                label: {
                    Text("+ \(activeJobs.count - cap) more jobs…")
                        .font(.caption2).foregroundColor(.accentColor)
                        .padding(.leading, 24).padding(.trailing, 12).padding(.vertical, 2)
                }
            )
            .buttonStyle(.plain)
        }
    }

    private func jobRow(_ job: ActiveJob) -> some View {
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
            Spacer()
            if total > 0 {
                Text("\(done)/\(total)")
                    .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }
            Text(job.elapsed)
                .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.leading, 24).padding(.trailing, 12).padding(.vertical, 2)
    }

    private func jobDotColor(for job: ActiveJob) -> Color {
        switch job.status {
        case "in_progress": return .yellow
        case "queued": return .blue
        default: return job.conclusion == "success" ? .green : (job.isDimmed ? .gray : .red)
        }
    }
}
