import SwiftUI

// REGRESSION GUARD — DO NOT REMOVE - see regression history (ref #52 #54 #57 #375 #376 #377)
//
// ARCHITECTURE: NSPanel + sizingOptions=.preferredContentSize
// Dynamic height is achieved via KVO on NSHostingController.preferredContentSize.
// SwiftUI views report their natural ideal size. No height caps needed here.
//
// RULE 1: Root VStack uses .frame(minWidth: 280, maxWidth: 900, alignment: .top)
//
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: RunnerStoreObservable.reload() uses withAnimation(nil).
//
// RULE 5: actionsSection is wrapped in a ScrollView capped at screenScrollMaxHeight.
//   screenScrollMaxHeight = NSScreen.main.visibleFrame.height * 0.80.
//   ❌ NEVER remove the ScrollView from actionsSection.
//   ❌ NEVER use a GeometryReader or preference key for this cap.
//   ❌ NEVER add .frame(maxHeight:) to the root VStack instead.
//
// RULE 6: systemStats MUST be stopped while the panel is open.
// RULE 6b: systemStats must RESTART when the main view becomes visible again.
// RULE 7: Timer calls LocalRunnerStore.refresh() + store.reload().
// RULE 8: AppDelegate.initPanelWidth is 320.
// RULE 9: displayTick fires every 1 second ALWAYS (no open-state gate).

/// Root popover view rendered inside the NSPanel.
/// Owns the runner-refresh timer, display-tick timer, and system-stats lifecycle.
struct PopoverMainView: View {
    @ObservedObject var store: RunnerStoreObservable
    let onSelectJob: (ActiveJob) -> Void
    let onSelectAction: (ActionGroup) -> Void
    let onSelectSettings: () -> Void
    let onSelectInlineJob: (ActiveJob, ActionGroup) -> Void

    @EnvironmentObject private var popoverOpenState: PopoverOpenState

    @ObservedObject private var systemStats = SystemStatsViewModel.shared
    @State private var isAuthenticated = false
    @State private var visibleCount: Int = 10
    @State private var runnerRefreshTimer: Timer?
    @State private var displayTick: Int = 0
    @State private var displayTickTimer: Timer?

    /// Maximum height for the scrollable actions list.
    /// 80% of the visible screen height — matches AppDelegate's 85% panel cap
    /// minus ~5% headroom for the fixed header + runner rows above the list.
    /// ❌ NEVER replace with a GeometryReader/preference approach.
    private var screenScrollMaxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) * 0.80
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeaderView(
                statsVM: systemStats,
                isAuthenticated: isAuthenticated,
                onSelectSettings: onSelectSettings,
                onSignIn: signInWithGitHub
            )
            Divider()
            PopoverLocalRunnerRow(runners: store.runners)
                .onAppear {
                    Task { await MainActor.run { LocalRunnerStore.shared.refresh() } }
                }
            // RULE 5: scrollable actions list, capped at screenScrollMaxHeight.
            actionsSectionScrollable
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
        .onChange(of: popoverOpenState.isOpen) { open in
            if open { systemStats.stop() } else { systemStats.start() }
        }
        .onChange(of: store.actions) { _ in visibleCount = 10 }
    }

    // MARK: - Scrollable actions section (RULE 5)

    private var actionsSectionScrollable: some View {
        ScrollView(.vertical, showsIndicators: true) {
            actionsSectionContent
        }
        .frame(maxHeight: screenScrollMaxHeight)
    }

    private var actionsSectionContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.actions.isEmpty {
                Text("No recent actions")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                SectionHeaderLabel(title: "Actions")
                let visible = Array(store.actions.prefix(visibleCount))
                ForEach(visible) { group in
                    ActionRowView(group: group, tick: displayTick, onSelect: { onSelectAction(group) })
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

    // MARK: - Runner refresh timer (RULE 7 — gated, 10s)

    private func startRunnerRefreshTimer() {
        runnerRefreshTimer?.invalidate()
        runnerRefreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [self] _ in
            guard !popoverOpenState.isOpen else { return }
            Task { await MainActor.run { LocalRunnerStore.shared.refresh() } }
            store.reload()
        }
    }

    // MARK: - Display tick timer (RULE 9 — always fires, 1s)

    private func startDisplayTickTimer() {
        displayTickTimer?.invalidate()
        displayTickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            displayTick += 1
        }
    }

    // MARK: - Rate-limit banner

    @ViewBuilder
    private var rateLimitBanner: some View {
        if store.isRateLimited {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange).font(.system(size: 10))
                Text("GitHub API rate limited — retrying\u{2026}")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            Divider()
        }
    }

    // MARK: - Helpers

    private func signInWithGitHub() {
        NSWorkspace.shared.open(URL(string: "https://github.com/login/oauth/authorize")!)
    }
}
