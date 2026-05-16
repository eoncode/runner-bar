import SwiftUI

// MARK: - SectionHeaderLabel
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
                Button(action: onSignIn, label: {
                    HStack(spacing: 4) {
                        Circle().fill(Color.orange).frame(width: 7, height: 7)
                        Text("Sign in").font(.caption2).foregroundColor(.secondary)
                    }
                })
                .buttonStyle(.plain).help("Sign in with GitHub")
            }
            Button(action: onSelectSettings, label: {
                Image(systemName: "gearshape").font(.system(size: 13)).foregroundColor(.secondary)
            })
            .buttonStyle(.plain).help("Settings")
            Button(action: { NSApplication.shared.terminate(nil) }, label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            })
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
struct PopoverLocalRunnerRow: View {
    let runners: [Runner]
    var body: some View {
        let busy = runners.filter { $0.busy }
        if !busy.isEmpty { runnerList(busy) }
    }

    @ViewBuilder
    private func runnerList(_ busy: [Runner]) -> some View {
        ForEach(busy.prefix(3)) { runner in runnerCard(runner) }
        if busy.count > 3 {
            Text("+ \(busy.count - 3) more\u{2026}")
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, DesignTokens.Spacing.rowHPad).padding(.vertical, 2)
        }
        Divider()
    }

    private func runnerCard(_ runner: Runner) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Color.rbWarning).frame(width: 7, height: 7)
            Text(runner.name).font(RBFont.label).foregroundColor(.primary).lineLimit(1).layoutPriority(1)
            Spacer()
            if let metrics = runner.metrics {
                StatPill(label: "CPU", value: String(format: "%.0f%%", metrics.cpu))
                StatPill(label: "MEM", value: String(format: "%.0f%%", metrics.mem))
            }
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.rbTextTertiary)
        }
        .padding(.horizontal, RBSpacing.md).padding(.vertical, RBSpacing.xs + 2)
        .background(
            RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous)
                .fill(Color.rbSurfaceElevated)
                .overlay(RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous).strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5))
        )
        .padding(.horizontal, RBSpacing.md).padding(.vertical, RBSpacing.xxs)
    }
}

// MARK: - ActionRowView
/// Expand behaviour (spec):
///   expandState == nil   → COMPACT (no jobs shown)
///     terminal rows (success/failed/queued) start here
///   expandState == false → AUTO-COMPACT (in_progress jobs only)
///     set by .onAppear for in-progress runs only, OR by onChange when
///     the row first transitions INTO inProgress (async store population)
///   expandState == true  → EXPANDED (all jobs)
///     set by user tapping the left pill
///
/// Auto-collapse on transition:
///   When a run transitions FROM inProgress → terminal (success/failed),
///   expandState is reset to nil so it collapses to compact.
///   This ONLY fires on an actual status change, NOT on every re-render.
///   Terminal rows that are already failed/success at appear time are
///   never auto-collapsed and remain fully user-controllable.
///
/// fix: async RunnerStore population means onAppear often fires before
///   groupStatus is inProgress. The onChange guard below catches the
///   first transition INTO inProgress so inline jobs always appear.
struct ActionRowView: View {
    let group: ActionGroup
    let tick: Int
    let onSelect: () -> Void

    /// nil = fully collapsed, false = auto-compact (in_progress jobs only), true = full expand
    @State private var expandState: Bool? = nil
    /// Tracks the last-seen status so onChange only reacts to genuine transitions.
    @State private var previousStatus: RBStatus? = nil

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous)
                .fill(Color.rbSurfaceElevated)
                .overlay(RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous).strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5))

            RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous).fill(rowStatus.tint)

            Button(
                action: {
                    guard !group.jobs.isEmpty else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if expandState == true {
                            expandState = (rowStatus == .inProgress) ? false : nil
                        } else {
                            expandState = true
                        }
                    }
                },
                label: {
                    // Half-pill indicator: a RoundedRectangle wide enough that its
                    // right rounded edge is clipped by the parent's clipShape, leaving
                    // only the left side of the pill visible — snug against the card's
                    // leading rounded corner.
                    RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous)
                        .fill(rowStatus.color)
                        .frame(width: RBRadius.card * 2)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, RBSpacing.xs)
                        .offset(x: -(RBRadius.card))
                }
            )
            .buttonStyle(.plain)
            .help(expandState == true ? "Collapse jobs" : "Expand jobs")

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: RBSpacing.md)
                    Button(action: onSelect, label: { rowContent }).buttonStyle(.plain)
                    Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary).padding(.trailing, 12)
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
            let s = rowStatus
            previousStatus = s
            // In-progress rows auto-expand to compact mode (in_progress jobs only).
            // Terminal/queued rows start fully collapsed — user must tap to expand.
            expandState = (s == .inProgress) ? false : nil
        }
        .onChange(of: rowStatus) { newStatus in
            // fix: RunnerStore populates async — onAppear often fires before
            // groupStatus is inProgress, leaving expandState == nil and hiding
            // inline jobs. Auto-expand the first time we see inProgress.
            // Guard: only expand if user hasn't manually collapsed (expandState == nil).
            // ⚠️ Never remove the expandState == nil guard — without it this would
            // override a user-triggered full-expand collapse back to auto-compact.
            if newStatus == .inProgress && expandState == nil {
                withAnimation(.easeInOut(duration: 0.15)) { expandState = false }
            }
            // ⚠️ Only auto-collapse when genuinely transitioning FROM inProgress
            // TO a terminal state. Without the previousStatus guard this fires
            // on every displayTick re-render for already-terminal rows, instantly
            // collapsing any user-triggered expand. Never remove previousStatus check.
            if previousStatus == .inProgress && (newStatus == .success || newStatus == .failed) {
                withAnimation(.easeInOut(duration: 0.15)) { expandState = nil }
            }
            previousStatus = newStatus
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
        let tickSnapshot = tick
        return HStack(spacing: 6) {
            DonutStatusView(status: rowStatus, progress: group.progressFraction ?? 0, size: 14)
            RunnerTypeIcon(isLocal: group.isLocalGroup)
            Text(group.label)
                .font(DesignTokens.Fonts.mono).foregroundColor(.secondary).lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(group.title)
                .font(.system(size: 12))
                .foregroundColor(group.isDimmed ? .secondary : .primary)
                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
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
                .font(DesignTokens.Fonts.mono).foregroundColor(.secondary).lineLimit(1)
                .fixedSize(horizontal: true, vertical: false).id(tickSnapshot)
        }
        if group.groupStatus == .inProgress || group.groupStatus == .queued {
            Text(group.currentJobName)
                .font(.caption).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.tail).layoutPriority(0)
        }
        Text(group.jobProgress)
            .font(DesignTokens.Fonts.mono).foregroundColor(.secondary).lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        Text(group.elapsed)
            .font(DesignTokens.Fonts.mono).foregroundColor(.secondary).lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        statusBadge
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch group.groupStatus {
        case .inProgress: StatusBadge(status: .inProgress, text: "IN PROGRESS")
        case .queued:     StatusBadge(status: .queued, text: "QUEUED")
        case .completed:
            switch group.conclusion {
            case "success": StatusBadge(status: .success, text: "SUCCESS")
            case "failure": StatusBadge(status: .failed, text: "FAILED")
            default:        StatusBadge(status: .unknown, text: "DONE")
            }
        }
    }
}
