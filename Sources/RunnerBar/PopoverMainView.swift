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
// RULE 1: Root VStack uses .frame(idealWidth: 720, maxWidth: .infinity, alignment: .top)
//   idealWidth: 720 pins preferredContentSize.width = 720 (panel width never changes).
//   ❌ NEVER remove idealWidth: 720.
//   ❌ NEVER add idealHeight or maxHeight to the root frame.
//   ❌ NEVER use .frame(width: 720) — not equivalent.
//   ❌ NEVER use .fixedSize() on the root VStack.
//
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: RunnerStoreObservable.reload() uses withAnimation(nil).
//
// RULE 5: NO height caps on actionsSection.
//   With NSPanel, height caps are not needed. Content grows naturally.
//   AppDelegate.maxHeight (85% screen) prevents off-screen overflow at the panel level.
//   ❌ NEVER add .frame(maxHeight:) to actionsSection.
//   ❌ NEVER wrap actionsSection in ScrollView.
//   ❌ NEVER add .fixedSize() to actionsSection.
//
// RULE 6: systemStats MUST be paused while the panel is open.
//   SystemStatsViewModel fires every 2s, mutating @StateObject → SwiftUI re-render
//   → new preferredContentSize → KVO fires → resizeAndRepositionPanel().
//   While open: this is fine (panel just resizes smoothly, no jump).
//   While closed: systemStats should run to keep status icon updated.
//   Gate reads PopoverOpenState via @EnvironmentObject (live, never stale).
//   ❌ NEVER re-add `var isPopoverOpen: Bool` prop — frozen at construction.
//   ❌ NEVER remove .onChange(of: popoverOpenState.isOpen).
//
// RULE 6b: systemStats must RESTART when the main view becomes visible again.
//   onChange(of: popoverOpenState.isOpen) only fires on panel open/close — it
//   does NOT fire when the user navigates back from a drill-down view. Without
//   this rule the header shows zeroed stats after back-navigation.
//   Fix: call systemStats.start() inside PopoverHeaderView .onAppear (which
//   re-fires on every back-navigation). The onChange(open=true) stop-guard
//   still wins because isOpen is already true when the back-nav fires.
//   ❌ NEVER remove the systemStats.start() from PopoverHeaderView .onAppear.
//
// RULE 7: Timer calls LocalRunnerStore.refresh() + store.reload().
//   BOTH gated behind !popoverOpenState.isOpen.
//   ❌ NEVER remove this guard.
//   ❌ NEVER call LocalRunnerStore.shared.refresh() directly from Timer closure
//      — it is @MainActor isolated, requires Task { @MainActor in }.
//
// RULE 8: idealWidth is 720. AppDelegate.initPanelWidth is also 720.
//   ❌ NEVER change one without changing the other.
//
// RULE 9: displayTick fires every 1 second ALWAYS (no open-state gate).
//   Its sole purpose is to force ActionRowView and InlineJobRowsView to
//   re-render so elapsed strings, pie-chart progress and currentStep names
//   stay live while the panel is visible.
//   ❌ NEVER gate displayTick behind !popoverOpenState.isOpen.
//   ❌ NEVER merge with runnerRefreshTimer (that one IS gated and fires at 5s).
//
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.

struct PopoverMainView: View {
    @ObservedObject var store: RunnerStoreObservable
    let onSelectJob: (ActiveJob) -> Void
    let onSelectAction: (ActionGroup) -> Void
    let onSelectSettings: () -> Void
    /// Direct-to-JobDetailView navigation from inline ↳ job rows.
    /// Receives the tapped job and its parent group; AppDelegate navigates to
    /// detailViewFromAction(job:group:) so the back button returns to ActionDetailView.
    let onSelectInlineJob: (ActiveJob, ActionGroup) -> Void

    // ⚠️ RULE 6: Live open-state via @EnvironmentObject — NEVER a frozen Bool prop.
    // ❌ NEVER replace with var isPopoverOpen: Bool.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    // UNDER ANY CIRCUMSTANCE.
    @EnvironmentObject private var popoverOpenState: PopoverOpenState

    @State private var isAuthenticated = (githubToken() != nil)
    @StateObject private var systemStats = SystemStatsViewModel()
    @State private var visibleCount: Int = 10
    @State private var runnerRefreshTimer: Timer?

    // ⚠️ RULE 9: displayTick — 1-second render clock for live elapsed/progress.
    // Incremented every second, passed into ActionRowView and InlineJobRowsView.
    // ❌ NEVER gate behind !popoverOpenState.isOpen.
    // ❌ NEVER merge with runnerRefreshTimer.
    @State private var displayTick: Int = 0
    @State private var displayTickTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ⚠️ RULE 6b: .onAppear on PopoverHeaderView restarts systemStats on
            // back-navigation. This fires every time the main view becomes the
            // active route — including after returning from JobDetailView or
            // ActionDetailView. The onChange(open=true) guard wins when the panel
            // is open (isOpen=true → stop is called immediately after start).
            // ❌ NEVER remove this .onAppear.
            PopoverHeaderView(
                stats: systemStats.stats,
                isAuthenticated: isAuthenticated,
                onSelectSettings: onSelectSettings,
                onSignIn: signInWithGitHub
            )
            .onAppear {
                // Restart whenever main view becomes visible (back-nav or initial appear).
                // onChange handles the stop-on-open contract; this handles the
                // start-on-return contract.
                systemStats.start()
            }
            Divider()
            if store.isRateLimited { rateLimitBanner; Divider() }
            PopoverLocalRunnerRow(runners: store.runners)
                .onAppear {
                    Task { await MainActor.run { LocalRunnerStore.shared.refresh() } }
                }
            actionsSection
        }
        // RULE 1: idealWidth:720 pins preferredContentSize.width = 720 always.
        // ❌ NEVER add idealHeight or maxHeight here.
        .frame(idealWidth: 720, maxWidth: .infinity, alignment: .top)
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
        // ⚠️ RULE 6: systemStats gate via live @EnvironmentObject.
        // ❌ NEVER remove. ⚠️ macOS 13-compatible single-value onChange.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE.
        .onChange(of: popoverOpenState.isOpen) { open in
            if open { systemStats.stop() } else { systemStats.start() }
        }
        .onChange(of: store.actions) { _ in visibleCount = 10 }
    }

    // MARK: - Runner refresh timer (RULE 7 — gated, 5s)

    private func startRunnerRefreshTimer() {
        stopRunnerRefreshTimer()
        runnerRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            // ⚠️ RULE 7: gate on live @EnvironmentObject.
            // ❌ NEVER remove this guard.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE.
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
    // Drives live elapsed/progress re-renders in ActionRowView + InlineJobRowsView.
    // ❌ NEVER gate behind !popoverOpenState.isOpen.

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

    // MARK: - Actions section (RULE 5: no height cap — NSPanel handles screen bounds)

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.actions.isEmpty {
                Text("No recent actions")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                let visible = Array(store.actions.prefix(visibleCount))
                ForEach(visible) { group in
                    // Pass displayTick so SwiftUI sees a changed input every second
                    // and re-renders the row (elapsed, pie progress, step name).
                    ActionRowView(group: group, tick: displayTick, onSelect: { onSelectAction(group) })
                    if group.groupStatus == .inProgress && !group.jobs.isEmpty {
                        InlineJobRowsView(
                            group: group,
                            tick: displayTick,
                            onSelectJob: onSelectInlineJob
                        )
                    }
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
