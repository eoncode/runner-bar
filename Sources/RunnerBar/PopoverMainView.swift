import SwiftUI

// ⚠️ REGRESSION GUARD — READ BEFORE CHANGING (ref #52 #54 #57 #375 #376 #377)
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.
//
// ARCHITECTURE: NSPanel + sizingOptions=.preferredContentSize
// Dynamic height is achieved via KVO on NSHostingController.preferredContentSize.
// AppDelegate observes it and calls NSPanel.setFrame() — zero jump (no anchor).
// SwiftUI views report their natural ideal size. No height caps needed here.
//
// RULE 1: Root VStack uses .frame(minWidth: 280, maxWidth: 900, alignment: .top)
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: RunnerStoreObservable.reload() uses withAnimation(nil).
// RULE 5: NO height caps on actionsSection.
// RULE 6: systemStats polls CONTINUOUSLY regardless of open state so sparkline
//         history always accumulates. Only runner/action refreshes are gated.
// RULE 6b: systemStats starts on onAppear and stops on onDisappear.
// RULE 7: Timer calls LocalRunnerStore.refresh() + store.reload() every 5s.
//         NOT gated behind isOpen — actions must update while popover is open.
// RULE 8: AppDelegate.initPanelWidth is 320.
// RULE 9: displayTick fires every 1 second ALWAYS (no open-state gate).
// RULE 10: InlineJobRowsView is now owned by ActionRowView (not this file).
// RULE 11: systemStats is SystemStatsViewModel.shared (singleton) — NEVER @StateObject.
//          Changing this back to @StateObject wipes sparkline history on every close.
//
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.

/// Root navigation host for the NSPanel popover.
/// Owns the runner-refresh timer, display-tick timer, and navigation routing.
struct PopoverMainView: View {
    /// The observable store driving all displayed data.
    @ObservedObject var store: RunnerStoreObservable
    /// Called when the user taps a job row to drill into job detail.
    let onSelectJob: (ActiveJob) -> Void
    /// Called when the user taps an action group row.
    let onSelectAction: (ActionGroup) -> Void
    /// Called when the user taps the settings gear.
    let onSelectSettings: () -> Void
    /// Called when the user taps an inline job chip inside an action row.
    let onSelectInlineJob: (ActiveJob, ActionGroup) -> Void

    @EnvironmentObject private var popoverOpenState: PopoverOpenState

    @State private var isAuthenticated = (githubToken() != nil)
    // ⚠️ RULE 11 — singleton, NOT @StateObject. History must survive close/reopen.
    @ObservedObject private var systemStats = SystemStatsViewModel.shared
    @State private var visibleCount: Int = 10
    @State private var runnerRefreshTimer: Timer?
    @State private var displayTick: Int = 0
    @State private var displayTickTimer: Timer?

    /// Renders the full popover panel: header, divider, runners, actions.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeaderView(
                stats: systemStats.stats,
                isAuthenticated: isAuthenticated,
                onSelectSettings: onSelectSettings,
                onSignIn: signInWithGitHub,
                cpuHistory: systemStats.cpuHistory,
                memHistory: systemStats.memHistory,
                diskHistory: systemStats.diskHistory
            )
            .onAppear { systemStats.start() }
            Divider()
            if store.isRateLimited { rateLimitBanner; Divider() }
            PopoverLocalRunnerRow(runners: store.runners)
                .onAppear {
                    Task { await MainActor.run { LocalRunnerStore.shared.refresh() } }
                }
            actionsSection
        }
        .frame(minWidth: 280, maxWidth: 900, alignment: .top)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            systemStats.start()  // no-op if already running — singleton
            startRunnerRefreshTimer()
            startDisplayTickTimer()
        }
        .onDisappear {
            // Do NOT stop systemStats — singleton must keep accumulating history
            stopRunnerRefreshTimer()
            stopDisplayTickTimer()
        }
        .onChange(of: store.actions) { _ in visibleCount = 10 }
    }

    // MARK: - Runner refresh timer (RULE 7 — ungated, 5s)

    private func startRunnerRefreshTimer() {
        stopRunnerRefreshTimer()
        // ⚠️ RULE 7: NOT gated behind !isOpen — actions must poll while popover is open.
        runnerRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in LocalRunnerStore.shared.refresh() }
            self.store.reload()
        }
    }

    private func stopRunnerRefreshTimer() {
        runnerRefreshTimer?.invalidate()
        runnerRefreshTimer = nil
    }

    // MARK: - Display tick timer (RULE 9 — ungated, 1s)

    private func startDisplayTickTimer() {
        stopDisplayTickTimer()
        displayTickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            self.displayTick &+= 1
        }
    }

    private func stopDisplayTickTimer() {
        displayTickTimer?.invalidate()
        displayTickTimer = nil
    }

    // MARK: - Rate limit banner

    private var rateLimitBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow).font(.caption)
            Text("GitHub rate limit reached — pausing polls")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    // MARK: - Actions section

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.actions.isEmpty {
                Text("No recent actions")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                SectionHeaderLabel(title: "Actions")
                let visible = Array(store.actions.prefix(visibleCount))
                ForEach(visible) { group in
                    ActionRowView(
                        group: group,
                        tick: displayTick,
                        onSelect: { onSelectAction(group) },
                        onSelectJob: onSelectInlineJob
                    )
                }
                loadMoreButton
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var loadMoreButton: some View {
        let nextBatch = min(10, store.actions.count - visibleCount)
        if nextBatch > 0 {
            Button(
                action: { visibleCount += nextBatch },
                label: {
                    Text("Load \(nextBatch) more actions\u{2026}")
                        .font(.caption).foregroundColor(.secondary)
                }
            )
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    // MARK: - Helpers

    private func signInWithGitHub() {
        let urlString = "https://docs.github.com/en/authentication/"
            + "keeping-your-account-and-data-secure/managing-your-personal-access-tokens"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
