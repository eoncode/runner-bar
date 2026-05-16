import SwiftUI

// REGRESSION GUARD — DO NOT REMOVE - see regression history (ref #52 #54 #57 #375 #376 #377)
//
// ARCHITECTURE: NSPanel + sizingOptions=.preferredContentSize
// Dynamic height is achieved via KVO on NSHostingController.preferredContentSize.
// AppDelegate observes it and calls NSPanel.setFrame() — zero jump (no anchor).
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
//   This mirrors AppDelegate's 85% panel ceiling minus headroom for the header
//   and runner rows above the list. The ScrollView is transparent for short lists
//   (content fits, no scroll indicator) and activates only when expanded rows
//   would push content off screen.
//   ❌ NEVER remove the ScrollView from actionsSection.
//   ❌ NEVER use a GeometryReader or preference key for this cap — it freezes
//      at the initial layout height and prevents scrolling to expanded content.
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

    @EnvironmentObject private var popoverOpenState: PopoverOpenState

    @State private var isAuthenticated = (githubToken() != nil)
    @StateObject private var systemStats = SystemStatsViewModel()
    @State private var visibleCount: Int = 10
    @State private var runnerRefreshTimer: Timer?
    @State private var displayTick: Int = 0
    @State private var displayTickTimer: Timer?

    /// Maximum height for the scrollable actions list.
    /// 80% of the visible screen height — matches AppDelegate's 85% panel cap
    /// minus ~5% headroom for the fixed header + runner rows above the list.
    /// Computed fresh on each body evaluation so it always reflects current screen.
    /// ❌ NEVER replace with a GeometryReader/preference approach — it freezes
    ///    at initial layout height and breaks scrolling for expanded rows.
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
            .onAppear { systemStats.start() }
            Divider()
            if store.isRateLimited { rateLimitBanner; Divider() }
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
            if !popoverOpenState.isOpen { systemStats.start() }
            startRunnerRefreshTimer()
            startDisplayTickTimer()
        }
        .onDisappear {
            systemStats.stop()
            stopRunnerRefreshTimer()
            stopDisplayTickTimer()
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

    // MARK: - Runner refresh timer (RULE 7 — gated, 5s)

    private func startRunnerRefreshTimer() {
        stopRunnerRefreshTimer()
        runnerRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            if !self.popoverOpenState.isOpen {
                Task { @MainActor in LocalRunnerStore.shared.refresh() }
                self.store.reload()
            }
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

    // MARK: - Helpers

    private func signInWithGitHub() {
        let urlString = "https://docs.github.com/en/authentication/"
            + "keeping-your-account-and-data-secure/managing-your-personal-access-tokens"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
