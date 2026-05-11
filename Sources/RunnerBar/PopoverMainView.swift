import SwiftUI

// ⚠️ REGRESSION GUARD — frame + padding rules (ref #52 #54 #57 #375 #376 #377)
//
// RULE 1: Root VStack MUST use .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
//         AppDelegate reads hc.view.fittingSize in openPopover() and remeasurePopover()
//         to size the popover. idealWidth pins the measurement width to 480.
//         ❌ NEVER remove .frame(idealWidth: 480)
//         ❌ NEVER use .frame(width: 480)
//         ❌ NEVER remove maxWidth: .infinity
//         ❌ NEVER add .frame(height:) or .frame(maxHeight:) to root VStack
//
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: NEVER use .fixedSize() on the root VStack.
// RULE 5: RunnerStoreObservable.reload() uses withAnimation(nil).
//
// RULE 6: actionsSection MUST NOT be wrapped in ScrollView and MUST NOT have
//         .fixedSize or .frame(maxHeight:) applied to it.
//
//         Height is fully dynamic — driven entirely by fittingSize.height in
//         AppDelegate.remeasurePopover(), which is called via async hop after every
//         navigate() and after "Load more" (onContentChanged callback).
//
//         ❌ NEVER wrap actionsSection in a ScrollView — ScrollView reports infinite
//            fittingSize.height, breaking remeasurePopover().
//         ❌ NEVER add .fixedSize to actionsSection.
//         ❌ NEVER add .frame(maxHeight:) to actionsSection — clips content and
//            mis-sizes the popover for the "Load more" dynamic height use case.
//         ✅ AppDelegate.maxHeight (680pt) is the only height cap — applied in
//            remeasurePopover() and openPopover() when clamping fittingSize.height.
//         If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//         UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
//         is major major major.
//
// RULE 7: The 5 s timer calls LocalRunnerStore.shared.refresh() + store.reload().
//         BOTH are gated behind !isPopoverOpen.
//         ❌ NEVER call store.reload() while isPopoverOpen == true.
//         ❌ NEVER call LocalRunnerStore.shared.refresh() while isPopoverOpen == true.
//         ❌ NEVER remove the !isPopoverOpen guard from the timer.
//         If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//         UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
//         is major major major.
//
// RULE 8: idealWidth is 480. AppDelegate.fixedWidth is also 480.
//         ❌ NEVER change one without changing the other.
//
// RULE 9: systemStats MUST be paused while the popover is open.
//         SystemStatsViewModel fires every 2 s, mutating @StateObject → SwiftUI re-render
//         → intrinsicContentSize update. Belt-and-suspenders with sizingOptions=[].
//         ❌ NEVER remove the .onChange(of: isPopoverOpen) systemStats gate.
//         If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//         UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
//         is major major major.
//
// RULE 10: onContentChanged is called by loadMoreButton after expanding the list.
//          AppDelegate uses it to call remeasurePopover() via 1 async hop so the
//          popover grows to fit the newly visible rows.
//          ❌ NEVER remove onContentChanged from loadMoreButton action.
//          If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//          UNDER ANY CIRCUMSTANCE.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.

struct PopoverMainView: View {
    @ObservedObject var store: RunnerStoreObservable
    let onSelectJob: (ActiveJob) -> Void
    let onSelectAction: (ActionGroup) -> Void
    let onSelectSettings: () -> Void
    /// Called after the "Load more" button expands the list so AppDelegate can
    /// remeasure the popover height. ❌ NEVER remove from loadMoreButton action.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    var onContentChanged: (() -> Void)? = nil
    /// Set by AppDelegate. Gates timer calls and systemStats (RULE 7, RULE 9).
    /// ❌ NEVER remove this property.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    var isPopoverOpen: Bool = false

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
                .onAppear { Task { LocalRunnerStore.shared.refresh() } }
            // ⚠️ RULE 6: NO ScrollView, NO .fixedSize, NO .frame(maxHeight:) here.
            // Height is fully dynamic — remeasurePopover() in AppDelegate handles capping.
            // ❌ NEVER wrap in ScrollView.
            // ❌ NEVER add .fixedSize or .frame(maxHeight:) to actionsSection.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE.
            actionsSection
        }
        // RULE 1: idealWidth:480 is LOAD-BEARING for fittingSize measurement.
        // ❌ NEVER add .frame(height:) or .frame(maxHeight:) here.
        .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            if !isPopoverOpen { systemStats.start() }
            startRunnerRefreshTimer()
        }
        .onDisappear {
            systemStats.stop()
            stopRunnerRefreshTimer()
        }
        // ⚠️ RULE 9: systemStats gate. ❌ NEVER remove.
        // ⚠️ macOS 13-compatible single-value onChange — ❌ NEVER use { _, _ in }.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
        // is major major major.
        .onChange(of: isPopoverOpen) { open in
            if open { systemStats.stop() } else { systemStats.start() }
        }
        .onChange(of: store.actions) { _ in visibleCount = 10 }
    }

    // MARK: - Runner refresh timer (RULE 7)

    private func startRunnerRefreshTimer() {
        stopRunnerRefreshTimer()
        runnerRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            // ❌ NEVER remove this guard (RULE 7).
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this
            // comment is removed is major major major.
            if !isPopoverOpen {
                LocalRunnerStore.shared.refresh()
                store.reload()
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
                        InlineJobRowsView(group: group, isPopoverOpen: isPopoverOpen)
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
                    // ⚠️ RULE 10: notify AppDelegate so it can remeasure the popover
                    // height after the list expands. ❌ NEVER remove this call.
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
