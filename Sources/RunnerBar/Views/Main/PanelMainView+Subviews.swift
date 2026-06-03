// PanelMainView+Subviews.swift
// RunnerBar

import RunnerBarCore
import SwiftUI
// MARK: - SectionHeaderLabel
/// Uppercase small-caps label used as a section divider inside the panel.
/// Displays a title string in the muted secondary style.
struct SectionHeaderLabel: View {
    /// The title text displayed in uppercase.
    let title: String
    /// Renders the uppercased title in secondary caption color with standard panel insets.
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
/// Top bar of the popover panel showing the RunnerBar logo, sign-in state,
/// and the settings gear button.
struct PanelHeaderView: View {
    /// The stats view model driving the header sparklines.
    @ObservedObject var statsVM: SystemStatsViewModel
    /// Whether the user is currently authenticated with GitHub.
    let isAuthenticated: Bool
    /// Called when the user taps the settings gear button.
    let onSelectSettings: () -> Void
    /// Called when the user taps the sign-in button.
    let onSignIn: () -> Void
    /// Renders the header bar: system stats, sign-in button (shown when unauthenticated), settings and quit buttons.
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
            // macOS 26+: wrap both toolbar buttons in a single shared GlassEffectContainer
            // so they share a CABackdropLayer sampling region, enabling interactive glass
            // (scaling-on-press, shimmer, bounce) and morphing between sibling buttons.
            // Pre-26: falls back to .buttonStyle(.plain) as before.
            if #available(macOS 26, *) {
                // Each button gets its own GlassEffectContainer so their backdrops
                // stay independent (no bleed). HStack keeps them side-by-side.
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

    /// Settings gear button — shared between the macOS 26 glass path and pre-26 plain path.
    @ViewBuilder private var settingsButton: some View {
        Button(action: onSelectSettings, label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(width: 28, height: 28)
        })
        .buttonStyle(.plain)
        .help("Settings")
        .accessibilityLabel("Settings")
    }

    /// Quit button — shared between the macOS 26 glass path and pre-26 plain path.
    @ViewBuilder private var quitButton: some View {
        Button(action: { NSApplication.shared.terminate(nil) }, label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 28, height: 28)
        })
        .buttonStyle(.plain)
        .help("Quit RunnerBar")
        .accessibilityLabel("Quit RunnerBar")
    }
}

// MARK: - RunnerTypeIcon
/// Small SF Symbol icon indicating whether a runner is local (self-hosted)
/// or a GitHub-hosted cloud runner.
private struct RunnerTypeIcon: View {
    /// Whether the runner is self-hosted (local) or GitHub-hosted (cloud).
    let isLocal: Bool
    /// Renders a desktop or cloud SF Symbol in secondary color at 9 pt.
    var body: some View {
        Image(systemName: isLocal ? "desktopcomputer" : "cloud")
            .font(.system(size: 9))
            .foregroundColor(.secondary)
    }
}

// MARK: - RunnerMetricsBadge
/// Single grouped badge showing CPU and MEM for a runner inside one
/// shared glass background. Uses `.statPillBackground()` so macOS 26+
/// gets native Liquid Glass and pre-26 falls back to ultraThinMaterial.
private struct RunnerMetricsBadge: View {
    /// CPU usage percentage (0–100).
    let cpu: Double
    /// Memory usage percentage (0–100).
    let mem: Double
    /// Renders CPU and MEM labels in a shared glass badge.
    var body: some View {
        HStack(spacing: 8) {
            metricItem(label: "CPU", value: String(format: "%.0f%%", cpu))
            metricItem(label: "MEM", value: String(format: "%.0f%%", mem))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .statPillBackground()
    }
    /// Renders a single label + value pair inside the badge.
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
/// Renders a card for each runner passed in. Caller is responsible for
/// pre-filtering to only the runners that are currently active — this
/// view renders all entries it receives without internal re-filtering.
///
/// ❌ DO NOT add an isBusy filter here — isBusy is set by RunnerStatusEnricher
/// on a separate background cycle and will always lag behind the RunnerStore
/// fetch cycle, causing rows to be silently swallowed. (#948)
struct PanelLocalRunnerRow: View {
    /// Maximum number of runner cards shown inline before the overflow label.
    private static let maxVisibleRunners = 3
    /// The list of runners to display.
    let runners: [RunnerModel]
    /// Renders the runner card list, or nothing if `runners` is empty.
    var body: some View {
        if !runners.isEmpty { runnerList(runners) }
    }
    /// Renders a vertical stack of runner cards, capped at `maxVisibleRunners` with an overflow label.
    @ViewBuilder private func runnerList(_ active: [RunnerModel]) -> some View {
        ForEach(active.prefix(Self.maxVisibleRunners)) { runner in runnerCard(runner) }
        if active.count > Self.maxVisibleRunners {
            Text("+ \(active.count - Self.maxVisibleRunners) more…")
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, DesignTokens.Spacing.rowHPad).padding(.vertical, 2)
        }
        Divider()
    }
    /// Compact card showing runner name with optional arch/platform inline,
    /// and a grouped CPU/MEM badge on the trailing edge.
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
            if let metrics = runner.metrics {
                RunnerMetricsBadge(cpu: metrics.cpu, mem: metrics.mem)
            }
        }
        .padding(.horizontal, RBSpacing.md).padding(.vertical, RBSpacing.xs + 2)
        .glassCard(cornerRadius: RBRadius.card)
        .padding(.horizontal, RBSpacing.md).padding(.vertical, RBSpacing.xxs)
    }
    /// Builds a normalised subtitle string from architecture and platform fields.
    /// Returns nil when both are absent so the caller can hide the tokens entirely.
    private func runnerSubtitle(_ runner: RunnerModel) -> String? {
        let rawArch = runner.platformArchitecture
        let rawOS = runner.platform
        let arch = rawArch.map { normaliseArch($0) }
        let os = rawOS.map { normalisePlatform($0) }
        let parts = [arch, os].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    /// Normalises raw architecture strings. Maps "ARM64"→"arm64", "X64"→"x64", "X86"→"x86".
    private func normaliseArch(_ raw: String) -> String {
        switch raw.uppercased() {
        case "ARM64": return "arm64"
        case "X64":   return "x64"
        case "X86":   return "x86"
        default:      return raw.lowercased()
        }
    }
    /// Normalises raw platform strings. Maps "osx"/"darwin"→"macOS", "linux"→"Linux", "win"→"Windows".
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
/// Tapping expands inline job rows; long-press opens the run URL in Safari.
///
/// macOS 26+: the card background uses `.glassCard()` inside the shared `rowContainer`
/// background ZStack, identical structure to the pre-26 path. Animation is
/// `.easeInOut(duration: 0.15)` on both paths — matching main branch exactly.
///
/// ⚠️ Do NOT add GlassEffectContainer, .glassEffectID, .bouncy, or
/// .glassEffectTransition — they cause staggered/slow expand animations (#957).
struct ActionRowView: View {
    /// The workflow action group this row represents.
    let group: WorkflowActionGroup
    /// Timer tick driving live elapsed-time refresh.
    let tick: Int
    /// Called when the user taps a step inside an expanded job row.
    let onStepTap: (ActiveJob, JobStep) -> Void
    /// Tracks whether the inline job list is expanded (`true`), collapsed (`false`), or hidden (`nil`).
    @State private var expandState: Bool?
    /// The row status observed on the previous tick, used to detect transitions.
    @State private var previousStatus: RBStatus?
    /// Routes to the macOS 26+ glass path or the pre-26 legacy path.
    var body: some View {
        if #available(macOS 26, *) {
            rowContainer {
                // macOS 26+: glassCard rendered as background element inside rowContainer's ZStack.
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

    // MARK: Shared row container

    /// Shared layout structure used by both the macOS 26+ and pre-26 paths.
    /// Only the background layer differs between the two paths — all other
    /// modifiers (clip, content shape, context menu, tap, padding, lifecycle)
    /// are applied once here to eliminate duplication.
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
            ZStack {
                background()
            }
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

    // MARK: Shared helpers

    /// Left-edge status accent bar — 4 pt wide, clipped to the card shape.
    @ViewBuilder private var statusAccentBar: some View {
        Rectangle()
            .fill(rowStatus.color)
            .frame(width: 4)
            .frame(maxHeight: .infinity)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Glass card background used by the pre-26 path.
    /// Routes through `.glassCard()` — nothing outside `PanelViewModifiers` calls `.glassEffect()` directly.
    @ViewBuilder private var glassCardBackground: some View {
        Color.clear
            .glassCard(cornerRadius: RBRadius.card)
    }

    /// Sets the initial expand state based on the row's current status on first appearance.
    private func applyInitialExpandState() {
        let status = rowStatus
        previousStatus = status
        expandState = (status == .inProgress) ? false : nil
    }

    /// Reacts to row status changes, auto-expanding on inProgress and collapsing on completion.
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

    /// Resolves the effective display status for the row.
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

    /// Main body of the action row.
    ///
    /// Column order (#984):
    /// graph-dot · local-remote-icon · sha · repo-name · commit-title · branch-pill · Spacer
    /// · time-ago · steps/total · elapsed(mm:ss, active only) · statusBadge
    ///
    /// - sha: `group.label` (7-char sha or PR#), muted mono
    /// - repo-name: `group.repoShortName` stripped from owner/repo
    /// - branch: `BranchTagPill` capped at maxWidth 80, hidden when nil
    private var rowContent: some View {
        let tickSnapshot = tick
        return HStack(spacing: 6) {
            DonutStatusView(status: rowStatus, progress: group.progressFraction ?? 0, size: 14)
            RunnerTypeIcon(isLocal: group.isLocalGroup ?? false)
            // SHA (7-char or PR#)
            Text(group.label)
                .font(DesignTokens.Fonts.mono)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            // Repo name
            Text(group.repoShortName)
                .font(DesignTokens.Fonts.mono)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            // Commit title
            Text(group.title)
                .font(.system(size: 12))
                .foregroundColor(group.isDimmed ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            // Branch pill — hidden when nil. Uses BranchTagPill for consistent icon + truncation.
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

    /// Trailing meta: time-ago · steps/total · elapsed(mm:ss, active only) · statusBadge.
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
        // Elapsed shown only while running or queued — snaps off on completion to avoid a frozen clock.
        if group.groupStatus == .inProgress || group.groupStatus == .queued {
            Text(group.elapsed)
                .font(DesignTokens.Fonts.mono)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        statusBadge
    }

    /// Colored pill badge reflecting the current run status.
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
/// Applies the expand-on-tap interaction to an action row card.
/// Shared by both the macOS 26+ and pre-26 paths via `rowContainer` to
/// eliminate duplicated `.onTapGesture` blocks.
/// Animation is always `.easeInOut(duration: 0.15)` — do NOT add `.bouncy` (#957).
private struct RowTapModifier: ViewModifier {
    /// The jobs to inspect before allowing expansion.
    let jobs: [ActiveJob]
    /// Binding to the parent row's expand state.
    @Binding var expandState: Bool?
    /// Current display status of the row.
    let rowStatus: RBStatus

    /// Applies the tap gesture with easeInOut animation.
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
