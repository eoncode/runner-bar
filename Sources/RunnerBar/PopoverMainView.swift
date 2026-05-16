import SwiftUI

// REGRESSION GUARD — DO NOT REMOVE - see regression history (ref #52 #54 #57 #375 #376 #377)
//
// ARCHITECTURE: NSPanel + sizingOptions=.preferredContentSize
// Dynamic height is achieved via KVO on NSHostingController.preferredContentSize.
// AppDelegate observes it and calls NSPanel.setFrame() — zero jump (no anchor).
// SwiftUI views report their natural ideal size. No height caps needed here.
//
// RULE 1: Root VStack uses .frame(minWidth: 280, maxWidth: 900, alignment: .top)
//   Dropping idealWidth lets SwiftUI report the natural content width as
//   preferredContentSize.width. The panel clamps between 280 and 900.
//   AppDelegate.resizeAndRepositionPanel() enforces these bounds at the NSPanel level.
//   Never add idealWidth here — it pins the width to a fixed value regardless of content.
//   Never add idealHeight or maxHeight to the root frame.
//   Never use .fixedSize() on the root VStack.
//   Never restore minWidth to 560 — that was the old fixed-width floor.
//
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: RunnerStoreObservable.reload() uses withAnimation(nil).
//
// RULE 5: NO height caps on actionsSection.
//   With NSPanel, height caps are not needed. Content grows naturally.
//   AppDelegate.maxHeight (85% screen) prevents off-screen overflow at the panel level.
//   Never add .frame(maxHeight:) to actionsSection.
//   Never wrap actionsSection in ScrollView.
//   Never add .fixedSize() to actionsSection.
//
// RULE 6: systemStats MUST be stopped while the panel is open.
//   SystemStatsViewModel fires every 2s, mutating @StateObject -> SwiftUI re-render
//   -> new preferredContentSize -> KVO fires -> resizeAndRepositionPanel().
//   While open: stats polling is stopped to prevent unnecessary re-renders/resizes.
//   While closed: stats polling runs to keep the header display current on next open.
//   Gate reads PopoverOpenState via @EnvironmentObject (live, never stale).
//   Never re-add `var isPopoverOpen: Bool` prop — frozen at construction.
//   Never remove .onChange(of: popoverOpenState.isOpen).
//
// RULE 6b: systemStats must RESTART when the main view becomes visible again.
//   onChange(of: popoverOpenState.isOpen) only fires on panel open/close — it
//   does NOT fire when the user navigates back from a drill-down view. Without
//   this rule the header shows zeroed stats after back-navigation.
//   Fix: call systemStats.start() inside PopoverHeaderView .onAppear (which
//   re-fires on every back-navigation). The onChange(open=true) stop-guard
//   still wins because isOpen is already true when the back-nav fires.
//   Never remove the systemStats.start() from PopoverHeaderView .onAppear.
//
// RULE 7: Timer calls LocalRunnerStore.refresh() + store.reload().
//   BOTH gated behind !popoverOpenState.isOpen.
//   Never remove this guard.
//   Never call LocalRunnerStore.shared.refresh() directly from Timer closure
//      — it is @MainActor isolated, requires Task { @MainActor in }.
//
// RULE 8: AppDelegate.initPanelWidth is 320 (initial open before SwiftUI measures).
//   Panel width is then content-driven, clamped 280-900 by resizeAndRepositionPanel.
//   Never add idealWidth back to this view.
//   Never restore initPanelWidth to 600 — that was over-wide.
//
// RULE 9: displayTick fires every 1 second ALWAYS (no open-state gate).
//   Its sole purpose is to force ActionRowView and InlineJobRowsView to
//   re-render so elapsed strings, pie-chart progress and currentStep names
//   stay live while the panel is visible.
//   Never gate displayTick behind !popoverOpenState.isOpen.
//   Never merge with runnerRefreshTimer (that one IS gated and fires at 5s).

/// Root popover view rendered inside the NSPanel.
/// Owns the runner-refresh timer, display-tick timer, and system-stats lifecycle.
struct PopoverMainView: View {
    /// The observable store driving the runner and action lists.
    @ObservedObject var store: RunnerStoreObservable
    /// Called when the user taps a job row to drill into job detail.
    let onSelectJob: (ActiveJob) -> Void
    /// Called when the user taps an action group row to drill into action detail.
    let onSelectAction: (ActionGroup) -> Void
    /// Called when the user taps the settings gear icon.
    let onSelectSettings: () -> Void

    @EnvironmentObject private var popoverOpenState: PopoverOpenState

    @State private var isAuthenticated = (githubToken() != nil)
    @StateObject private var systemStats = SystemStatsViewModel()
    @State private var visibleCount: Int = 10
    @State private var runnerRefreshTimer: Timer?
    @State private var displayTick: Int = 0
    @State private var displayTickTimer: Timer?

    /// Root layout: header -> divider -> local-runner row -> actions list.
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
            actionsSection
        }
        // RULE 1: content-driven width, clamped 280-900.
        // Never add idealWidth here.
        // Never add idealHeight or maxHeight here.
        // Never restore minWidth to 560 — that was the old fixed-width floor.
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

    // MARK: - Actions section (RULE 5: no height cap)

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
                    // BUG FIX: Do NOT render InlineJobRowsView here.
                    // ActionRowView already renders InlineJobRowsView internally
                    // when expanded=true. Rendering it here too caused duplicate
                    // job rows for in-progress groups.
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

    // MARK: - Helpers

    private func signInWithGitHub() {
        let urlString = "https://docs.github.com/en/authentication/"
            + "keeping-your-account-and-data-secure/managing-your-personal-access-tokens"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
