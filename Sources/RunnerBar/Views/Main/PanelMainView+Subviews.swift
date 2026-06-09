// PanelMainView+Subviews.swift
// RunnerBar

import RunnerBarCore
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

// MARK: - PanelHeaderView
struct PanelHeaderView: View {
    @ObservedObject var statsVM: SystemStatsViewModel
    let onSelectSettings: () -> Void
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
private struct RunnerTypeIcon: View {
    let isLocal: Bool
    var body: some View {
        Image(systemName: isLocal ? "desktopcomputer" : "cloud")
            .font(.system(size: 9))
            .foregroundColor(.secondary)
    }
}

// MARK: - RunnerMetricsBadge
/// CPU + MEM badge for runner rows.
///
/// Always rendered (shows 0% until real metrics arrive) to prevent layout jump.
///
/// Glass architecture — identical to StatusBadge in ActionRowView.metaTrailing:
///   - Badge applies tint + .glassEffect(.regular, in: Capsule()) internally.
///   - Call site wraps badge in a standalone GlassEffectContainer (NOT nested
///     inside the card container) so it samples the real backdrop behind the panel.
///
/// ❌ Do NOT wrap the card itself in GlassEffectContainer — ActionRowView does not
///    do this and neither should runnerCard. Card glass is applied via .background{}.
private struct RunnerMetricsBadge: View {
    let cpu: Double
    let mem: Double
    var body: some View {
        HStack(spacing: 8) {
            metricItem(label: "CPU", value: String(format: "%.0f%%", cpu))
            metricItem(label: "MEM", value: String(format: "%.0f%%", mem))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .statPillBackground()
    }
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
/// ❌ DO NOT add an isBusy filter here — causes rows to be silently swallowed (#948).
struct PanelLocalRunnerRow: View {
    private static let maxVisibleRunners = 3
    let runners: [RunnerModel]
    var body: some View {
        if !runners.isEmpty { runnerList(runners) }
    }
    @ViewBuilder private func runnerList(_ active: [RunnerModel]) -> some View {
        ForEach(active.prefix(Self.maxVisibleRunners)) { runner in runnerCard(runner) }
        if active.count > Self.maxVisibleRunners {
            Text("+ \(active.count - Self.maxVisibleRunners) more…")
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, DesignTokens.Spacing.rowHPad).padding(.vertical, 2)
        }
        Divider()
    }

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

    private func runnerSubtitle(_ runner: RunnerModel) -> String? {
        let arch = runner.platformArchitecture.map { normaliseArch($0) }
        let os = runner.platform.map { normalisePlatform($0) }
        return [arch, os].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }
    private func normaliseArch(_ raw: String) -> String {
        switch raw.uppercased() {
        case "ARM64": return "arm64"
        case "X64":   return "x64"
        case "X86":   return "x86"
        default:      return raw.lowercased()
        }
    }
    private func normalisePlatform(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.hasPrefix("osx") || lower.hasPrefix("darwin") { return "macOS" }
        if lower.hasPrefix("linux") { return "Linux" }
        if lower.hasPrefix("win") { return "Windows" }
        return raw
    }
}

// MARK: - ActionRowView
/// ⚠️ Do NOT add GlassEffectContainer, .glassEffectID, .bouncy, or
/// .glassEffectTransition to the row or rowContainer — causes staggered/slow
/// expand animations (#957). The statusBadge GlassEffectContainer in metaTrailing
/// is intentionally scoped to just the badge, not the row.
struct ActionRowView: View {
    let group: WorkflowActionGroup
    let tick: Int
    let onStepTap: (ActiveJob, JobStep) -> Void
    @State private var expandState: Bool?
    @State private var previousStatus: RBStatus?
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

    @ViewBuilder private var statusAccentBar: some View {
        Rectangle()
            .fill(rowStatus.color)
            .frame(width: 4)
            .frame(maxHeight: .infinity)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var glassCardBackground: some View {
        Color.clear.glassCard(cornerRadius: RBRadius.card)
    }

    private func applyInitialExpandState() {
        let status = rowStatus
        previousStatus = status
        expandState = (status == .inProgress) ? false : nil
    }

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
