// PanelMainView+Subviews.swift
// RunnerBar

import RunnerBarCore
import SwiftUI

// MARK: - SectionHeaderLabel
/// Uppercase small-caps label used as a section divider inside the panel.
struct SectionHeaderLabel: View {
    /// The raw title string; displayed uppercased.
    let title: String

    /// Renders the uppercased title with section-caption font and secondary colour.
    var body: some View {
        Text(title.uppercased())
            .font(RBFont.sectionCaption)
            .foregroundColor(.secondary)
            .padding(.horizontal, DesignTokens.Spacing.rowHPad)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

// MARK: - PanelHeaderView
/// Top bar of the popover panel showing system stats and the settings/quit buttons.
struct PanelHeaderView: View {
    /// View model driving the CPU/MEM/disk stat pills.
    @ObservedObject var statsVM: SystemStatsViewModel
    /// Called when the user taps the settings gear button.
    let onSelectSettings: () -> Void

    /// Renders the header HStack with stats bar and settings/quit buttons.
    var body: some View {
        HStack(spacing: 6) {
            HeaderStatsBar(statsVM: statsVM)
            Spacer()
            if #available(macOS 26, *) {
                HStack(spacing: 8) {
                    GlassEffectContainer { settingsButton.glassButton() }
                    GlassEffectContainer { quitButton.glassButton() }
                }
            } else {
                settingsButton
                quitButton
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.rowHPad)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// Settings gear button — plain style, 28 pt hit area.
    @ViewBuilder private var settingsButton: some View {
        Button(action: onSelectSettings) {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help("Settings")
        .accessibilityLabel("Settings")
    }

    /// Quit button — plain style, 28 pt hit area.
    @ViewBuilder private var quitButton: some View {
        Button(action: { NSApplication.shared.terminate(nil) }) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help("Quit RunnerBar")
        .accessibilityLabel("Quit RunnerBar")
    }
}

// MARK: - RunnerTypeIcon
/// Small icon indicating whether a runner is local (desktop) or cloud-hosted.
private struct RunnerTypeIcon: View {
    /// `true` for a self-hosted local runner, `false` for a cloud runner.
    let isLocal: Bool

    /// Renders the appropriate SF Symbol for the runner type.
    var body: some View {
        Image(systemName: isLocal ? "desktopcomputer" : "cloud")
            .font(.system(size: 9))
            .foregroundColor(.secondary)
    }
}

// MARK: - RunnerMetricsBadge
/// Single grouped badge showing CPU and MEM for a runner inside one shared glass background.
///
/// Always rendered regardless of whether live metrics are available — shows 0% on
/// cycle 1 to prevent layout jump when real values arrive on cycle 2.
///
/// macOS 26+: MUST be wrapped in its OWN `GlassEffectContainer` at the call site
/// (separate from the card container). Sharing the card’s container means the pill
/// glass samples the card backdrop — near-zero contrast. Its own container gives
/// a fresh dedicated CABackdropLayer sampling region, same pattern as StatusBadge
/// in metaTrailing. Pre-26: falls back to `.ultraThinMaterial` capsule.
///
/// ❌ Do NOT wrap the card itself in GlassEffectContainer — ActionRowView does not
///    do this and neither should runnerCard. Card glass is applied via .background{}.
private struct RunnerMetricsBadge: View {
    /// CPU utilisation percentage (0–100).
    let cpu: Double
    /// Memory utilisation percentage (0–100).
    let mem: Double

    /// Renders CPU and MEM metric items inside a `statPillBackground` capsule.
    var body: some View {
        HStack(spacing: 8) {
            metricItem(label: "CPU", value: String(format: "%.0f%%", cpu))
            metricItem(label: "MEM", value: String(format: "%.0f%%", mem))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .statPillBackground()
    }
    /// Renders a single label–value pair for use inside the badge HStack.
    private func metricItem(label: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(RBFont.statLabel)
                .foregroundColor(.secondary)
            Text(value)
                .font(RBFont.statValue)
                .foregroundColor(.primary)
                .monospacedDigit()
        }
    }
}

// MARK: - PanelLocalRunnerRow
/// Renders a card for each runner passed in.
///
/// ❌ DO NOT add an isBusy filter here — isBusy is set by RunnerStatusEnricher
/// on a separate background cycle and will always lag behind the RunnerStore
/// fetch cycle, causing rows to be silently swallowed. (#948)
struct PanelLocalRunnerRow: View {
    private static let maxVisibleRunners = 3
    /// The runners to display. Up to `maxVisibleRunners` are shown; a “+ N more…”
    /// label is appended when the list exceeds that limit.
    let runners: [RunnerModel]

    /// Renders the runner list when non-empty, otherwise produces no view.
    var body: some View {
        if !runners.isEmpty { runnerList(runners) }
    }

    /// Renders up to `maxVisibleRunners` runner cards followed by a divider.
    @ViewBuilder private func runnerList(_ active: [RunnerModel]) -> some View {
        ForEach(active.prefix(Self.maxVisibleRunners)) { runner in runnerCard(runner) }
        if active.count > Self.maxVisibleRunners {
            Text("+ \(active.count - Self.maxVisibleRunners) more…")
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, DesignTokens.Spacing.rowHPad).padding(.vertical, 2)
        }
        Divider()
    }

    /// Runner card with CPU/MEM badge.
    ///
    /// Glass architecture mirrors ActionRowView exactly:
    ///   - .glassCard() applied via .background{} directly — NO GlassEffectContainer around the card.
    ///   - RunnerMetricsBadge gets its own standalone GlassEffectContainer, same as
    ///     StatusBadge in ActionRowView.metaTrailing.
    private func runnerCard(_ runner: RunnerModel) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Color.rbWarning).frame(width: 7, height: 7)
            HStack(spacing: 4) {
                Text(runner.runnerName)
                    .font(RBFont.label)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if let subtitle = runnerSubtitle(runner) {
                    Text("· \(subtitle)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer()
            // Standalone GlassEffectContainer — same as StatusBadge in metaTrailing.
            // NOT nested inside a card container so it samples the real backdrop.
            if #available(macOS 26, *) {
                GlassEffectContainer {
                    RunnerMetricsBadge(
                        cpu: runner.metrics?.cpu ?? 0,
                        mem: runner.metrics?.mem ?? 0
                    )
                }
            } else {
                RunnerMetricsBadge(
                    cpu: runner.metrics?.cpu ?? 0,
                    mem: runner.metrics?.mem ?? 0
                )
            }
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, RBSpacing.xs + 2)
        .frame(maxWidth: .infinity)
        .background {
            // Same as ActionRowView: .glassCard() in .background{}, no wrapping container.
            if #available(macOS 26, *) {
                Color.clear.glassCard(cornerRadius: RBRadius.card)
            } else {
                Color.clear.glassCard(cornerRadius: RBRadius.card)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous))
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, RBSpacing.xxs)
    }

    /// Returns a formatted subtitle string combining architecture and OS platform, or `nil` if neither is available.
    private func runnerSubtitle(_ runner: RunnerModel) -> String? {
        let arch = runner.platformArchitecture.map { normaliseArch($0) }
        let os = runner.platform.map { normalisePlatform($0) }
        return [arch, os].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }
    /// Normalises a raw architecture string to a canonical lowercase form.
    private func normaliseArch(_ raw: String) -> String {
        switch raw.uppercased() {
        case "ARM64": return "arm64"
        case "X64":   return "x64"
        case "X86":   return "x86"
        default:      return raw.lowercased()
        }
    }
    /// Normalises a raw platform string to a human-readable OS name.
    private func normalisePlatform(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.hasPrefix("osx") || lower.hasPrefix("darwin") { return "macOS" }
        if lower.hasPrefix("linux") { return "Linux" }
        if lower.hasPrefix("win") { return "Windows" }
        return raw
    }
}

// MARK: - ActionRowView
/// Row representing one GitHub Actions workflow run.
///
/// ⚠️ Do NOT add GlassEffectContainer, .glassEffectID, .bouncy, or
/// .glassEffectTransition to the row or rowContainer — they cause staggered/slow
/// expand animations (#957). The statusBadge GlassEffectContainer in metaTrailing
/// is intentionally scoped to just the badge, not the row.
struct ActionRowView: View {
    /// The workflow action group this row represents.
    let group: WorkflowActionGroup
    /// Poll tick counter used to force time-ago label refreshes.
    let tick: Int
    /// Called when the user taps a step inside the expanded inline job rows.
    let onStepTap: (ActiveJob, JobStep) -> Void
    /// Drives the inline expand/collapse state: `nil` = collapsed, `false` = partially expanded, `true` = fully expanded.
    @State private var expandState: Bool?
    /// Tracks the previous row status to detect in-progress → done transitions.
    @State private var previousStatus: RBStatus?

    /// Renders the row using the appropriate glass card background for the current OS.
    var body: some View {
        if #available(macOS 26, *) {
            rowContainer {
                Color.clear.glassCard(cornerRadius: RBRadius.card)
                statusAccentBar
            }
        } else {
            rowContainer {
                glassCardBackground
                statusAccentBar
            }
        }
    }

    /// Wraps `rowContent` (and optionally `InlineJobRowsView`) in a card-shaped container
    /// with the supplied glass background.
    @ViewBuilder
    private func rowContainer<Background: View>(@ViewBuilder background: () -> Background) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: RBSpacing.md)
                rowContent
            }
            if let fullExpand = expandState {
                InlineJobRowsView(group: group, tick: tick, fullExpand: fullExpand, onStepTap: onStepTap)
            }
        }
        .frame(maxWidth: .infinity)
        .background {
            ZStack { background() }
            .clipShape(RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous))
        }
        .clipShape(RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous))
        .workflowContextMenu(group: group)
        .modifier(RowTapModifier(jobs: group.jobs, expandState: $expandState, rowStatus: rowStatus))
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, RBSpacing.xxs)
        .onAppear { applyInitialExpandState() }
        .onChange(of: rowStatus) { _, newStatus in handleStatusChange(newStatus) }
    }

    /// Left-edge accent bar whose colour reflects the current row status.
    @ViewBuilder private var statusAccentBar: some View {
        Rectangle()
            .fill(rowStatus.color)
            .frame(width: 4)
            .frame(maxHeight: .infinity)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Pre-macOS-26 glass card background used as the ZStack layer inside `rowContainer`.
    @ViewBuilder private var glassCardBackground: some View {
        Color.clear.glassCard(cornerRadius: RBRadius.card)
    }

    /// Sets the initial expand state based on the row’s status at appear time.
    private func applyInitialExpandState() {
        let status = rowStatus
        previousStatus = status
        expandState = (status == .inProgress) ? false : nil
    }

    /// Animates expand state transitions when the row status changes.
    private func handleStatusChange(_ newStatus: RBStatus) {
        let animation: Animation = .easeInOut(duration: 0.15)
        if newStatus == .inProgress && expandState == nil {
            withAnimation(animation) { expandState = false }
        }
        if previousStatus == .inProgress && (newStatus == .success || newStatus == .failed) {
            withAnimation(animation) { expandState = nil }
        }
        previousStatus = newStatus
    }

    /// Derives the canonical `RBStatus` from the group’s status and conclusion.
    private var rowStatus: RBStatus {
        switch group.groupStatus {
        case .inProgress: return .inProgress
        case .queued: return .queued
        case .completed:
            switch group.conclusion {
            case "success": return .success
            case "failure": return .failed
            default: return .unknown
            }
        }
    }

    /// HStack containing the donut, runner type icon, labels, branch pill, and trailing meta.
    private var rowContent: some View {
        let tickSnapshot = tick
        return HStack(spacing: 6) {
            DonutStatusView(status: rowStatus, progress: group.progressFraction ?? 0, size: 14)
            RunnerTypeIcon(isLocal: group.isLocalGroup ?? false)
            Text(group.label)
                .font(DesignTokens.Fonts.mono)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(group.repoShortName)
                .font(DesignTokens.Fonts.mono)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(group.title)
                .font(.system(size: 12))
                .foregroundColor(group.isDimmed ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if let branch = group.headBranch {
                BranchTagPill(name: branch)
                    .frame(maxWidth: 80, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(0)
            }
            Spacer()
            metaTrailing(tick: tickSnapshot)
        }
        .padding(.trailing, RBSpacing.xs)
        .padding(.vertical, 4)
    }

    /// statusBadge wrapped in its own standalone GlassEffectContainer — scoped to badge only.
    /// ⚠️ Do NOT expand this container to the row or rowContainer (#957).
    @ViewBuilder private func metaTrailing(tick tickSnapshot: Int) -> some View {
        if let start = group.firstJobStartedAt {
            Text(RelativeTimeFormatter.string(from: start))
                .font(DesignTokens.Fonts.mono)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .id(tickSnapshot)
        }
        if !group.jobs.isEmpty {
            Text(group.jobProgress)
                .font(DesignTokens.Fonts.mono)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        if group.groupStatus == .inProgress || group.groupStatus == .queued {
            Text(group.elapsed)
                .font(DesignTokens.Fonts.mono)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        if #available(macOS 26, *) {
            GlassEffectContainer { statusBadge }
        } else {
            statusBadge
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch group.groupStatus {
        case .inProgress: StatusBadge(status: .inProgress, text: "IN PROGRESS")
        case .queued: StatusBadge(status: .queued, text: "QUEUED")
        case .completed:
            switch group.conclusion {
            case "success": StatusBadge(status: .success, text: "SUCCESS")
            case "failure": StatusBadge(status: .failed, text: "FAILED")
            default: StatusBadge(status: .unknown, text: "DONE")
            }
        }
    }
}

// MARK: - RowTapModifier
/// Animation is always `.easeInOut(duration: 0.15)` — do NOT add `.bouncy` (#957).
private struct RowTapModifier: ViewModifier {
    let jobs: [ActiveJob]
    @Binding var expandState: Bool?
    let rowStatus: RBStatus
    func body(content: Content) -> some View {
        content.onTapGesture {
            guard !jobs.isEmpty else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                if expandState == true {
                    expandState = (rowStatus == .inProgress) ? false : nil
                } else {
                    expandState = true
                }
            }
        }
    }
}

// MARK: - String+nilIfEmpty
private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
