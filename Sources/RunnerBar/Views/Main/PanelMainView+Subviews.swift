// PanelMainView+Subviews.swift
// RunnerBar
// swiftlint:disable colon opening_brace

import RunnerBarCore
import SwiftUI
// MARK: - SectionHeaderLabel
/// Uppercase small-caps label used as a section divider inside the panel.
/// Displays a title string in the muted secondary style.
struct SectionHeaderLabel: View {
    /// The title constant.
    let title: String
    /// The body property.
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
    /// The statsVM property.
    @ObservedObject var statsVM: SystemStatsViewModel
    /// The isAuthenticated constant.
    let isAuthenticated: Bool
    /// The onSelectSettings constant.
    let onSelectSettings: () -> Void
    /// The onSignIn constant.
    let onSignIn: () -> Void
    /// The body property.
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
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")
            Button(action: { NSApplication.shared.terminate(nil) }, label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            })
            .buttonStyle(.plain)
            .help("Quit RunnerBar")
            .accessibilityLabel("Quit RunnerBar")
        }
        .padding(.horizontal, DesignTokens.Spacing.rowHPad)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

// MARK: - RunnerTypeIcon
/// Small SF Symbol icon indicating whether a runner is local (self-hosted)
/// or a GitHub-hosted cloud runner.
private struct RunnerTypeIcon: View {
    /// The isLocal constant.
    let isLocal: Bool
    /// The body property.
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
    /// The cpu constant.
    let cpu: Double
    /// The mem constant.
    let mem: Double
    /// The body property.
    var body: some View {
        HStack(spacing: 8) {
            metricItem(label: "CPU", value: String(format: "%.0f%%", cpu))
            metricItem(label: "MEM", value: String(format: "%.0f%%", mem))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .statPillBackground()
    }
    /// Renders a label+value pair.
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
    /// The runners constant.
    let runners: [RunnerModel]
    /// The body property.
    var body: some View {
        if !runners.isEmpty { runnerList(runners) }
    }
    /// Renders a vertical stack of `runnerCard` views for each runner.
    @ViewBuilder private func runnerList(_ active: [RunnerModel]) -> some View {
        ForEach(active.prefix(3)) { runner in runnerCard(runner) }
        if active.count > 3 {
            Text("+ \(active.count - 3) more…")
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, DesignTokens.Spacing.rowHPad).padding(.vertical, 2)
        }
        Divider()
    }
    /// Compact card showing runner name with optional arch/platform inline,
    /// and a grouped CPU/MEM badge on the trailing edge.
    ///
    /// arch and platform are rendered as muted secondary text after the name,
    /// separated by middle dots (e.g. "psw-org-runner · arm64 · macOS").
    /// The meta tokens are hidden when both fields are nil.
    private func runnerCard(_ runner: RunnerModel) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Color.rbWarning).frame(width: 7, height: 7)
            // Name + optional arch/platform inline
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
    /// Parts are joined with a middle dot separator (·).
    private func runnerSubtitle(_ runner: RunnerModel) -> String? {
        let arch = runner.platformArchitecture.map { normaliseArch($0) }
        let os = runner.platform.map { normalisePlatform($0) }
        let parts = [arch, os].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Normalises raw architecture strings from the GitHub runner agent JSON.
    /// Maps "ARM64"→"arm64", "X64"→"x64", "X86"→"x86"; lowercases all others.
    private func normaliseArch(_ raw: String) -> String {
        switch raw.uppercased() {
        case "ARM64": return "arm64"
        case "X64":   return "x64"
        case "X86":   return "x86"
        default:      return raw.lowercased()
        }
    }

    /// Normalises raw platform strings from the GitHub runner agent JSON.
    /// Maps "osx"/"darwin"→"macOS", "linux"→"Linux", "win"→"Windows".
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
struct ActionRowView: View {
    /// The group constant.
    let group: WorkflowActionGroup
    /// The tick constant.
    let tick: Int
    /// The onStepTap constant.
    let onStepTap: (ActiveJob, JobStep) -> Void
    /// The expandState property.
    @State private var expandState: Bool?
    /// The previousStatus property.
    @State private var previousStatus: RBStatus?
    /// The body property.
    var body: some View {
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
        .background(
            ZStack {
                glassCardBackground
                Rectangle()
                    .fill(rowStatus.color)
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .clipShape(RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous))
        )
        .clipShape(RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous))
        .workflowContextMenu(group: group)
        .onTapGesture {
            guard !group.jobs.isEmpty else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                if expandState == true {
                    expandState = (rowStatus == .inProgress) ? false : nil
                } else {
                    expandState = true
                }
            }
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, RBSpacing.xxs)
        .onAppear {
            let status = rowStatus
            previousStatus = status
            expandState = (status == .inProgress) ? false : nil
        }
        .onChange(of: rowStatus) { _, newStatus in
            if newStatus == .inProgress && expandState == nil {
                withAnimation(.easeInOut(duration: 0.15)) { expandState = false }
            }
            if previousStatus == .inProgress && (newStatus == .success || newStatus == .failed) {
                withAnimation(.easeInOut(duration: 0.15)) { expandState = nil }
            }
            previousStatus = newStatus
        }
    }

    /// Glass card background for the action row.
    @ViewBuilder private var glassCardBackground: some View {
        Color.clear
            .glassCard(cornerRadius: RBRadius.card)
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
    /// Main body of the action row: workflow name, repo, branch, and trailing meta info.
    private var rowContent: some View {
        let tickSnapshot = tick
        return HStack(spacing: 6) {
            DonutStatusView(status: rowStatus, progress: group.progressFraction ?? 0, size: 14)
            RunnerTypeIcon(isLocal: group.isLocalGroup ?? false)
            Text(group.label)
                .font(DesignTokens.Fonts.mono).foregroundColor(.secondary).lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(group.title)
                .font(.system(size: 12))
                .foregroundColor(group.isDimmed ? .secondary : .primary)
                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
            if let branch = group.headBranch {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text(branch)
                        .font(DesignTokens.Fonts.mono)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 80, alignment: .leading)
                }
                .layoutPriority(0)
            }
            Spacer()
            metaTrailing(tick: tickSnapshot)
        }
        .padding(.trailing, RBSpacing.xs)
        .padding(.vertical, 4)
    }
    /// Trailing meta area: elapsed time or conclusion label, keyed off `tickSnapshot` for live updates.
    @ViewBuilder private func metaTrailing(tick tickSnapshot: Int) -> some View {
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
// swiftlint:enable colon opening_brace
