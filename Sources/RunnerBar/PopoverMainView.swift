import SwiftUI

// MARK: - PopoverMainView

/// The root view rendered inside the NSPanel.
/// Composes the system-stats header, runner rows, and action rows.
struct PopoverMainView: View {
    // MARK: - Dependencies (injected)
    @ObservedObject var store: RunnerStoreObservable
    var onSelectRunner: ((Runner) -> Void)?
    var onSelectGroup:  ((ActionGroup) -> Void)?
    var onSelectJob:    ((ActiveJob, ActionGroup) -> Void)?
    var onSelectSettings: () -> Void = {}
    var onSelectAction:    ((ActionGroup) -> Void)?
    var onSelectInlineJob: ((ActiveJob, ActionGroup) -> Void)?

    // MARK: - Internal state
    @ObservedObject private var systemStats = SystemStatsViewModel.shared
    @State private var isAuthenticated = false
    @State private var tick: Int = 0
    @State private var runnerRefreshTimer: Timer?
    @State private var displayTickTimer: Timer?

    /// Renders the full popover panel: header, divider, runners, actions.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeaderView(
                stats: systemStats.stats,
                isAuthenticated: isAuthenticated,
                onSelectSettings: onSelectSettings,
                onSignIn: {},
                cpuHistory: systemStats.cpuHistory,
                memHistory: systemStats.memHistory,
                diskHistory: systemStats.diskHistory
            )
            .onAppear { systemStats.start() }
            Divider()
            if store.isRateLimited { rateLimitBanner; Divider() }
            ForEach(store.runners) { runner in
                PopoverLocalRunnerRow(runners: [runner])
            }
            .onAppear {
                Task { await MainActor.run { LocalRunnerStore.shared.refresh() } }
            }
            actionsSection
        }
        .frame(minWidth: 280, maxWidth: 900, alignment: .top)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            systemStats.start()
            startRunnerRefreshTimer()
            startDisplayTickTimer()
        }
        .onDisappear {
            runnerRefreshTimer?.invalidate()
            displayTickTimer?.invalidate()
            runnerRefreshTimer = nil
            displayTickTimer = nil
        }
    }

    // MARK: - Rate-limit banner

    private var rateLimitBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 10))
            Text("GitHub API rate limited — retrying\u{2026}")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    // MARK: - Actions section

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            if store.actions.isEmpty {
                emptyActionsPlaceholder
            } else {
                ForEach(store.actions) { group in
                    ActionRowView(
                        group: group,
                        tick: tick,
                        onSelect: { onSelectAction?(group) },
                        onSelectJob: onSelectInlineJob
                    )
                    Divider().padding(.leading, 12)
                }
            }
        }
    }

    private var emptyActionsPlaceholder: some View {
        Text(isAuthenticated ? "No recent workflow runs" : "Sign in to see workflow runs")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: - Timers

    private func startRunnerRefreshTimer() {
        runnerRefreshTimer?.invalidate()
        runnerRefreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { await store.reload() }
        }
    }

    private func startDisplayTickTimer() {
        displayTickTimer?.invalidate()
        displayTickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            tick += 1
        }
    }
}
