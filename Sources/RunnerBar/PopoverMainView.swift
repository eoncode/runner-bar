import SwiftUI

// ⚠️ REGRESSION GUARD — frame + padding rules (ref #52 #54 #57 #375 #376 #377)
//
// RULE 1: Root VStack MUST use .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
//         AppDelegate uses sizingOptions=.preferredContentSize. idealWidth pins the
//         measurement width to 480. ❌ NEVER remove .frame(idealWidth: 480).
//         ❌ NEVER use .frame(width: 480). ❌ NEVER remove maxWidth: .infinity.
//         ❌ NEVER add .frame(height:) or .frame(maxHeight:) to root VStack.
//
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: NEVER use .fixedSize() on the root VStack.
// RULE 5: RunnerStoreObservable.reload() uses withAnimation(nil).
//
// RULE 6: actionsSection MUST NOT be wrapped in ScrollView at the top level.
//         It uses a ScrollView internally (with .frame(maxHeight: 620)) to cap the
//         popover height and allow scrolling for long action lists.
//         ❌ NEVER remove the inner ScrollView's .frame(maxHeight: 620).
//         ❌ NEVER wrap the actionsSection VStack in an OUTER ScrollView.
//         ❌ NEVER remove .frame(maxHeight: 620) — without it, a long action list
//            makes preferredContentSize.height unbounded → popover overflows screen.
//         If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//         UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
//         is major major major.
//
// RULE 7: The 5 s timer calls LocalRunnerStore.shared.refresh() + store.reload().
//         BOTH are gated behind !popoverOpenState.isOpen.
//         LocalRunnerStore.shared.refresh() is @MainActor-isolated and MUST be called
//         via Task { @MainActor in ... } from the nonisolated Timer closure.
//         ❌ NEVER call store.reload() while popoverOpenState.isOpen == true.
//         ❌ NEVER call LocalRunnerStore.shared.refresh() while popoverOpenState.isOpen.
//         ❌ NEVER remove the !popoverOpenState.isOpen guard from the timer.
//         ❌ NEVER call LocalRunnerStore.shared.refresh() directly from the Timer closure
//            — it is @MainActor isolated and requires Task { @MainActor in }.
//         If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//         UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
//         is major major major.
//
// RULE 8: idealWidth is 480. AppDelegate.fixedWidth is also 480.
//         ❌ NEVER change one without changing the other.
//
// RULE 9: systemStats MUST be paused while the popover is open.
//         SystemStatsViewModel fires every 2 s, mutating @StateObject → SwiftUI re-render
//         → preferredContentSize update → NSPopover re-anchor → side jump every 2 s.
//         systemStats gate reads PopoverOpenState via @EnvironmentObject (live, not stale).
//         popoverOpenState.isOpen is set TRUE before show() in AppDelegate.openPopover().
//         This ensures systemStats.stop() fires on the FIRST SwiftUI render after show().
//         ❌ NEVER remove the .onChange(of: popoverOpenState.isOpen) systemStats gate.
//         ❌ NEVER read isPopoverOpen from a frozen Bool prop — always @EnvironmentObject.
//         If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//         UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
//         is major major major.
//
// RULE 10: onContentChanged is called by loadMoreButton after expanding the list.
//          AppDelegate MAY use it to respond to list expansion.
//          ❌ NEVER remove onContentChanged from loadMoreButton action.
//          If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//          UNDER ANY CIRCUMSTANCE.
//
// RULE 11: isPopoverOpen MUST NOT be a Bool prop on this view.
//          The frozen Bool snapshot was the ROOT CAUSE of the side-jump bug:
//          systemStats.stop() fired AFTER show() (async prop propagation) instead of
//          BEFORE, letting the 2s timer trigger a re-render and re-anchor.
//          ✅ Always read liveness from @EnvironmentObject PopoverOpenState.
//          ❌ NEVER add var isPopoverOpen: Bool back to this view.
//          If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//          UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
//          is major major major.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.

struct PopoverMainView: View {
    @ObservedObject var store: RunnerStoreObservable
    let onSelectJob: (ActiveJob) -> Void
    let onSelectAction: (ActionGroup) -> Void
    let onSelectSettings: () -> Void
    /// Called after the "Load more" button expands the list.
    /// ❌ NEVER remove from loadMoreButton action.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    var onContentChanged: (() -> Void)? = nil

    // ⚠️ RULE 9 + RULE 11: Read liveness from @EnvironmentObject, NOT a frozen Bool prop.
    // popoverOpenState.isOpen is set TRUE before show() in AppDelegate.openPopover().
    // This makes systemStats.stop() fire on the FIRST render, before the 2s timer fires.
    // ❌ NEVER replace this with a Bool prop — frozen snapshot causes side jumps.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    // UNDER ANY CIRCUMSTANCE.
    @EnvironmentObject private var popoverOpenState: PopoverOpenState

    @State private var isAuthenticated = (githubToken() != nil)
    @StateObject private var systemStats = SystemStatsViewModel()
    @State private var visibleCount: Int = 10
    @State private var runnerRefreshTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeaderView(
                stats: systemStats.stats,
                isAuthenticated: isAuthenticated,
                onSelectSettings: onSelectSettings,
                onSignIn: signInWithGitHub
            )
            Divider()
            if store.isRateLimited { rateLimitBanner; Divider() }
            PopoverLocalRunnerRow(runners: store.runners)
                .onAppear { Task { await MainActor.run { LocalRunnerStore.shared.refresh() } } }
            // ⚠️ RULE 6: actionsSection is inside a ScrollView with maxHeight cap.
            // This bounds preferredContentSize.height for long action lists.
            // ❌ NEVER remove the ScrollView or the .frame(maxHeight: 620).
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE.
            ScrollView {
                actionsSection
            }
            .frame(maxHeight: 620)
        }
        // RULE 1: idealWidth:480 is LOAD-BEARING for preferredContentSize width pinning.
        // ❌ NEVER add .frame(height:) or .frame(maxHeight:) here — the ScrollView above handles it.
        .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            // ⚠️ RULE 9: On appear, sync with current popoverOpenState.isOpen.
            // popoverOpenState.isOpen is already true when the popover just opened.
            if !popoverOpenState.isOpen { systemStats.start() }
            startRunnerRefreshTimer()
        }
        .onDisappear {
            systemStats.stop()
            stopRunnerRefreshTimer()
        }
        // ⚠️ RULE 9: systemStats gate — reads live @EnvironmentObject, not stale prop.
        // ❌ NEVER remove. ❌ NEVER replace with onChange of a Bool prop.
        // ⚠️ macOS 13-compatible single-value onChange — ❌ NEVER use { _, _ in }.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
        // is major major major.
        .onChange(of: popoverOpenState.isOpen) { open in
            if open { systemStats.stop() } else { systemStats.start() }
        }
        .onChange(of: store.actions) { _ in visibleCount = 10 }
    }

    // MARK: - Runner refresh timer (RULE 7)

    private func startRunnerRefreshTimer() {
        stopRunnerRefreshTimer()
        runnerRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            // ⚠️ RULE 7: Gate on popoverOpenState.isOpen (live @EnvironmentObject value).
            // ❌ NEVER remove this guard (RULE 7).
            // ❌ LocalRunnerStore.shared.refresh() is @MainActor-isolated — MUST use
            //   Task { @MainActor in } from this nonisolated Timer closure.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this
            // comment is removed is major major major.
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
                let visible = Array(store.actions.prefix(visibleCount))
                ForEach(visible) { group in
                    ActionRowView(group: group, onSelect: { onSelectAction(group) })
                    if group.groupStatus == .inProgress && !group.jobs.isEmpty {
                        // ✅ InlineJobRowsView reads isPopoverOpen via @EnvironmentObject PopoverOpenState
                        // ❌ NEVER pass isPopoverOpen: as a plain Bool prop.
                        InlineJobRowsView(group: group)
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
                action: {
                    visibleCount += nextBatch
                    // ⚠️ RULE 10: notify AppDelegate of list expansion.
                    // ❌ NEVER remove this call.
                    // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE
                    // NOT ALLOWED UNDER ANY CIRCUMSTANCE.
                    onContentChanged?()
                },
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
        let urlString = "https://docs.github.com/en/authentication/" +
            "keeping-your-account-and-data-secure/managing-your-personal-access-tokens"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
