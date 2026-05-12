import SwiftUI

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
                value: blockBar(pct: stats.memTotalGB > 0
                    ? (stats.memUsedGB / stats.memTotalGB) * 100 : 0)
                    + " "
                    + String(format: "%.1f/%.1fGB", stats.memUsedGB, stats.memTotalGB),
                pct: stats.memTotalGB > 0 ? (stats.memUsedGB / stats.memTotalGB) * 100 : 0
            )
            diskChip
        }
    }

    /// DISK chip: used/total + free space and free percent in parens.
    /// e.g. "██░ 333/460GB (127GB 28%)"
    private var diskChip: some View {
        let total = stats.diskTotalGB
        let used = stats.diskUsedGB
        let free = max(0, total - used)
        let pct = total > 0 ? (used / total) * 100 : 0
        let freePct = total > 0 ? (free / total) * 100 : 0
        let value = blockBar(pct: pct)
            + " "
            + String(format: "%d/%dGB", Int(used.rounded()), Int(total.rounded()))
            + " ("
            + String(format: "%dGB %d%%", Int(free.rounded()), Int(freePct.rounded()))
            + ")"
        return statChip(label: "DISK", value: value, pct: pct)
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
        return String(repeating: "\u{2588}", count: filledCount) + String(repeating: "\u{2591}", count: width - filledCount)
    }

    private func usageColor(pct: Double) -> Color {
        if pct > 85 { return .red }
        if pct > 60 { return .yellow }
        return .green
    }
}

// MARK: - PopoverLocalRunnerRow

/// Shows runners that are actively running a job (busy == true).
/// Hidden entirely when no runner is busy — idle/offline runners are not shown.
struct PopoverLocalRunnerRow: View {
    let runners: [Runner]

    var body: some View {
        // Spec: only show runners when they are actively busy (running a job).
        // Idle online runners are intentionally hidden.
        let busy = runners.filter { $0.busy }
        if !busy.isEmpty { runnerList(busy) }
    }

    @ViewBuilder
    private func runnerList(_ busy: [Runner]) -> some View {
        ForEach(busy.prefix(3)) { runner in
            HStack(spacing: 8) {
                Circle().fill(Color.yellow).frame(width: 8, height: 8)
                // Runner name: lineLimit(1) — machine names can be arbitrarily long.
                // Title truncation is intentional here (machine names vs commit titles).
                Text(runner.name)
                    .font(.system(size: 12)).foregroundColor(.primary).lineLimit(1)
                Spacer()
                if let metrics = runner.metrics {
                    // CPU/MEM stats are short fixed-format strings — fixedSize prevents
                    // them ever being truncated regardless of panel width.
                    Text(String(format: "CPU: %.1f%%  MEM: %.1f%%", metrics.cpu, metrics.mem))
                        .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 3)
        }
        if busy.count > 3 {
            Text("+ \(busy.count - 3) more\u{2026}")
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 2)
        }
        Divider()
    }
}

// MARK: - ActionRowView

/// Single action-group row with pie progress dot, started-ago timestamp,
/// and spec-parity typography (#178).
///
/// Dynamic-width strategy (NSPanel — no anchor, zero jump on any resize):
/// - SHA label  (group.label) : .fixedSize() — always 7 chars, never truncate
/// - Timestamp                : .fixedSize() — "2m ago" / "just now", short
/// - Steps progress           : .fixedSize() — "0/10" format, 4-6 chars max
/// - Elapsed                  : .fixedSize() — "02:25" format, 5 chars max
/// - Status chip              : .fixedSize() — already was
/// - Title (group.title)      : lineLimit(1) truncation KEPT — commit msgs are long
/// - currentJobName           : lineLimit(1) truncation KEPT — job names can be long
/// Panel idealWidth 560 gives comfortable room; preferredContentSize grows it further
/// if needed (up to maxWidth = 90% screen).
///
/// ⚠️ TICK CONTRACT: `tick` MUST be read inside `body` (via `rowContent`) so SwiftUI
/// invalidates this view on every displayTick beat. Without this, elapsed/progress
/// strings on action rows update on SwiftUI's own schedule instead of the shared
/// 1-second clock, causing rows to tick at different rates.
/// ❌ NEVER remove the `_ = tick` line from rowContent.
struct ActionRowView: View {
    let group: ActionGroup
    let tick: Int
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect, label: { rowContent }).buttonStyle(.plain)
            Image(systemName: "chevron.right")
                .font(.caption2).foregroundColor(.secondary).padding(.trailing, 12)
        }
    }

    private var rowContent: some View {
        // ⚠️ TICK CONTRACT — DO NOT REMOVE.
        // Consuming tick here forces SwiftUI to re-evaluate rowContent every second,
        // keeping elapsed/progress in sync with InlineJobRowsView on the same beat.
        // ❌ NEVER remove this line.
        let _ = tick
        return HStack(spacing: 6) {
            PieProgressDot(progress: group.progressFraction, color: dotColor)

            // SHA / label: always 7 chars (e.g. "a1b25e4") — fixedSize so it never truncates.
            // ❌ NEVER add frame(width:) here — NSPanel grows to fit.
            Text(group.label)
                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            // Title: commit message — intentionally truncated, can be very long.
            // layoutPriority(1) gives it first claim on remaining space.
            // ❌ NEVER add frame(width:) here.
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
            // Timestamp: "2m ago", "just now", "1h ago" — short, never truncate.
            // fixedSize lets the panel grow rather than clipping the date.
            // ❌ NEVER add frame(width:) here.
            Text(RelativeTimeFormatter.string(from: start))
                .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        if group.groupStatus == .inProgress || group.groupStatus == .queued {
            // currentJobName: can be long — keep truncation, yield to title.
            // layoutPriority(0) means it shrinks before the title does.
            Text(group.currentJobName)
                .font(.caption).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(0)
        }
        // Steps progress "0/10", "3/10" — short numeric, never truncate.
        // fixedSize lets the panel grow to show it fully.
        // ❌ NEVER add frame(width:) here.
        Text(group.jobProgress)
            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)

        // Elapsed "02:25", "01:18" — 5 chars, never truncate.
        // ❌ NEVER add frame(width:) here.
        Text(group.elapsed)
            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)

        statusChip
    }

    /// Status chip — lineLimit(1) + fixedSize prevents multi-word labels like
    /// "IN PROGRESS" from wrapping onto a second line, corrupting
    /// preferredContentSize.height and mis-sizing the panel (ref #52 #54).
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
///
/// Tapping a row navigates directly to JobDetailView for that job, skipping
/// ActionDetailView — the group is passed along so the back button can return
/// to ActionDetailView.
///
/// ⚠️ REGRESSION GUARD (#377):
/// `cap += 4` on button tap mutates @State while the popover is visible.
/// This triggers a SwiftUI height change → preferredContentSize update → NSPanel
/// resize → (safe, no jump, but still guard it to avoid mid-open layout thrash).
///
/// isPopoverOpen is read from @EnvironmentObject PopoverOpenState — NOT from a plain
/// Bool prop. A Bool prop is frozen at construction time (always false because
/// mainView() constructs it before the popover opens). The environment object is
/// mutated by AppDelegate before show() so the value is always live.
///
/// ❌ NEVER add `var isPopoverOpen: Bool` prop back.
/// ❌ NEVER mutate cap while popoverOpenState.isOpen == true.
/// ❌ NEVER remove .disabled(popoverOpenState.isOpen) from the expand button.
/// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
/// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
/// is major major major.
struct InlineJobRowsView: View {
    let group: ActionGroup
    let tick: Int
    /// Called when the user taps an inline job row.
    /// Receives the tapped job and its parent group so AppDelegate can navigate
    /// directly to JobDetailView with the correct back-stack (→ ActionDetailView).
    var onSelectJob: ((ActiveJob, ActionGroup) -> Void)? = nil

    /// Live open-state signal. Read from environment — never a plain Bool prop.
    @EnvironmentObject private var popoverOpenState: PopoverOpenState
    @State private var cap: Int = 4

    /// Only in-progress jobs — ❌ never include queued or completed jobs here.
    private var activeJobs: [ActiveJob] {
        group.jobs.filter { $0.status == "in_progress" }
    }

    var body: some View {
        ForEach(activeJobs.prefix(cap)) { job in
            if let onSelectJob {
                Button(action: { onSelectJob(job, group) }, label: {
                    jobRow(job)
                })
                .buttonStyle(.plain)
            } else {
                jobRow(job)
            }
        }
        if activeJobs.count > cap {
            Button(
                action: {
                    // ❌ NEVER remove the isOpen guard — mutating cap while
                    // the panel is open causes a height change → layout thrash.
                    if !popoverOpenState.isOpen { cap += 4 }
                },
                label: {
                    Text("+ \(activeJobs.count - cap) more jobs\u{2026}")
                        .font(.caption2).foregroundColor(.accentColor)
                        .padding(.leading, 24).padding(.trailing, 12).padding(.vertical, 2)
                }
            )
            .buttonStyle(.plain)
            // Belt-and-suspenders: also disable the button while open.
            .disabled(popoverOpenState.isOpen)
        }
    }

    private func jobRow(_ job: ActiveJob) -> some View {
        // ⚠️ TICK CONTRACT — DO NOT REMOVE.
        // tick is consumed here so SwiftUI re-evaluates jobRow on every 1s beat,
        // keeping elapsed in sync with ActionRowView.
        // ❌ NEVER remove this line.
        let _ = tick
        let currentStep = job.steps.first(where: { $0.status == "in_progress" })
        let stepName = currentStep.map(\.name).flatMap { $0.isEmpty ? nil : $0 }
        let done = job.steps.filter { $0.conclusion != nil }.count
        let total = job.steps.count
        return HStack(spacing: 6) {
            Text("\u{21B3}").font(.caption).foregroundColor(.secondary).frame(width: 16, alignment: .trailing)
            PieProgressDot(progress: job.progressFraction, color: jobDotColor(for: job), size: 7)
            Group {
                if let name = stepName {
                    // "JobName · StepName" — truncate at tail, step name yields to job name.
                    // lineLimit(1) is load-bearing (prevents height growth).
                    Text(job.name + " \u{00B7} " + name)
                } else {
                    Text(job.name)
                }
            }
            .font(.caption).foregroundColor(.secondary)
            .lineLimit(1).truncationMode(.tail)
            .layoutPriority(1)  // claim space before trailing numerics

            Spacer()

            if total > 0 {
                // "13/..." "11/..." — short numeric, never truncate.
                // fixedSize lets the panel grow rather than clipping step counts.
                // ❌ NEVER add frame(width:) here.
                Text("\(done)/\(total)")
                    .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            // Elapsed "01:29", "01:16" — 5 chars, never truncate.
            // ❌ NEVER add frame(width:) here.
            Text(job.elapsed)
                .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            // Chevron hint: only shown when rows are tappable.
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
        case "queued": return .blue
        default: return job.conclusion == "success" ? .green : (job.isDimmed ? .gray : .red)
        }
    }
}
